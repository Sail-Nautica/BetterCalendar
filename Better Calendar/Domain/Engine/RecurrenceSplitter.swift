import Foundation

/// Spec 2.3/2.4 (BC-ENG-001, BC-ENG-002): a pure planner producing the `EngineTransaction` for
/// an `EditScope`-aware create/update/delete against a recurring series. Like
/// `EventMutationUseCases`, it only reads `Context.database` and returns a description of what
/// to do — it never touches SQLite or `BetterCalendarStore` state directly.
///
/// `.thisEventOnly` and `.allEvents` delegate straight to the existing, already-tested
/// `EventMutationUseCases` entry points (`createEvent`/`updateEvent`/`deleteEvent`/
/// `cancelOccurrence`) — they are exactly today's "This Event"/"All Events" behavior, just
/// reachable through one `EditScope`-shaped API instead of two differently-shaped ones.
/// `.thisAndFuture` is new: it splits the series into a truncated original master and a new
/// master carrying the remaining pattern, in one transaction, so a partially split series is
/// never observable (spec 2.13's "same transaction" principle, applied here to a split instead
/// of a delete+tombstone pair).
enum RecurrenceSplitter {
    /// `EventMutationUseCases.Outcome`, generalized to also carry `flaggedExceptions` for the
    /// `.allEvents` case. A separate type rather than reusing `EventMutationUseCases.Outcome`
    /// directly — that type's `.applied` case has no room for a second payload.
    struct Result: Equatable {
        var transaction: EngineTransaction
        /// Spec 2.4: exceptions that no longer correspond to any occurrence the (possibly just
        /// changed) recurrence rule generates. Never removed automatically — "never silently
        /// dropped" — just surfaced for a caller to act on. Always empty for `.thisEventOnly`/
        /// `.thisAndFuture`, which cannot make an exception incompatible with the master's rule.
        var flaggedExceptions: [RecurrenceException] = []
    }

    enum Outcome: Equatable {
        case applied(Result)
        case duplicate
        case conflicted(currentVersionNumber: Int)
        /// Spec 3.10, mirroring `EventMutationUseCases.Outcome.rejected`: a scope edit is still
        /// an edit, and a read-only calendar refuses one wholesale rather than splitting a
        /// series it does not own.
        case rejected(CapabilityViolation)
    }

    // MARK: - Edit

    /// - Parameter expectedVersionNumber: checked against whichever entity this scope actually
    ///   bumps the version of — the master for `.thisAndFuture`/`.allEvents`, or the per-occurrence
    ///   replacement event for `.thisEventOnly` *when one already exists*. A `.thisEventOnly` edit
    ///   that creates a replacement for the first time has nothing to conflict with yet, matching
    ///   `EventMutationUseCases.createEvent`'s own behavior, so the parameter is unused on that path.
    static func planEdit(
        scope: EditScope,
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        idempotencyKey: UUID = UUID(),
        in context: EventMutationUseCases.Context,
        edits: (inout CalendarEvent) -> Void
    ) -> Outcome {
        switch scope {
        case .thisEventOnly:
            return planThisEventOnlyEdit(master: master, occurrenceKey: occurrenceKey, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, edits: edits)
        case .allEvents:
            return planAllEventsEdit(master: master, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, edits: edits)
        case .thisAndFuture:
            return planThisAndFutureEdit(master: master, occurrenceKey: occurrenceKey, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, edits: edits)
        }
    }

    // MARK: - Delete

    /// - Parameter exceptions: every `RecurrenceException` currently recorded for `master`
    ///   (i.e. `database.recurrenceExceptions.filter { $0.masterEventID == master.id }` — the
    ///   caller filters because `Context` carries the whole database and only the caller knows
    ///   which subset is relevant here).
    static func planDelete(
        scope: EditScope,
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        exceptions: [RecurrenceException],
        tombstoneID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        in context: EventMutationUseCases.Context
    ) -> Outcome {
        switch scope {
        case .thisEventOnly:
            return planThisEventOnlyDelete(master: master, occurrenceKey: occurrenceKey, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context)
        case .allEvents:
            return wrap(EventMutationUseCases.deleteEvent(eventID: master.id, expectedVersionNumber: expectedVersionNumber, tombstoneID: tombstoneID, deletedBy: .userEdit, idempotencyKey: idempotencyKey, in: context))
        case .thisAndFuture:
            return planThisAndFutureDelete(master: master, occurrenceKey: occurrenceKey, expectedVersionNumber: expectedVersionNumber, exceptions: exceptions, tombstoneID: tombstoneID, idempotencyKey: idempotencyKey, in: context)
        }
    }

