import Foundation

/// Spec 2.2/2.11: one entry point per logical event-mutating user action. Each function here
/// is a pure planner in effect — it reads `Context.database` (the store's current in-memory
/// snapshot, never SQLite directly) and returns an `Outcome` describing what to do, without
/// performing any I/O itself. `BetterCalendarStore` is the only caller; it turns `.applied`
/// into a call to its own `withPersistedMutation(_:)`.
///
/// Every function takes an `idempotencyKey`, defaulted to a fresh `UUID()`. A real user action
/// always gets a fresh key, so the short-circuit below never fires in ordinary use — it exists
/// for a caller that deliberately reuses a key, which is exactly what a replayed/retried
/// mutation looks like (spec 2.10/2.11; `EngineIdempotencyTests` exercises it directly by
/// passing the same key twice).
enum EventMutationUseCases {
    struct Context {
        var database: LocalCalendarDatabase
        var now: Date = .now
        var source: JournalSource = .userEdit
    }

    /// `.duplicate` and `.conflicted` both mean "nothing was written." They are distinguished
    /// because the caller treats them differently: a duplicate replay is a no-op success, a
    /// conflict is a rejected write.
    enum Outcome {
        case applied(EngineTransaction)
        /// Spec 2.10/2.11: a mutation with this `idempotencyKey` is already `pending` or
        /// `applied` in the outbox. Replaying it is a no-op that still counts as success —
        /// the effect it wanted already exists (or will shortly). Spec 2.13/BC-ENG-006's
        /// resurrection guard reuses this same case: a delayed create/update for an entity
        /// that already has a tombstone is likewise "nothing to do, already handled" — the
        /// delete that produced the tombstone always wins.
        case duplicate
        /// Spec 3.10: the target calendar does not permit this operation — it is read-only, or
        /// its provider reports that it disallows the specific change. Distinct from
        /// `.conflicted`, which means "you may write this, but not from the version you based it
        /// on": a rejection is not retryable and not resolvable by refetching.
        ///
        /// Returned *before* any `EngineTransaction` is produced, so nothing is written locally
        /// and the user never sees an optimistic change that a provider then refuses. Nothing in
        /// Phase 2 can produce this — every calendar that exists today is writable — which is
        /// exactly the property that makes adding it now safe.
        case rejected(CapabilityViolation)
        /// Spec 2.14: `expectedVersionNumber` did not match the entity's current stored
        /// version, so the write is rejected rather than silently overwriting a newer one.
        /// The rejected content is not lost in practice: whatever state it was based on is
        /// already durable in `EventVersion` history from when *that* state was current (see
        /// `updateEvent`) — there is no separate "preserve the loser" step to perform here.
        case conflicted(currentVersionNumber: Int)
    }

    // MARK: - Create

    /// BC-REC-010's "This Event" seed also lands here: `exception`, when supplied, is upserted
    /// in the same transaction as the new replacement event, so the pair can never be observed
    /// half-created.
    static func createEvent(
        _ event: CalendarEvent,
        exception: RecurrenceException? = nil,
        idempotencyKey: UUID = UUID(),
        in context: Context,
        editScope: EditScope? = nil,
        occurrenceDate: Date? = nil
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }
        if hasLiveTombstone(forEntityID: event.id, in: context.database) { return .duplicate }
        if let violation = capabilityViolation(writingTo: event.calendarID, creating: true, in: context.database) {
            return .rejected(violation)
        }

        var changes: [EntityChange] = [.upsertEvent(event)]
        if let exception {
            changes.append(.upsertRecurrenceException(exception))
        }

        let entry = journalEntry(
            entityType: .event,
            entityID: event.id,
            operation: .create,
            fieldDiff: FieldDiff.compute(from: Optional<CalendarEvent>.none, to: event),
            context: context
        )
        let mutation = outboxRow(objectID: event.id, operation: .create, payload: event, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context, editScope: editScope, occurrenceDate: occurrenceDate)

