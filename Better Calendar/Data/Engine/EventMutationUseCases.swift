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
        in context: Context
    ) -> Outcome {
        if let outcome = existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return outcome }
        if hasLiveTombstone(forEntityID: event.id, in: context.database) { return .duplicate }

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
        let mutation = outboxRow(objectID: event.id, operation: .create, payload: event, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

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

        var updated = previous
        mutate(&updated)
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
        let eventsToImport = events.filter { !tombstonedIDs.contains($0.id) }
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
        context: Context
    ) -> PendingMutation {
        PendingMutation(
            id: UUID(),
            objectID: objectID,
            objectType: .event,
            operation: operation,
            createdAt: context.now,
            payload: payload.encodedSnapshotJSON(),
            idempotencyKey: idempotencyKey,
            changeJournalEntryID: journalEntryID
        )
    }
}