    // MARK: - This Event

    private static func existingReplacement(forMasterID masterID: UUID, occurrenceStart: Date, in database: LocalCalendarDatabase) -> CalendarEvent? {
        database.events.first {
            $0.recurrenceMasterID == masterID && $0.recurrenceOriginalStart.map { abs($0.timeIntervalSince(occurrenceStart)) < 1 } == true
        }
    }

    private static func planThisEventOnlyEdit(
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        idempotencyKey: UUID,
        in context: EventMutationUseCases.Context,
        edits: (inout CalendarEvent) -> Void
    ) -> Outcome {
        if let replacement = existingReplacement(forMasterID: master.id, occurrenceStart: occurrenceKey.originalStart, in: context.database) {
            return wrap(EventMutationUseCases.updateEvent(eventID: replacement.id, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, mutate: edits))
        }

        var seed = master.seedForOccurrenceEdit(occurrenceStartDate: occurrenceKey.originalStart, occurrenceEndDate: occurrenceKey.originalStart.addingTimeInterval(master.duration))
        edits(&seed)
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: master.isAllDay ? nil : occurrenceKey.originalStart,
            originalOccurrenceLocalDate: master.isAllDay ? master.localDateString(for: occurrenceKey.originalStart) : nil,
            exceptionType: .modified,
            replacementEventID: seed.id
        )
        // Spec 3D.5: locally this is a new replacement event; on the device it is a save of one
        // *occurrence* of the existing series, which detaches it. Tagging the row is what lets
        // the write-back planner tell those apart — untagged, it would create a second event on
        // the user's calendar alongside the occurrence the series still generates.
        return wrap(EventMutationUseCases.createEvent(
            seed,
            exception: exception,
            idempotencyKey: idempotencyKey,
            in: context,
            editScope: .thisEventOnly,
            occurrenceDate: occurrenceKey.originalStart
        ))
    }

    /// If this occurrence already has a standalone replacement, it already has a `.modified`
    /// exception too — the two are always created together (see `planThisEventOnlyEdit`) — so
    /// deleting here must reuse that exception rather than mint a second one with a fresh id
    /// for the same slot. Deleting the replacement event itself is enough: the cascade in
    /// `LocalCalendarDatabase.applying(_:)`/`SQLiteCalendarRepository.apply(_:)` nulls out that
    /// exception's `replacementEventID`, and `RecurrenceExpander` already treats `.modified`
    /// exactly like `.cancelled` for the purpose of skipping the master's slot — `exceptionType`
    /// only distinguishes them for display, never for expansion.
    private static func planThisEventOnlyDelete(
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        idempotencyKey: UUID,
        in context: EventMutationUseCases.Context
    ) -> Outcome {
        if let replacement = existingReplacement(forMasterID: master.id, occurrenceStart: occurrenceKey.originalStart, in: context.database) {
            return wrap(EventMutationUseCases.deleteEvent(eventID: replacement.id, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context))
        }

        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: master.isAllDay ? nil : occurrenceKey.originalStart,
            originalOccurrenceLocalDate: master.isAllDay ? master.localDateString(for: occurrenceKey.originalStart) : nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )
        return wrap(EventMutationUseCases.cancelOccurrence(masterEventID: master.id, exception: exception, removingReplacementEventID: nil, idempotencyKey: idempotencyKey, in: context))
    }

    // MARK: - All Events

    private static func planAllEventsEdit(
        master: CalendarEvent,
        expectedVersionNumber: Int,
        idempotencyKey: UUID,
        in context: EventMutationUseCases.Context,
        edits: (inout CalendarEvent) -> Void
    ) -> Outcome {
        let outcome = EventMutationUseCases.updateEvent(eventID: master.id, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, mutate: edits)
        guard case .applied(let transaction) = outcome else { return wrap(outcome) }

        guard case .upsertEvent(let updatedMaster) = transaction.entityChanges.first(where: {
            if case .upsertEvent(let event) = $0 { return event.id == master.id }
            return false
        }) else {
            return .applied(Result(transaction: transaction))
        }

        let relevantExceptions = context.database.recurrenceExceptions.filter { $0.masterEventID == master.id }
        return .applied(Result(transaction: transaction, flaggedExceptions: flaggedExceptions(for: updatedMaster, exceptions: relevantExceptions)))
    }

    /// Spec 2.4: exceptions in `exceptions` that no longer land on any occurrence
    /// `updatedMaster`'s (possibly just-changed) recurrence rule generates. A `nil` recurrence
    /// (the edit turned the series into a single event) flags every exception — none of them
    /// can correspond to an occurrence of a rule that no longer exists.
    private static func flaggedExceptions(for updatedMaster: CalendarEvent, exceptions: [RecurrenceException]) -> [RecurrenceException] {
        guard !exceptions.isEmpty else { return [] }
        guard updatedMaster.recurrence != nil else { return exceptions }

        let expander = RecurrenceExpander()
        let calendar = updatedMaster.calendarInOriginalTimeZone

        return exceptions.filter { exception in
            guard let referenceDate = referenceDate(for: exception, calendar: calendar) else { return true }
            // A narrow window around this one exception's own recorded slot — cheaper and more
            // precise than expanding the whole series, and correct regardless of the rule's end
            // policy (including `.never`, which `RecurrenceExpander` can't be asked to expand
            // "entirely").
            let window = DateInterval(start: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60), end: referenceDate.addingTimeInterval(2 * 24 * 60 * 60))
            let candidates = expander.occurrences(of: updatedMaster, in: window, exceptions: [])
            return !candidates.contains { exception.matches(occurrenceStart: $0.occurrenceStartDate, event: updatedMaster) }
        }
    }

    private static func referenceDate(for exception: RecurrenceException, calendar: Calendar) -> Date? {
        if let start = exception.originalOccurrenceStart { return start }
        if let localDateString = exception.originalOccurrenceLocalDate { return date(fromLocalDateString: localDateString, calendar: calendar) }
        return nil
    }

    private static func date(fromLocalDateString value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    // MARK: - This and Future

    /// How many of `event`'s own occurrences (ignoring exceptions — spec 2.16/RFC 5545, COUNT
    /// is a rule-position count, not an exception-adjusted one) start strictly before `date`.
    /// Used to shrink an `.afterOccurrences` end onto the new master so the *total* occurrence
    /// count across both halves of a split series matches what the original rule promised.
    private static func occurrencesBeforeCount(of event: CalendarEvent, before date: Date) -> Int {
        guard date > event.startDate else { return 0 }
        return RecurrenceExpander().occurrences(of: event, in: DateInterval(start: event.startDate, end: date), exceptions: []).count
    }

    /// The last instant/local-date the truncated original master's rule should still include —
    /// "immediately before" `occurrenceStart`, matching `RecurrenceRule.includes`'s `.onDate`
    /// comparison for the event's own time semantics (CLAUDE.md: all-day compares local dates,
    /// never UTC instants).
    private static func truncationEndDate(before occurrenceStart: Date, event: CalendarEvent) -> Date {
        if event.isAllDay {
            return event.calendarInOriginalTimeZone.date(byAdding: .day, value: -1, to: occurrenceStart) ?? occurrenceStart
        }
        return occurrenceStart.addingTimeInterval(-1)
    }

    private static func isBefore(_ exception: RecurrenceException, splitPoint: Date, event: CalendarEvent) -> Bool {
        if event.isAllDay {
            guard let localDate = exception.originalOccurrenceLocalDate else { return false }
            return localDate < event.localDateString(for: splitPoint)
        }
        guard let start = exception.originalOccurrenceStart else { return false }
        return start < splitPoint
    }

    private static func planThisAndFutureEdit(
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        idempotencyKey: UUID,
        in context: EventMutationUseCases.Context,
        edits: (inout CalendarEvent) -> Void
    ) -> Outcome {
        let occurrencesBefore = occurrencesBeforeCount(of: master, before: occurrenceKey.originalStart)
        guard occurrencesBefore > 0 else {
            // Nothing precedes the selected occurrence — there is no series left to keep as a
            // separate "before" half, so this degenerates to an ordinary whole-series edit.
            return planAllEventsEdit(master: master, expectedVersionNumber: expectedVersionNumber, idempotencyKey: idempotencyKey, in: context, edits: edits)
        }

        if EventMutationUseCases.hasLiveTombstone(forEntityID: master.id, in: context.database) { return .duplicate }
        if let outcome = EventMutationUseCases.existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return wrap(outcome) }
        guard master.versionNumber == expectedVersionNumber else { return .conflicted(currentVersionNumber: master.versionNumber) }

        var truncatedMaster = master
        truncatedMaster.recurrence?.end = .onDate(truncationEndDate(before: occurrenceKey.originalStart, event: master))
        truncatedMaster.versionNumber = master.versionNumber + 1
        truncatedMaster.updatedAt = context.now

        var newMaster = master
        newMaster.id = UUID()
        newMaster.startDate = occurrenceKey.originalStart
        newMaster.endDate = occurrenceKey.originalStart.addingTimeInterval(master.duration)
        newMaster.versionNumber = 1
        newMaster.createdAt = context.now
        newMaster.updatedAt = context.now
        newMaster.recurrenceMasterID = nil
        newMaster.recurrenceOriginalStart = nil
        newMaster.reminders = master.reminders.map { EventReminder(id: UUID(), offset: $0.offset) }
        if case .afterOccurrences(let count) = master.recurrence?.end {
            newMaster.recurrence?.end = .afterOccurrences(max(count - occurrencesBefore, 0))
        }
        edits(&newMaster)

        let relevantExceptions = context.database.recurrenceExceptions.filter { $0.masterEventID == master.id }
        let splitAtExceptions = relevantExceptions.filter { $0.matches(occurrenceStart: occurrenceKey.originalStart, event: master) }
        let laterExceptions = relevantExceptions.filter { !isBefore($0, splitPoint: occurrenceKey.originalStart, event: master) && !$0.matches(occurrenceStart: occurrenceKey.originalStart, event: master) }

        // A transferred exception's own `replacementEventID` still carries `recurrenceMasterID`
        // pointing at the old (now truncated) master. Left alone, `resolveSeries(for:)` would
        // resolve that replacement back to the wrong half of the split the next time it's
        // selected for an All Events/This and Future action, so its series metadata moves to
        // the new master right alongside the exception it belongs to.
        let transferredReplacements: [CalendarEvent] = laterExceptions.compactMap { exception in
            guard let replacementID = exception.replacementEventID,
                  var replacement = context.database.events.first(where: { $0.id == replacementID }) else { return nil }
            replacement.recurrenceMasterID = newMaster.id
            return replacement
        }

        var changes: [EntityChange] = [.upsertEvent(truncatedMaster), .upsertEvent(newMaster)]
        changes.append(contentsOf: laterExceptions.map {
            var transferred = $0
            transferred.masterEventID = newMaster.id
            return .upsertRecurrenceException(transferred)
        })
        changes.append(contentsOf: transferredReplacements.map { .upsertEvent($0) })
        // The occurrence being split on is folded directly into the new master's own first
        // occurrence — its exception (and any standalone replacement it pointed at) is retired
        // rather than transferred, since the new master's content (from `edits`) already is
        // that occurrence's content.
        changes.append(contentsOf: splitAtExceptions.map { .deleteRecurrenceException($0.id) })
        changes.append(contentsOf: splitAtExceptions.compactMap { $0.replacementEventID }.map { .deleteEvent($0) })

        let entry = EventMutationUseCases.journalEntry(
            entityType: .event,
            entityID: master.id,
            operation: .update,
            fieldDiff: FieldDiff.compute(from: master, to: truncatedMaster),
            context: context
        )
        let version = EventVersion(id: UUID(), eventID: master.id, versionNumber: master.versionNumber, snapshotJSON: master.encodedSnapshotJSON() ?? "{}", createdAt: context.now, changeJournalEntryID: entry.id)
        // Spec 3D.5: locally a split is two rows — truncate one master, create another. On the
        // device it is **one** future-span write, and EventKit performs its own split. Both rows
        // carry the scope so the planner issues exactly that one write and retires the other
        // without touching the device; writing both would leave the user with a truncated series
        // *and* a separate new one that EventKit never made.
        let truncateOutbox = EventMutationUseCases.outboxRow(objectID: master.id, operation: .update, payload: truncatedMaster, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context, editScope: .thisAndFuture, occurrenceDate: occurrenceKey.originalStart)
        let createOutbox = EventMutationUseCases.outboxRow(objectID: newMaster.id, operation: .create, payload: newMaster, idempotencyKey: UUID(), journalEntryID: entry.id, context: context, editScope: .thisAndFuture, occurrenceDate: occurrenceKey.originalStart)

        return .applied(Result(transaction: EngineTransaction(
            entityChanges: changes,
            outboxRows: [truncateOutbox, createOutbox],
            journalEntries: [entry],
            eventVersions: [version]
        )))
    }

    private static func planThisAndFutureDelete(
        master: CalendarEvent,
        occurrenceKey: OccurrenceKey,
        expectedVersionNumber: Int,
        exceptions: [RecurrenceException],
        tombstoneID: UUID,
        idempotencyKey: UUID,
        in context: EventMutationUseCases.Context
    ) -> Outcome {
        let occurrencesBefore = occurrencesBeforeCount(of: master, before: occurrenceKey.originalStart)
        guard occurrencesBefore > 0 else {
            // Deleting "this and future" from the very first occurrence deletes the whole
            // series. `.recurrenceSplit` (rather than `.userEdit`) records that this tombstone
            // came from a this-and-future action, not a plain "delete event" one.
            return wrap(EventMutationUseCases.deleteEvent(eventID: master.id, expectedVersionNumber: expectedVersionNumber, tombstoneID: tombstoneID, deletedBy: .recurrenceSplit, idempotencyKey: idempotencyKey, in: context))
        }

        if EventMutationUseCases.hasLiveTombstone(forEntityID: master.id, in: context.database) { return .duplicate }
        if let outcome = EventMutationUseCases.existingOutcome(forIdempotencyKey: idempotencyKey, in: context.database) { return wrap(outcome) }
        guard master.versionNumber == expectedVersionNumber else { return .conflicted(currentVersionNumber: master.versionNumber) }

        var truncatedMaster = master
        truncatedMaster.recurrence?.end = .onDate(truncationEndDate(before: occurrenceKey.originalStart, event: master))
        truncatedMaster.versionNumber = master.versionNumber + 1
        truncatedMaster.updatedAt = context.now

        // Every occurrence from the split point onward is gone outright — unlike the edit case,
        // there is no new master to transfer their exceptions to.
        let retiredExceptions = exceptions.filter { !isBefore($0, splitPoint: occurrenceKey.originalStart, event: master) }

        var changes: [EntityChange] = [.upsertEvent(truncatedMaster)]
        changes.append(contentsOf: retiredExceptions.map { .deleteRecurrenceException($0.id) })
        changes.append(contentsOf: retiredExceptions.compactMap { $0.replacementEventID }.map { .deleteEvent($0) })

        let entry = EventMutationUseCases.journalEntry(
            entityType: .event,
            entityID: master.id,
            operation: .update,
            fieldDiff: FieldDiff.compute(from: master, to: truncatedMaster),
            context: context
        )
        let version = EventVersion(id: UUID(), eventID: master.id, versionNumber: master.versionNumber, snapshotJSON: master.encodedSnapshotJSON() ?? "{}", createdAt: context.now, changeJournalEntryID: entry.id)
        let mutation = EventMutationUseCases.outboxRow(objectID: master.id, operation: .update, payload: truncatedMaster, idempotencyKey: idempotencyKey, journalEntryID: entry.id, context: context)

        return .applied(Result(transaction: EngineTransaction(entityChanges: changes, outboxRows: [mutation], journalEntries: [entry], eventVersions: [version])))
    }

    // MARK: - Shared

    private static func wrap(_ outcome: EventMutationUseCases.Outcome) -> Outcome {
        switch outcome {
        case .applied(let transaction):
            return .applied(Result(transaction: transaction))
        case .duplicate:
            return .duplicate
        case .conflicted(let currentVersionNumber):
            return .conflicted(currentVersionNumber: currentVersionNumber)
        case .rejected(let violation):
            return .rejected(violation)
        }
    }
}