        return .applied(EngineTransaction(entityChanges: changes, outboxRows: [mutation], journalEntries: [entry]))
    }

    // MARK: - Update (shared by move/resize/moveToCalendar too)

    /// The general "edit an existing event" entry point. `mutate` receives a copy of the
    /// event's current stored state (not the caller's possibly-stale copy) and edits it in
    /// place; `move`/`resize`/`moveToCalendar` are all just `mutate` closures over this.
    static func updateEvent(
        eventID: UUID,
        expectedVersionNumber: Int,
        idempotencyKey: UUID = UUID(),
        in context: Context,
        mutate: (inout CalendarEvent) -> Void
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }
        // Checked before "does it exist": a delayed update replaying against an event that was
        // since deleted must report success (BC-ENG-006), not the generic not-found conflict
        // below — those are different situations even though neither has an event to update.
        if hasLiveTombstone(forEntityID: eventID, in: context.database) { return .duplicate }
        guard let previous = context.database.events.first(where: { $0.id == eventID }) else {
            return .conflicted(currentVersionNumber: 0)
        }
        guard previous.versionNumber == expectedVersionNumber else {
            return .conflicted(currentVersionNumber: previous.versionNumber)
        }

        // Spec 3.10: the calendar the event lives on now must permit the edit...
        if let violation = capabilityViolation(writingTo: previous.calendarID, creating: false, in: context.database) {
            return .rejected(violation)
        }
        // ...and spec 3.13/3C.3: so must the event's own repeat pattern. A series the engine
        // cannot express was mirrored raw; editing it would mean writing back an approximation
        // of the user's series, which is how a series gets destroyed. Refusing here is what makes
        // that unreachable rather than merely unlikely.
        if let violation = recurrenceViolation(editing: previous, in: context.database) {
            return .rejected(violation)
        }

        var updated = previous
        mutate(&updated)

        // ...and, when the edit is a move between calendars (`moveEventToCalendar`), the
        // destination must permit gaining one. Checked after `mutate` because that closure is
        // the only thing that knows whether this update is a move.
        if updated.calendarID != previous.calendarID,
           let violation = capabilityViolation(writingTo: updated.calendarID, creating: true, in: context.database) {
            return .rejected(violation)
        }

        updated.versionNumber = previous.versionNumber + 1

        let entry = journalEntry(
            entityType: .event,
            entityID: eventID,
            operation: .update,
            fieldDiff: FieldDiff.compute(from: previous, to: updated),
            context: context
        )
        // Spec 2.9: the row being superseded, snapshotted under its own (pre-bump) version
        // number — the durable record of "what the event looked like at version N."
        let version = EventVersion(
            id: UUID(),
            eventID: eventID,
            versionNumber: previous.versionNumber,
            snapshotJSON: previous.encodedSnapshotJSON() ?? "{}",
            createdAt: context.now,
            changeJournalEntryID: entry.id
        )
        let mutation = outboxRow(objectID: eventID, operation: .update, payload: updated, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

        return .applied(EngineTransaction(
            entityChanges: [.upsertEvent(updated)],
            outboxRows: [mutation],
            journalEntries: [entry],
            eventVersions: [version]
        ))
    }

    /// BC-EVT mutation used by drag-to-move: preserves duration, marks the event
    /// `pendingUpdate` for the next notification reconciliation pass.
    static func moveEvent(
        eventID: UUID,
        to newStartDate: Date,
        expectedVersionNumber: Int,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        updateEvent(eventID: eventID, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context) { updated in
            let duration = max(updated.duration, 15 * 60)
            updated.startDate = newStartDate
            updated.endDate = newStartDate.addingTimeInterval(duration)
            updated.providerMetadata.syncStatus = .pendingUpdate
        }
    }

    static func resizeEvent(
        eventID: UUID,
        startDate: Date,
        endDate: Date,
        expectedVersionNumber: Int,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        updateEvent(eventID: eventID, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context) { updated in
            updated.startDate = startDate
            updated.endDate = endDate
            updated.providerMetadata.syncStatus = .pendingUpdate
        }
    }

    /// BC-EVT-020 (spec 1.10 "Move to calendar"): distinct from `moveEvent`, which changes
    /// time rather than ownership.
    static func moveEventToCalendar(
        eventID: UUID,
        calendarID: UUID,
        expectedVersionNumber: Int,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        updateEvent(eventID: eventID, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context) { updated in
            updated.calendarID = calendarID
        }
    }

    // MARK: - Delete

    /// The caller mints `tombstoneID` up front so it can build an Undo action (which restores
    /// via `restoreTombstone(_:tombstoneID:...)`) before knowing whether the delete committed.
    static func deleteEvent(
        eventID: UUID,
        expectedVersionNumber: Int,
        tombstoneID: UUID = UUID(),
        deletedBy: TombstoneCause = .userEdit,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }
        guard let previous = context.database.events.first(where: { $0.id == eventID }) else {
            // Already gone — replaying a delete against a delete is the definition of success.
            return .duplicate
        }
        guard previous.versionNumber == expectedVersionNumber else {
            return .conflicted(currentVersionNumber: previous.versionNumber)
        }
        // Spec 3.10: deleting is a content modification. A read-only calendar refuses it for the
        // same reason it refuses an edit — and refusing here, before the tombstone is minted,
        // keeps the undo banner from offering to restore something that was never removed.
        if let violation = capabilityViolation(writingTo: previous.calendarID, creating: false, in: context.database) {
            return .rejected(violation)
        }

        let tombstone = DeletedObjectTombstone(
            id: tombstoneID,
            entityType: .event,
            entityID: previous.id,
            title: previous.title,
            deletedAt: context.now,
            deletedBy: deletedBy,
            eventSnapshotJSON: previous.encodedSnapshotJSON(),
            deletionSyncedAt: nil
        )
        let entry = journalEntry(
            entityType: .event,
            entityID: previous.id,
            operation: .delete,
            fieldDiff: FieldDiff.compute(from: previous, to: Optional<CalendarEvent>.none),
            context: context
        )
        let mutation = outboxRow(objectID: previous.id, operation: .delete, payload: previous, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

        return .applied(EngineTransaction(
            entityChanges: [.deleteEvent(previous.id)],
            outboxRows: [mutation],
            journalEntries: [entry],
            tombstones: [tombstone]
        ))
    }

    /// BC-REC-010 "This Event" delete scope: cancels one occurrence via a `RecurrenceException`
    /// without touching the master's own row (so the master carries no version bump), and
    /// removes an existing per-occurrence replacement event if one was already recorded.
    /// Exceptions have no concurrency counter of their own — nothing in Phase 2 edits the same
    /// occurrence exception from two places concurrently.
    static func cancelOccurrence(
        masterEventID: UUID,
        exception: RecurrenceException,
        removingReplacementEventID: UUID? = nil,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }

        var changes: [EntityChange] = [.upsertRecurrenceException(exception)]
        if let removingReplacementEventID {
            changes.append(.deleteEvent(removingReplacementEventID))
        }

        let entry = journalEntry(entityType: .recurrenceException, entityID: exception.id, operation: .create, fieldDiff: nil, context: context)
        let mutation = PendingMutation(
            id: UUID(),
            objectID: masterEventID,
            objectType: .event,
            operation: .update,
            createdAt: context.now,
            idempotencyKey: idempotencyKey,
            changeJournalEntryID: entry.id
        )

        return .applied(EngineTransaction(entityChanges: changes, outboxRows: [mutation], journalEntries: [entry]))
    }

    /// Undo for `cancelOccurrence`: removes the exception and, if a replacement existed before
    /// the cancel, restores it.
    static func restoreOccurrence(
        masterEventID: UUID,
        exceptionID: UUID,
        restoringReplacement replacement: CalendarEvent?,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }

        var changes: [EntityChange] = [.deleteRecurrenceException(exceptionID)]
        if let replacement {
            changes.append(.upsertEvent(replacement))
        }

        let entry = journalEntry(entityType: .recurrenceException, entityID: exceptionID, operation: .delete, fieldDiff: nil, context: context)
        let mutation = PendingMutation(
            id: UUID(),
            objectID: masterEventID,
            objectType: .event,
            operation: .update,
            createdAt: context.now,
            idempotencyKey: idempotencyKey,
            changeJournalEntryID: entry.id
        )

        return .applied(EngineTransaction(entityChanges: changes, outboxRows: [mutation], journalEntries: [entry]))
    }

    // MARK: - Duplicate

    /// The caller mints `newEventID` up front (rather than this function generating one
    /// internally) so it can build an Undo action referencing the new event before knowing
    /// whether the mutation actually committed.
    static func duplicateEvent(
        _ event: CalendarEvent,
        newEventID: UUID = UUID(),
        startDate: Date? = nil,
        includeRecurrence: Bool = false,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }
        // A duplicate is a create on the source event's calendar, so it needs creation rights
        // there — not the edit rights the original event's own calendar would imply.
        if let violation = capabilityViolation(writingTo: event.calendarID, creating: true, in: context.database) {
            return .rejected(violation)
        }

        let duplicateStartDate = startDate ?? event.startDate
        let duplicateEndDate = duplicateStartDate.addingTimeInterval(max(event.duration, event.isAllDay ? 24 * 60 * 60 : 15 * 60))
        let duplicate = CalendarEvent(
            id: newEventID,
            calendarID: event.calendarID,
            title: "Copy of \(event.title)",
            startDate: duplicateStartDate,
            endDate: duplicateEndDate,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: event.location,
            urlString: event.urlString,
            notes: event.notes,
            reminders: event.reminders.map { EventReminder(id: UUID(), offset: $0.offset) },
            recurrence: includeRecurrence ? event.recurrence : nil,
            providerMetadata: .local,
            createdAt: context.now,
            updatedAt: context.now
        )

        let entry = journalEntry(
            entityType: .event,
            entityID: duplicate.id,
            operation: .create,
            fieldDiff: FieldDiff.compute(from: Optional<CalendarEvent>.none, to: duplicate),
            context: context
        )
        let mutation = outboxRow(objectID: duplicate.id, operation: .create, payload: duplicate, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

        return .applied(EngineTransaction(entityChanges: [.upsertEvent(duplicate)], outboxRows: [mutation], journalEntries: [entry]))
    }

    // MARK: - Restore from tombstone

    /// The store decodes the tombstone's snapshot and resolves a fallback calendar before
    /// calling this — the use case only needs the already-reconstructed event and the
    /// tombstone id to retire.
    static func restoreTombstone(
        _ event: CalendarEvent,
        tombstoneID: UUID,
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }

        let entry = journalEntry(
            entityType: .event,
            entityID: event.id,
            operation: .create,
            fieldDiff: FieldDiff.compute(from: Optional<CalendarEvent>.none, to: event),
            context: context
        )
        let mutation = outboxRow(objectID: event.id, operation: .create, payload: event, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

        return .applied(EngineTransaction(
            entityChanges: [.upsertEvent(event)],
            outboxRows: [mutation],
            journalEntries: [entry],
            removedTombstoneIDs: [tombstoneID]
        ))
    }

    // MARK: - Import commit

    /// Spec 1.18/1.22, spec 2.8: one journal entry *per imported event* rather than one for the
    /// whole batch. "One journal entry per logical user action" collapses at the entity level —
    /// each imported event is its own distinct creation, exactly like importing them one at a
    /// time would be, just committed together for spec 2.19's throughput target. The outer
    /// `idempotencyKey` still guards the batch as a whole, so double-tapping "Import" cannot
    /// commit the same parsed payload twice.
    static func importCommit(
        events: [CalendarEvent],
        exceptions: [RecurrenceException],
        idempotencyKey: UUID = UUID(),
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }

        // Spec 2.13/BC-ENG-006: skip (not fail) any event whose id already has a live
        // tombstone, rather than resurrecting it — the rest of the batch still commits.
        let tombstonedIDs = Set(context.database.deletedEventTombstones.map(\.entityID))
        // Spec 3.10, following the same skip-don't-fail precedent as the tombstone filter above:
        // an import destined for a calendar that refuses new events drops those events and
        // commits the rest, rather than failing a whole file because one target is read-only.
        // No calendar refuses today, so this changes nothing until Phase 3 mirrors one.
        let eventsToImport = events.filter {
            !tombstonedIDs.contains($0.id)
                && capabilityViolation(writingTo: $0.calendarID, creating: true, in: context.database) == nil
        }
        guard !eventsToImport.isEmpty else { return .applied(.empty) }
        let importedIDs = Set(eventsToImport.map(\.id))
        let exceptionsToImport = exceptions.filter { importedIDs.contains($0.masterEventID) }

        var changes: [EntityChange] = eventsToImport.map { .upsertEvent($0) }
        changes.append(contentsOf: exceptionsToImport.map { .upsertRecurrenceException($0) })

        var journalEntries: [ChangeJournalEntry] = []
        var mutations: [PendingMutation] = []
        for (index, event) in eventsToImport.enumerated() {
            let entry = journalEntry(
                entityType: .event,
                entityID: event.id,
                operation: .create,
                fieldDiff: FieldDiff.compute(from: Optional<CalendarEvent>.none, to: event),
                context: context
            )
            journalEntries.append(entry)
            // The outer `idempotencyKey` guards the batch as a whole (see this function's doc
            // comment) — but `existingOutcome` only ever finds a key that some row actually
            // carries, so it has to land on a real outbox row, not just be checked against one
            // at the top of this function. The first row carries it verbatim; every other row
            // still gets its own fresh key, since each is independently retryable once a
            // provider exists.
            let rowIdempotencyKey = index == 0 ? idempotencyKey : UUID()
            mutations.append(outboxRow(objectID: event.id, operation: .create, payload: event, idempotencyKey: rowIdempotencyKey, journalEntryID: entry.id, context: context))
        }

        return .applied(EngineTransaction(entityChanges: changes, outboxRows: mutations, journalEntries: journalEntries))
    }

    // MARK: - Shared helpers

    /// Spec 2.10/2.11's idempotency guard: an outbox row already `pending` or `applied` under
    /// this key means the effect this call wants already exists (or is already underway).
    ///
    /// Not `private`: `RecurrenceSplitter` (spec 2.3/2.4) reuses this exact guard for its own
    /// bespoke `.thisAndFuture` transactions rather than re-implementing it.
    /// Spec 3.10's model-layer enforcement. Deliberately conservative: a calendar this database
    /// does not know about is *not* rejected, because Phase 1/2 already allow writing an event
    /// whose `calendarID` has no matching row (import and undo both rely on it), and turning
    /// that into a rejection here would change behavior this phase has no business changing.
    /// Only a calendar that exists and says no produces a violation.
    static func capabilityViolation(
        writingTo calendarID: UUID,
        creating: Bool,
        in database: LocalCalendarDatabase
    ) -> CapabilityViolation? {
        guard let calendar = database.calendars.first(where: { $0.id == calendarID }) else { return nil }
        // Spec 3B.4: an unavailable calendar refuses everything, and says why in its own words —
        // it has not denied permission, it is simply no longer on the device.
        guard !calendar.isUnavailable else {
            return CapabilityViolation(calendarID: calendarID, calendarName: calendar.name, reason: .unavailable)
        }
        // Spec 3F.3: refused at the model layer, not merely hidden from the pickers — the same
        // discipline spec 3.10 applies to a read-only calendar, and for the same reason. A queued
        // edit that predates the choice must not reach the device through the losing transport.
        guard !calendar.isSupersededByDuplicateConnection else {
            return CapabilityViolation(calendarID: calendarID, calendarName: calendar.name, reason: .supersededConnection)
        }
        if creating {
            guard calendar.allowsEventCreation else {
                return CapabilityViolation(calendarID: calendarID, calendarName: calendar.name, reason: .creationNotAllowed)
            }
        } else {
            guard calendar.allowsEventEditing else {
                return CapabilityViolation(calendarID: calendarID, calendarName: calendar.name, reason: .readOnly)
            }
        }
        return nil
    }

    /// Spec 3.13/3C.3's model-layer refusal, the event-level counterpart of
    /// `capabilityViolation(writingTo:creating:in:)`.
    ///
    /// A device event whose repeat pattern `RecurrenceRule` cannot express — more than one rule,
    /// or a set-position/day-of-year form the engine does not model — is mirrored with its
    /// `recurrence` left `nil` and its raw rules preserved. Its occurrences after the first are
    /// therefore *not shown*, which is visible incompleteness; letting it be edited would turn
    /// that into invisible wrongness, because the write-back Phase 3D performs would replace the
    /// user's real series with the approximation we hold.
    ///
    /// Only edits are refused. Creating an event on the same calendar is fine (the new event has
    /// its own, expressible, recurrence), and duplicating one produces a Better Calendar-owned
    /// copy with no recurrence at all — neither can write an approximation back over a series.
    static func recurrenceViolation(editing event: CalendarEvent, in database: LocalCalendarDatabase) -> CapabilityViolation? {
        guard event.hasUnrepresentableRecurrence else { return nil }
        let calendarName = database.calendars.first { $0.id == event.calendarID }?.name ?? event.title
        return CapabilityViolation(
            calendarID: event.calendarID,
            calendarName: calendarName,
            reason: .unrepresentableRecurrence
        )
    }

    static func existingOutcome(forIdempotencyKey key: UUID, in database: LocalCalendarDatabase) -> Outcome? {
        let alreadyEnqueued = database.pendingMutations.contains {
            $0.idempotencyKey == key && ($0.status == .pending || $0.status == .applied)
        }
        return alreadyEnqueued ? .duplicate : nil
    }

    /// Spec 2.13/BC-ENG-006's resurrection guard: an entity with a tombstone still present in
    /// `database` hasn't been purged yet, so per spec 2.13's retention semantics it is still
    /// authoritative — the delete it records always wins over a delayed create/update.
    ///
    /// Not `private`: see `existingOutcome` above — `RecurrenceSplitter` reuses this too.
    static func hasLiveTombstone(forEntityID entityID: UUID, in database: LocalCalendarDatabase) -> Bool {
        database.deletedEventTombstones.contains { $0.entityID == entityID }
    }

    /// Not `private`: see `existingOutcome` above — `RecurrenceSplitter` reuses this too.
    static func journalEntry(
        entityType: EngineEntityType,
        entityID: UUID,
        operation: JournalOperation,
        fieldDiff: String?,
        context: Context
    ) -> ChangeJournalEntry {
        ChangeJournalEntry(
            id: UUID(),
            entityType: entityType,
            entityID: entityID,
            operation: operation,
            fieldDiff: fieldDiff,
            source: context.source,
            occurredAt: context.now,
            appliedMutationID: nil
        )
    }

    /// Not `private`: see `existingOutcome` above — `RecurrenceSplitter` reuses this too.
    static func outboxRow(
        objectID: UUID,
        operation: MutationOperation,
        payload: CalendarEvent,
        idempotencyKey: UUID,
        journalEntryID: UUID,
        context: Context,
        editScope: EditScope? = nil,
        occurrenceDate: Date? = nil
    ) -> PendingMutation {
        PendingMutation(
            id: UUID(),
            objectID: objectID,
            objectType: .event,
            operation: operation,
            createdAt: context.now,
            payload: payload.encodedSnapshotJSON(),
            idempotencyKey: idempotencyKey,
            changeJournalEntryID: journalEntryID,
            editScope: editScope,
            occurrenceDate: occurrenceDate
        )
    }
}
