import Foundation
import Observation

@Observable
final class BetterCalendarStore {
    private(set) var calendars: [BetterCalendar] = []
    private(set) var events: [CalendarEvent] = []
    private(set) var pendingMutations: [PendingMutation] = []
    private(set) var deletedEventTombstones: [DeletedEventTombstone] = []
    private(set) var settings: AppSettings = .defaultSettings
    private(set) var recurrenceExceptions: [RecurrenceException] = []
    private(set) var lastError: String?
    private(set) var environmentRevision = 0
    var undoAction: UndoAction?

    private let repository: LocalCalendarRepository
    private let notificationScheduler: LocalNotificationScheduling
    /// Spec 2.5: memoised `RecurrenceExpander` output behind `visibleOccurrences(in:)`. Kept
    /// fresh by `invalidateOccurrenceCache(for:previousDatabase:)` on every `EngineTransaction`
    /// applied through `withPersistedMutation` and fully cleared on any whole-database
    /// replacement (`load()`, `withBulkMutation`).
    private let occurrenceCache = OccurrenceCache()
    /// Spec 2.6 (BC-ENG-003): maintained incrementally by `reindexConflicts(for:previousDatabase:)`
    /// after every successfully persisted `EngineTransaction`, and rebuilt wholesale on any
    /// whole-database replacement (`load()`, `withBulkMutation`) — the same two hook points as
    /// `occurrenceCache`, but reindexed only on success (unlike the occurrence cache, this is
    /// maintained state that mirrors `events`, not a lazily-recomputed memoisation, so a rolled
    /// back mutation must never touch it).
    private let conflictIndex = ConflictIndex()

    init(repository: LocalCalendarRepository = SQLiteCalendarRepository(), notificationScheduler: LocalNotificationScheduling = UserNotificationScheduler()) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        load()
    }

    var defaultCalendarID: UUID? {
        calendars.first(where: \.isDefault)?.id ?? calendars.first?.id
    }

    var visibleEvents: [CalendarEvent] {
        let visibleCalendarIDs = Set(calendars.filter(\.isVisible).map(\.id))
        return events
            .filter { visibleCalendarIDs.contains($0.calendarID) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Spec 2.18's ten-step launch sequence — see `LaunchRecovery`'s doc comment for exactly
    /// which steps live there versus here.
    func load() {
        let outcome = LaunchRecovery.run(repository: repository)
        apply(outcome.database)
        occurrenceCache.invalidateAll()
        conflictIndex.rebuild(from: events)
        ensureDefaultCalendar()

        if outcome.usedFallbackSeed {
            lastError = "Calendar data could not be loaded. Sample local data is being shown while the existing file is left available for recovery."
        } else if outcome.needsRecoveryPrompt {
            lastError = "Calendar data may be corrupted. Existing data is being kept while recovery options are prepared."
        } else {
            lastError = nil
        }

        // Step 9: bumping this here, unconditionally, is cheap insurance against the device's
        // time zone having changed while the app was suspended — `refreshForSystemTimeChange()`
        // already does the same thing reactively for a live TZ-change notification.
        environmentRevision += 1
        reconcileNotifications()
    }

    func saveEvent(from draft: EventDraft) -> Bool {
        guard draft.validationError == nil else { return false }

        let now = Date.now
        let reminders = reminderRecords(for: draft)
        let recurrence = draft.recurrence.frequency == .never ? nil : draft.recurrence
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // BC-TZ-001: resolved directly from both draft flags rather than through the
        // `isAllDay` boolean shim, which only ever collapses `.allDay`⇄`.timed` and would
        // silently drop a `.floating` lock-to-timezone toggle.
        let resolvedTimeType: EventTimeType = draft.isAllDay ? .allDay : (draft.isLockedToTimeZone ? .floating : .timed)

        let outcome: EventMutationUseCases.Outcome
        if let eventID = draft.id, let existing = events.first(where: { $0.id == eventID }) {
            outcome = EventMutationUseCases.updateEvent(eventID: eventID, expectedVersionNumber: existing.versionNumber, in: engineContext()) { updated in
                updated.title = trimmedTitle
                updated.calendarID = draft.calendarID
                updated.startDate = draft.startDate
                updated.endDate = self.normalizedEndDate(for: draft)
                updated.timeType = resolvedTimeType
                updated.timeZoneIdentifier = draft.timeZoneIdentifier
                updated.location = draft.location.nilIfBlank
                updated.urlString = draft.urlString.nilIfBlank
                updated.notes = draft.notes.nilIfBlank
                updated.reminders = reminders
                updated.recurrence = recurrence
                updated.providerMetadata.syncStatus = .pendingUpdate
            }
        } else {
            // A non-nil `draft.id` here means this is a "This Event" occurrence seed
            // (BC-REC-010) whose id was pre-minted by `seedForOccurrenceEdit` but doesn't
            // exist in `events` yet — honour it so the new replacement gets a stable id
            // rather than a second, throwaway one.
            let eventID = draft.id ?? UUID()
            let newEvent = CalendarEvent(
                id: eventID,
                calendarID: draft.calendarID,
                title: trimmedTitle,
                startDate: draft.startDate,
                endDate: normalizedEndDate(for: draft),
                timeType: resolvedTimeType,
                timeZoneIdentifier: draft.timeZoneIdentifier,
                location: draft.location.nilIfBlank,
                urlString: draft.urlString.nilIfBlank,
                notes: draft.notes.nilIfBlank,
                reminders: reminders,
                recurrence: recurrence,
                providerMetadata: ProviderMetadata.local,
                createdAt: now,
                updatedAt: now,
                recurrenceMasterID: draft.recurrenceMasterID,
                recurrenceOriginalStart: draft.recurrenceOriginalStart
            )

            var exception: RecurrenceException?
            if let masterID = draft.recurrenceMasterID, let originalStart = draft.recurrenceOriginalStart,
               let masterEvent = events.first(where: { $0.id == masterID }) {
                exception = RecurrenceException(
                    id: UUID(),
                    masterEventID: masterID,
                    originalOccurrenceStart: masterEvent.isAllDay ? nil : originalStart,
                    originalOccurrenceLocalDate: masterEvent.isAllDay ? masterEvent.localDateString(for: originalStart) : nil,
                    exceptionType: .modified,
                    replacementEventID: eventID
                )
            }

            outcome = EventMutationUseCases.createEvent(newEvent, exception: exception, in: engineContext())
        }

        let didSave = perform(outcome)

        if didSave {
            PrivacyLog.track(.eventSaved)
        }

        if didSave && !reminders.isEmpty {
            reconcileNotifications(authorizationRequestPolicy: .ifNeeded)
        }

        return didSave
    }

    func deleteEvent(_ event: CalendarEvent) {
        let tombstoneID = UUID()
        let outcome = EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, tombstoneID: tombstoneID, in: engineContext())
        guard perform(outcome) else { return }

        PrivacyLog.track(.eventDeleted)
        notificationScheduler.cancelNotifications(for: [event.id])
        undoAction = UndoAction(message: "Deleted \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            let restoreOutcome = EventMutationUseCases.restoreTombstone(event, tombstoneID: tombstoneID, in: self.engineContext(source: .undo))
            _ = self.perform(restoreOutcome)
        }
    }

    /// "This Event" delete scope for a recurring occurrence (BC-REC-010, spec 1.11): records a
    /// `.cancelled` exception so the expander skips just this slot, leaving sibling occurrences
    /// and the master event untouched. If this occurrence was already individually modified,
    /// that replacement is removed too — deleting a modified occurrence deletes it outright,
    /// it doesn't fall back to showing the master's original content.
    func deleteOccurrence(_ occurrence: CalendarOccurrence) {
        guard occurrence.isRecurringOccurrence else {
            deleteEvent(occurrence.event)
            return
        }

        let masterEvent = occurrence.event
        let existingReplacement = existingReplacementEvent(forOccurrenceOf: masterEvent.id, occurrenceStartDate: occurrence.occurrenceStartDate)
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: masterEvent.id,
            originalOccurrenceStart: masterEvent.isAllDay ? nil : occurrence.occurrenceStartDate,
            originalOccurrenceLocalDate: masterEvent.isAllDay ? masterEvent.localDateString(for: occurrence.occurrenceStartDate) : nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )

        let outcome = EventMutationUseCases.cancelOccurrence(
            masterEventID: masterEvent.id,
            exception: exception,
            removingReplacementEventID: existingReplacement?.id,
            in: engineContext()
        )
        guard perform(outcome) else { return }

        if let existingReplacement {
            notificationScheduler.cancelNotifications(for: [existingReplacement.id])
        }
        undoAction = UndoAction(message: "Deleted this occurrence of \"\(masterEvent.title)\"", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            let restoreOutcome = EventMutationUseCases.restoreOccurrence(
                masterEventID: masterEvent.id,
                exceptionID: exception.id,
                restoringReplacement: existingReplacement,
                in: self.engineContext(source: .undo)
            )
            _ = self.perform(restoreOutcome)
        }
    }

    /// The standalone replacement event already recorded for this specific occurrence, if the
    /// user has previously chosen "This Event" to edit it (BC-REC-010).
    func existingReplacementEvent(forOccurrenceOf masterID: UUID, occurrenceStartDate: Date) -> CalendarEvent? {
        events.first { $0.recurrenceMasterID == masterID && $0.recurrenceOriginalStart == occurrenceStartDate }
    }

    /// Resolves which event a "This Event" edit should open (BC-REC-010, spec 1.11): the
    /// existing replacement if this occurrence has already been individually modified,
    /// otherwise a fresh seed built from the occurrence itself. Saving the result through the
    /// normal `saveEvent(from:)` path either updates that replacement or creates it for the
    /// first time — see `seedForOccurrenceEdit`.
    ///
    /// If `occurrence` isn't part of a live recurring series at all — e.g. it's already a
    /// standalone replacement event, encountered when re-editing an already-modified
    /// occurrence via a fresh `visibleOccurrences` lookup — this just returns its own event
    /// unchanged, so the normal update path in `saveEvent(from:)` applies instead of
    /// mistakenly seeding a second replacement chained off the first.
    func eventForEditingOccurrence(_ occurrence: CalendarOccurrence) -> CalendarEvent {
        guard occurrence.isRecurringOccurrence else { return occurrence.event }

        return existingReplacementEvent(forOccurrenceOf: occurrence.event.id, occurrenceStartDate: occurrence.occurrenceStartDate)
            ?? occurrence.event.seedForOccurrenceEdit(occurrenceStartDate: occurrence.occurrenceStartDate, occurrenceEndDate: occurrence.occurrenceEndDate)
    }

    /// Reconstructs a soft-deleted event from its tombstone's durable snapshot (spec 0.12).
    /// This is the recovery path for when the app was force-quit before the in-memory Undo
    /// banner was tapped — the undo closure itself does not survive a relaunch.
    @discardableResult
    func restoreDeletedEvent(_ tombstone: DeletedEventTombstone) -> Bool {
        guard let snapshotJSON = tombstone.eventSnapshotJSON,
              var restoredEvent = CalendarEvent(snapshotJSON: snapshotJSON) else {
            return false
        }

        if !calendars.contains(where: { $0.id == restoredEvent.calendarID }), let fallbackID = defaultCalendarID {
            restoredEvent.calendarID = fallbackID
        }

        let outcome = EventMutationUseCases.restoreTombstone(restoredEvent, tombstoneID: tombstone.id, in: engineContext())
        return perform(outcome)
    }

    func moveEvent(_ event: CalendarEvent, to newStartDate: Date) {
        guard let originalEvent = events.first(where: { $0.id == event.id }) else { return }

        let outcome = EventMutationUseCases.moveEvent(eventID: event.id, to: newStartDate, expectedVersionNumber: originalEvent.versionNumber, in: engineContext())
        guard perform(outcome) else { return }

        undoAction = UndoAction(message: "Moved \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
            guard let self, let current = self.events.first(where: { $0.id == originalEvent.id }) else { return }
            let restoreOutcome = EventMutationUseCases.updateEvent(eventID: originalEvent.id, expectedVersionNumber: current.versionNumber, in: self.engineContext(source: .undo)) { updated in
                updated.startDate = originalEvent.startDate
                updated.endDate = originalEvent.endDate
            }
            _ = self.perform(restoreOutcome)
        }
    }

    func resizeEvent(_ event: CalendarEvent, startDate: Date, endDate: Date) {
        guard endDate > startDate, let originalEvent = events.first(where: { $0.id == event.id }) else { return }

        let outcome = EventMutationUseCases.resizeEvent(eventID: event.id, startDate: startDate, endDate: endDate, expectedVersionNumber: originalEvent.versionNumber, in: engineContext())
        guard perform(outcome) else { return }

        undoAction = UndoAction(message: "Resized \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
            guard let self, let current = self.events.first(where: { $0.id == originalEvent.id }) else { return }
            let restoreOutcome = EventMutationUseCases.updateEvent(eventID: originalEvent.id, expectedVersionNumber: current.versionNumber, in: self.engineContext(source: .undo)) { updated in
                updated.startDate = originalEvent.startDate
                updated.endDate = originalEvent.endDate
            }
            _ = self.perform(restoreOutcome)
        }
    }

    /// BC-EVT-020 (spec 1.10 "Move to calendar"): reassigns an event's owning calendar.
    /// Distinct from `moveEvent`, which changes an event's *time*.
    @discardableResult
    func moveEventToCalendar(_ event: CalendarEvent, calendarID: UUID) -> Bool {
        guard let originalEvent = events.first(where: { $0.id == event.id }), calendarID != event.calendarID else { return false }

        let outcome = EventMutationUseCases.moveEventToCalendar(eventID: event.id, calendarID: calendarID, expectedVersionNumber: originalEvent.versionNumber, in: engineContext())
        return perform(outcome)
    }

    func duplicateEvent(_ event: CalendarEvent, startDate: Date? = nil, includeRecurrence: Bool = false) {
        let newEventID = UUID()
        let outcome = EventMutationUseCases.duplicateEvent(event, newEventID: newEventID, startDate: startDate, includeRecurrence: includeRecurrence, in: engineContext())
        guard perform(outcome) else { return }

        undoAction = UndoAction(message: "Duplicated \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
            guard let self, let duplicate = self.events.first(where: { $0.id == newEventID }) else { return }
            let deleteOutcome = EventMutationUseCases.deleteEvent(eventID: newEventID, expectedVersionNumber: duplicate.versionNumber, in: self.engineContext(source: .undo))
            _ = self.perform(deleteOutcome)
        }
    }

    /// Spec 2.3/2.4 (BC-ENG-001, BC-ENG-002): edits `occurrence`'s series according to `scope`,
    /// via `RecurrenceSplitter`. `scope` defaults to `.thisEventOnly` — every effect this method
    /// can have with the default is identical to `saveEvent(from: store.eventForEditingOccurrence(occurrence))`.
    ///
    /// `.thisAndFuture` is engine-API only in Phase 2 (see `EditScope`'s doc comment) — nothing
    /// under `Features/` calls this method with that scope yet, only `RecurrenceSplitterTests`/
    /// `RecurrenceMatrixTests` and future Phase 3 UI.
    @discardableResult
    func editSeries(_ occurrence: CalendarOccurrence, scope: EditScope = .thisEventOnly, edits: (inout CalendarEvent) -> Void) -> Bool {
        guard let (master, occurrenceKey) = resolveSeries(for: occurrence) else { return false }

        let outcome = RecurrenceSplitter.planEdit(
            scope: scope,
            master: master,
            occurrenceKey: occurrenceKey,
            expectedVersionNumber: expectedVersionNumber(for: occurrence, master: master, scope: scope),
            in: engineContext(),
            edits: edits
        )
        return performSplit(outcome)
    }

    /// Delete counterpart to `editSeries(_:scope:edits:)` — see its doc comment.
    @discardableResult
    func deleteSeries(_ occurrence: CalendarOccurrence, scope: EditScope = .thisEventOnly) -> Bool {
        guard let (master, occurrenceKey) = resolveSeries(for: occurrence) else { return false }

        let outcome = RecurrenceSplitter.planDelete(
            scope: scope,
            master: master,
            occurrenceKey: occurrenceKey,
            expectedVersionNumber: expectedVersionNumber(for: occurrence, master: master, scope: scope),
            exceptions: recurrenceExceptions.filter { $0.masterEventID == master.id },
            in: engineContext()
        )
        return performSplit(outcome)
    }

    /// `.allEvents`/`.thisAndFuture` always version-check the master, regardless of which
    /// occurrence the caller selected it through. `.thisEventOnly` version-checks whichever
    /// entity it will actually write: `occurrence.event` *is* that entity — either the master
    /// itself (an occurrence still generated by the rule, no replacement yet) or an existing
    /// standalone replacement — so using its version number keeps the check aligned with
    /// `RecurrenceSplitter`'s own resolution instead of always checking the master's, which
    /// drifts from a replacement's version after the replacement's first edit.
    private func expectedVersionNumber(for occurrence: CalendarOccurrence, master: CalendarEvent, scope: EditScope) -> Int {
        scope == .thisEventOnly ? occurrence.event.versionNumber : master.versionNumber
    }

    /// Resolves an occurrence (which may itself already be a standalone per-occurrence
    /// replacement, not the recurring master) to the master event backing its series plus the
    /// `OccurrenceKey` identifying its original slot in that master's rule.
    private func resolveSeries(for occurrence: CalendarOccurrence) -> (master: CalendarEvent, occurrenceKey: OccurrenceKey)? {
        let masterID = occurrence.isRecurringOccurrence ? occurrence.event.id : occurrence.event.recurrenceMasterID
        guard let masterID, let master = events.first(where: { $0.id == masterID }) else { return nil }

        let originalStart = occurrence.isRecurringOccurrence
            ? occurrence.occurrenceStartDate
            : (occurrence.event.recurrenceOriginalStart ?? occurrence.occurrenceStartDate)

        return (master, OccurrenceKey(recurrenceMasterID: masterID, originalStart: originalStart))
    }

    /// Dispatches a `RecurrenceSplitter` outcome exactly like `perform(_:)` does for
    /// `EventMutationUseCases.Outcome`. `flaggedExceptions` (spec 2.4) has no Phase 2 UI
    /// consumer yet — see `RecurrenceSplitter.Result`'s doc comment — so it is only observable
    /// by calling `RecurrenceSplitter` directly, which the engine tests do.
    private func performSplit(_ outcome: RecurrenceSplitter.Outcome) -> Bool {
        switch outcome {
        case .applied(let result):
            return withPersistedMutation(result.transaction)
        case .duplicate:
            return true
        case .conflicted:
            lastError = "This event changed since it was last loaded. Your change was not saved."
            return false
        }
    }

    func addCalendar(named name: String, colorName: CalendarColorName) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let calendar = BetterCalendar(
            id: UUID(),
            name: trimmedName,
            colorName: colorName,
            isVisible: true,
            isDefault: calendars.isEmpty,
            sortOrder: calendars.count,
            createdAt: .now,
            updatedAt: .now
        )
        _ = performCalendarTransaction(changes: [.upsertCalendar(calendar)], journalEntityID: calendar.id, journalOperation: .create, outboxOperation: .create)
    }

    func updateCalendar(_ calendar: BetterCalendar) {
        guard let index = calendars.firstIndex(where: { $0.id == calendar.id }) else { return }

        var updated = calendar
        updated.updatedAt = .now
        updated.versionNumber = calendars[index].versionNumber + 1

        var candidateCalendars = calendars
        candidateCalendars[index] = updated
        let changes = [EntityChange.upsertCalendar(updated)] + defaultCalendarCorrections(for: candidateCalendars)

        _ = performCalendarTransaction(changes: changes, journalEntityID: calendar.id, journalOperation: .update, outboxOperation: .update)
    }

    func setDefaultCalendar(_ calendar: BetterCalendar) {
        var changes: [EntityChange] = []
        for existing in calendars {
            let shouldBeDefault = existing.id == calendar.id
            guard existing.isDefault != shouldBeDefault else { continue }
            var copy = existing
            copy.isDefault = shouldBeDefault
            copy.updatedAt = .now
            copy.versionNumber += 1
            changes.append(.upsertCalendar(copy))
        }
        guard !changes.isEmpty else { return }

        _ = performCalendarTransaction(changes: changes, journalEntityID: calendar.id, journalOperation: .update, outboxOperation: .update)
    }

    /// Reorders calendars per a drag gesture's `.onMove` offsets/destination (spec 1.3), then
    /// renumbers `sortOrder` sequentially so it stays a stable, persisted ordering rather than
    /// being re-derived from array position at save time.
    ///
    /// This is a manual reimplementation of `Array.move(fromOffsets:toOffset:)` — that method
    /// is a SwiftUI extension, and the Data layer must not import SwiftUI.
    ///
    /// Pure reordering housekeeping, not a journaled "logical user action" of its own (spec
    /// 2.8's vocabulary has no natural single entity id for "the whole list was reshuffled") —
    /// it goes straight through the transaction pipeline with no journal entry or outbox row.
    func reorderCalendars(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = calendars
        let itemsToMove = source.map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: itemsToMove, at: adjustedDestination)

        var changes: [EntityChange] = []
        for (index, calendar) in reordered.enumerated() where calendar.sortOrder != index {
            var copy = calendar
            copy.sortOrder = index
            copy.updatedAt = .now
            changes.append(.upsertCalendar(copy))
        }
        guard !changes.isEmpty else { return }

        _ = withPersistedMutation(EngineTransaction(entityChanges: changes))
    }

    /// Count of this calendar's not-yet-past events, expanding recurrence within a bounded
    /// one-year lookahead so an open-ended recurring event still counts without generating an
    /// unbounded number of occurrences (spec 1.3 calendar list "number of future events").
    func futureEventCount(for calendar: BetterCalendar, now: Date = .now) -> Int {
        let horizon = DateInterval(start: now, end: now.addingTimeInterval(365 * 24 * 60 * 60))
        let expander = RecurrenceExpander()

        return events
            .filter { $0.calendarID == calendar.id }
            .filter { event in
                guard event.recurrence != nil else {
                    return event.endDate >= now
                }
                return !expander.occurrences(of: event, in: horizon).isEmpty
            }
            .count
    }

    func toggleCalendarVisibility(_ calendar: BetterCalendar) {
        guard let index = calendars.firstIndex(where: { $0.id == calendar.id }) else { return }

        var updated = calendars[index]
        updated.isVisible.toggle()
        updated.updatedAt = .now
        updated.versionNumber += 1

        _ = performCalendarTransaction(changes: [.upsertCalendar(updated)], journalEntityID: calendar.id, journalOperation: .update, outboxOperation: .update)
    }

    func deleteCalendar(_ calendar: BetterCalendar, moveEventsTo replacementID: UUID?) {
        guard !calendar.isDefault || replacementID != nil else { return }

        let affectedEvents = events.filter { $0.calendarID == calendar.id }
        let now = Date.now
        var changes: [EntityChange] = []
        var journalEntries: [ChangeJournalEntry] = []
        var outboxRows: [PendingMutation] = []
        var tombstones: [DeletedEventTombstone] = []

        if let replacementID {
            for event in affectedEvents {
                var updated = event
                updated.calendarID = replacementID
                updated.updatedAt = now
                updated.versionNumber += 1
                changes.append(.upsertEvent(updated))

                let entry = ChangeJournalEntry(id: UUID(), entityType: .event, entityID: event.id, operation: .update, fieldDiff: FieldDiff.compute(from: event, to: updated), source: .userEdit, occurredAt: now, appliedMutationID: nil)
                journalEntries.append(entry)
                outboxRows.append(PendingMutation(id: UUID(), objectID: event.id, objectType: .event, operation: .update, createdAt: now, payload: updated.encodedSnapshotJSON(), changeJournalEntryID: entry.id))
            }
        } else {
            for event in affectedEvents {
                changes.append(.deleteEvent(event.id))
                tombstones.append(
                    DeletedObjectTombstone(id: UUID(), entityType: .event, entityID: event.id, title: event.title, deletedAt: now, deletedBy: .calendarDeletion, eventSnapshotJSON: event.encodedSnapshotJSON(), deletionSyncedAt: nil)
                )

                let entry = ChangeJournalEntry(id: UUID(), entityType: .event, entityID: event.id, operation: .delete, fieldDiff: FieldDiff.compute(from: event, to: Optional<CalendarEvent>.none), source: .userEdit, occurredAt: now, appliedMutationID: nil)
                journalEntries.append(entry)
                outboxRows.append(PendingMutation(id: UUID(), objectID: event.id, objectType: .event, operation: .delete, createdAt: now, payload: event.encodedSnapshotJSON(), changeJournalEntryID: entry.id))
            }
        }

        changes.append(.deleteCalendar(calendar.id))
        let calendarEntry = ChangeJournalEntry(id: UUID(), entityType: .calendar, entityID: calendar.id, operation: .delete, fieldDiff: nil, source: .userEdit, occurredAt: now, appliedMutationID: nil)
        journalEntries.append(calendarEntry)
        outboxRows.append(PendingMutation(id: UUID(), objectID: calendar.id, objectType: .calendar, operation: .delete, createdAt: now, changeJournalEntryID: calendarEntry.id))

        let remainingCalendars = calendars.filter { $0.id != calendar.id }
        changes.append(contentsOf: defaultCalendarCorrections(for: remainingCalendars))

        _ = withPersistedMutation(EngineTransaction(entityChanges: changes, outboxRows: outboxRows, journalEntries: journalEntries, tombstones: tombstones))
    }

    /// Applies a settings change through the same persist-then-rollback-on-failure path as
    /// every other mutation (BC-SET-001, spec 1.20). Settings are not part of the change
    /// journal's entity vocabulary (spec 2.8 covers event/calendar/reminder/recurrence rows),
    /// so this carries no journal entry or outbox row — just the transactional apply-and-roll-
    /// back-on-failure guarantee every mutation gets.
    @discardableResult
    func updateSettings(_ mutate: (inout AppSettings) -> Void) -> Bool {
        var updated = settings
        mutate(&updated)
        return withPersistedMutation(EngineTransaction(settings: updated))
    }

    /// Persists the pieces of view state spec 1.2 requires survive relaunch (BC-VIEW-010).
    /// Each parameter is independently optional so a caller only touches the fields it owns
    /// (`AppRootView` owns tab/view mode, `CalendarScreen` owns the selected date).
    @discardableResult
    func updateLastViewState(tab: BetterCalendarTab? = nil, date: Date? = nil, viewMode: CalendarViewMode? = nil) -> Bool {
        guard tab != nil || date != nil || viewMode != nil else { return true }
        return updateSettings { settings in
            if let tab { settings.lastSelectedTab = tab }
            if let date { settings.lastSelectedDate = date }
            if let viewMode { settings.defaultCalendarView = viewMode }
        }
    }

    func clearUndo() {
        undoAction = nil
    }

    func clearLastError() {
        lastError = nil
    }

    /// Spec 1.20 "Delete all local data" (and the debug "Reset database" diagnostic, which is
    /// the same operation): wipes back to a single fresh default calendar with no events,
    /// tombstones, or pending mutations. Settings are preserved — a full settings reset is a
    /// bigger destructive step than this control promises.
    ///
    /// A wholesale wipe, not a "logical user action" the journal tracks — it stays on the bulk
    /// `save(_:)` path rather than the incremental transaction pipeline.
    @discardableResult
    func deleteAllLocalData() -> Bool {
        withBulkMutation {
            calendars = [BetterCalendar.localDefault()]
            events = []
            pendingMutations = []
            deletedEventTombstones = []
        }
    }

    /// Debug-only diagnostic (spec 1.20): merges the built-in sample calendars/events into the
    /// current database without disturbing existing data.
    @discardableResult
    func loadSampleData() -> Bool {
        let sample = LocalCalendarDatabase.seed
        return withBulkMutation {
            for sampleCalendar in sample.calendars where !calendars.contains(where: { $0.name == sampleCalendar.name }) {
                calendars.append(sampleCalendar)
            }
            events.append(contentsOf: sample.events)
            sortEvents()
        }
    }

    /// Debug-only diagnostic (spec 1.20): forces an immediate notification reconciliation pass.
    func reconcileAllNotifications() {
        reconcileNotifications(authorizationRequestPolicy: .ifNeeded)
    }

    /// Debug-only diagnostic (spec 1.20 "pending notification count").
    func pendingNotificationCount() async -> Int {
        await notificationScheduler.pendingRequestCount()
    }

    /// M7's Settings diagnostics surface (spec 2.20): journal size and the last-applied
    /// migration's identifier/checksum, read live from `repository`. `nil` fields (rather than a
    /// thrown error) are how the flat-file/stub repositories signal "not applicable" — see
    /// `RepositoryDiagnostics.unavailable`.
    func repositoryDiagnostics() -> RepositoryDiagnostics {
        (try? repository.diagnostics()) ?? .unavailable
    }

    func refreshForSystemTimeChange() {
        environmentRevision += 1
        purgeExpiredTombstones()
        reconcileNotifications()
    }

    func visibleOccurrences(in range: DateInterval) -> [CalendarOccurrence] {
        let paddedRange = DateInterval(
            start: range.start.addingTimeInterval(-24 * 60 * 60),
            end: range.end.addingTimeInterval(24 * 60 * 60)
        )
        return visibleEvents
            .flatMap { event in
                occurrenceCache.occurrences(of: event, in: paddedRange, exceptions: recurrenceExceptions.filter { $0.masterEventID == event.id })
            }
            .filter { occurrence in
                if occurrence.event.isAllDay {
                    return true
                }

                return occurrence.occurrenceStartDate < range.end && occurrence.occurrenceEndDate > range.start
            }
            .sorted { lhs, rhs in
                if lhs.occurrenceStartDate == rhs.occurrenceStartDate {
                    return lhs.event.title < rhs.event.title
                }
                return lhs.occurrenceStartDate < rhs.occurrenceStartDate
            }
    }

    func visibleOccurrences(on date: Date, calendar: Calendar = .current) -> [CalendarOccurrence] {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else { return [] }

        return visibleOccurrences(in: dayInterval)
            .filter { $0.occurs(on: date, displayCalendar: calendar) }
            .sorted { lhs, rhs in
                if lhs.event.isAllDay != rhs.event.isAllDay {
                    return lhs.event.isAllDay
                }

                if lhs.occurrenceStartDate == rhs.occurrenceStartDate {
                    return lhs.event.title < rhs.event.title
                }

                return lhs.occurrenceStartDate < rhs.occurrenceStartDate
            }
    }

    /// Spec 2.6 (BC-ENG-003): event ids currently conflicting with `event` — `.busy` and
    /// overlapping (all-day events only against other all-day events, on overlapping local
    /// dates). Engine-API only, like `editSeries`/`deleteSeries`: no `Features/` call site exists
    /// in Phase 2, this exists for Phase 11/12 to build a conflict-warning UI on.
    ///
    /// Indexes each stored `CalendarEvent` row's own interval. For a recurring master that is
    /// its first occurrence only — an unmodified future occurrence has no row of its own to
    /// index, so it is not separately checked here. A per-occurrence replacement event (from a
    /// "This Event" edit) *is* its own row and is fully covered.
    func conflictingEventIDs(for event: CalendarEvent) -> Set<UUID> {
        conflictIndex.conflicts(for: event.id)
    }

    /// Spec 2.7 (BC-ENG-004): merged busy intervals over `query`'s range. `query.calendarIDs ==
    /// nil` resolves to every currently-visible calendar (`calendars.filter(\.isVisible)`) here —
    /// `FreeBusy.query` itself treats `nil` as "no filter, every calendar," since the pure
    /// `Domain/` function has no notion of calendar visibility.
    func freeBusy(_ query: FreeBusy.Query) -> [DateInterval] {
        var resolvedQuery = query
        if resolvedQuery.calendarIDs == nil {
            resolvedQuery.calendarIDs = Set(calendars.filter(\.isVisible).map(\.id))
        }
        return FreeBusy.query(resolvedQuery, events: events, exceptions: recurrenceExceptions)
    }

    /// BC-SRCH-001/002 (spec 1.13): full-text search via the FTS5 index (recall) plus
    /// `SearchFilters` (date range/calendar/timeframe/all-day/recurring), ranked exact title
    /// match → title prefix → title contains → location → notes → calendar name, with future
    /// events sorted before past ones on ties. Falls back to an empty result (rather than a
    /// full in-memory scan) if the index query itself fails — that would mean a corrupt
    /// database, at which point `lastError` from the surrounding load/save path is the more
    /// useful signal.
    func searchEvents(matching query: String, filters: SearchFilters = SearchFilters(), now: Date = .now) -> [CalendarEvent] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        // BC-PRIV-001, spec 0.13: the query string itself is never included, only the fact that
        // a search happened.
        PrivacyLog.track(.searchPerformed)

        let candidateIDs = (try? repository.searchEventIDs(matching: trimmedQuery)).map(Set.init) ?? []
        guard !candidateIDs.isEmpty else { return [] }

        // An explicit calendar filter searches that calendar regardless of its visibility
        // toggle (the user asked for it by name); with no calendar filter, search only the
        // calendars currently shown, matching what every other view already displays.
        let scopedEvents = filters.calendarID == nil ? visibleEvents : events
        let lowercasedQuery = trimmedQuery.lowercased()
        return scopedEvents
            .filter { candidateIDs.contains($0.id) && filters.matches($0, now: now) }
            .sorted { lhs, rhs in
                let lhsRank = searchRank(for: lhs, query: lowercasedQuery)
                let rhsRank = searchRank(for: rhs, query: lowercasedQuery)
                if lhsRank != rhsRank { return lhsRank < rhsRank }

                let lhsFuture = lhs.startDate >= now
                let rhsFuture = rhs.startDate >= now
                if lhsFuture != rhsFuture { return lhsFuture }
                return lhs.startDate < rhs.startDate
            }
    }

    /// Lower is more relevant. Mirrors spec 1.13's ranking order exactly: exact title match,
    /// title prefix, title contains, location match, notes match, calendar-name match.
    private func searchRank(for event: CalendarEvent, query: String) -> Int {
        let title = event.title.lowercased()
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if let location = event.location?.lowercased(), location.contains(query) { return 3 }
        if let notes = event.notes?.lowercased(), notes.contains(query) { return 4 }
        if let calendarName = calendars.first(where: { $0.id == event.calendarID })?.name.lowercased(), calendarName.contains(query) { return 5 }
        return 6
    }

    enum ICSExportScope {
        case singleEvent(UUID)
        case series(masterEventID: UUID)
        case dateRange(DateInterval)
        case calendar(UUID)
        case all
    }

    /// BC-ICS-002 (spec 1.19): exports one event, one recurring series (master + its
    /// exceptions/replacements), a date range, a whole calendar, or everything. Scoping
    /// filters `events` down to the relevant subset before handing off to the codec, which
    /// stays scope-agnostic.
    func exportICS(scope: ICSExportScope = .all) -> String {
        let scopedEvents: [CalendarEvent]
        switch scope {
        case .singleEvent(let eventID):
            scopedEvents = events.filter { $0.id == eventID }
        case .series(let masterEventID):
            let replacementIDs = Set(
                recurrenceExceptions
                    .filter { $0.masterEventID == masterEventID }
                    .compactMap(\.replacementEventID)
            )
            scopedEvents = events.filter { $0.id == masterEventID || replacementIDs.contains($0.id) }
        case .dateRange(let range):
            scopedEvents = events.filter { $0.intersects(range) }
        case .calendar(let calendarID):
            scopedEvents = events.filter { $0.calendarID == calendarID }
        case .all:
            scopedEvents = events
        }

        let scopedIDs = Set(scopedEvents.map(\.id))
        let scopedExceptions = recurrenceExceptions.filter { scopedIDs.contains($0.masterEventID) }
        return ICSCalendarCodec.export(events: scopedEvents, calendars: calendars, recurrenceExceptions: scopedExceptions)
    }

    /// BC-ICS-001 (spec 1.18): parses without persisting, so the caller can show an import
    /// preview (imported/skipped/failed counts, destination-calendar picker) before committing.
    func previewImportICS(_ text: String) -> ImportSummary {
        ICSCalendarCodec.importEvents(from: text, defaultCalendarID: defaultCalendarID)
    }

    /// Commits a previously-parsed import in one transaction (spec 1.18/1.22), reassigning
    /// every imported event to `destinationCalendarID` when given. Duplicate detection (spec
    /// 2.15, BC-ENG-007) goes through `DuplicateDetector`, which checks a provider UID (RFC 5545
    /// UID → `providerMetadata.providerObjectID`) first when the imported event carries one,
    /// falling back to `(calendarID, normalizedTitle, startInstant, endInstant)` matching within
    /// a small tolerance when it doesn't. A duplicate master's replacements/exceptions are
    /// skipped along with it, since they'd otherwise reference a master id that was never
    /// created.
    @discardableResult
    func commitImport(_ summary: ImportSummary, destinationCalendarID: UUID? = nil) -> ImportSummary {
        guard !summary.events.isEmpty else { return summary }

        let masterEvents = summary.events.filter { $0.recurrenceMasterID == nil }
        let replacementEvents = summary.events.filter { $0.recurrenceMasterID != nil }

        var duplicateMasterIDs: Set<UUID> = []
        var duplicateReasonCounts: [DuplicateDetector.MatchReason: Int] = [:]
        for master in masterEvents {
            guard let match = DuplicateDetector.candidates(for: master, among: events).first else { continue }
            duplicateMasterIDs.insert(master.id)
            duplicateReasonCounts[match.reason, default: 0] += 1
        }

        let newMasters = masterEvents.filter { !duplicateMasterIDs.contains($0.id) }
        let newReplacements = replacementEvents.filter { !duplicateMasterIDs.contains($0.recurrenceMasterID ?? $0.id) }
        let newExceptions = summary.recurrenceExceptions.filter { !duplicateMasterIDs.contains($0.masterEventID) }
        let skippedCount = summary.skippedCount + duplicateMasterIDs.count

        var newEvents = newMasters + newReplacements
        if let destinationCalendarID {
            for index in newEvents.indices {
                newEvents[index].calendarID = destinationCalendarID
            }
        }

        guard !newEvents.isEmpty else {
            PrivacyLog.track(.icsImportResult, metadata: "imported=0 skipped=\(skippedCount) failed=\(summary.failedCount)\(duplicateReasonSuffix(duplicateReasonCounts))")
            return ImportSummary(importedCount: 0, skippedCount: skippedCount, failedCount: summary.failedCount, events: [])
        }

        let outcome = EventMutationUseCases.importCommit(events: newEvents, exceptions: newExceptions, in: engineContext(source: .importICS))
        let didSave = perform(outcome)

        if didSave {
            PrivacyLog.track(.icsImportResult, metadata: "imported=\(newEvents.count) skipped=\(skippedCount) failed=\(summary.failedCount)\(duplicateReasonSuffix(duplicateReasonCounts))")
            return ImportSummary(importedCount: newEvents.count, skippedCount: skippedCount, failedCount: summary.failedCount, events: newEvents, recurrenceExceptions: newExceptions)
        }

        PrivacyLog.track(.icsImportResult, metadata: "imported=0 skipped=\(skippedCount) failed=\(summary.failedCount + newEvents.count)\(duplicateReasonSuffix(duplicateReasonCounts))")
        return ImportSummary(importedCount: 0, skippedCount: skippedCount, failedCount: summary.failedCount + newEvents.count, events: [])
    }

    /// Spec 2.15's "log duplicate-detection decisions for auditability," at the granularity the
    /// existing `.icsImportResult` privacy log already tracks import outcomes — not a new
    /// `change_journal` row per decision. See `Documentation/Decisions/0003-duplicate-detector-logging-scope.md`
    /// for why: `change_journal.operation`'s SQLite `CHECK` constraint has no "skipped, not
    /// applied" value, and SQLite's automatic foreign-key-clause rewrite on `ALTER TABLE RENAME`
    /// (the only way to widen a `CHECK`) would also require rebuilding `event_versions`, which
    /// references it — real schema risk for a feature with no UI consumer yet in Phase 2.
    private func duplicateReasonSuffix(_ counts: [DuplicateDetector.MatchReason: Int]) -> String {
        guard !counts.isEmpty else { return "" }
        let parts = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
        return " duplicateReasons=" + parts.joined(separator: ",")
    }

    /// Convenience for the paste-text flow: parses and commits in one call, keeping the
    /// existing `store.importICS(text)` call sites and tests working unchanged.
    @discardableResult
    func importICS(_ text: String) -> ImportSummary {
        commitImport(previewImportICS(text))
    }

    private func engineContext(source: JournalSource = .userEdit) -> EventMutationUseCases.Context {
        EventMutationUseCases.Context(database: database, source: source)
    }

    /// Dispatches a use case's result: `.applied` goes through the normal transaction pipeline,
    /// `.duplicate` is a no-op success (spec 2.10/2.11 — the effect already exists), and
    /// `.conflicted` surfaces as a failed mutation exactly like a persistence failure does.
    @discardableResult
    private func perform(_ outcome: EventMutationUseCases.Outcome) -> Bool {
        switch outcome {
        case .applied(let transaction):
            return withPersistedMutation(transaction)
        case .duplicate:
            return true
        case .conflicted:
            lastError = "This event changed since it was last loaded. Your change was not saved."
            return false
        }
    }

    /// Spec 2.2: applies one `EngineTransaction` — in memory first (optimistic update), then
    /// through the repository — rolling the in-memory state back to what it was if persistence
    /// fails. This is the incremental counterpart of `withBulkMutation` below; every event and
    /// per-entity calendar mutation goes through this one.
    @discardableResult
    private func withPersistedMutation(_ transaction: EngineTransaction) -> Bool {
        guard !transaction.isEmpty else { return true }

        let previousDatabase = database
        invalidateOccurrenceCache(for: transaction, previousDatabase: previousDatabase)
        apply(previousDatabase.applying(transaction))

        guard persist(transaction) else {
            apply(previousDatabase)
            return false
        }

        reindexConflicts(for: transaction, previousDatabase: previousDatabase)
        return true
    }

    /// Spec 2.6: updates `conflictIndex` for exactly the entities this transaction touched.
    /// Run only after `persist` succeeds — unlike `invalidateOccurrenceCache`, which merely drops
    /// entries for lazy recomputation later (safe regardless of whether the mutation ultimately
    /// commits), `conflictIndex` holds maintained state that must never reflect a change that got
    /// rolled back.
    private func reindexConflicts(for transaction: EngineTransaction, previousDatabase: LocalCalendarDatabase) {
        for change in transaction.entityChanges {
            switch change {
            case .upsertEvent(let event):
                let previous = previousDatabase.events.first { $0.id == event.id }
                conflictIndex.reindex(movedFrom: previous, to: event)
            case .deleteEvent(let id):
                let previous = previousDatabase.events.first { $0.id == id }
                conflictIndex.reindex(movedFrom: previous, to: nil)
            case .deleteCalendar(let id):
                // Mirrors the cascade `LocalCalendarDatabase.applying(_:)` performs in memory:
                // the transaction itself only carries `.deleteCalendar`, not one `.deleteEvent`
                // per orphaned event, so those have to be found the same way here.
                for event in previousDatabase.events where event.calendarID == id {
                    conflictIndex.reindex(movedFrom: event, to: nil)
                }
            case .upsertRecurrenceException, .deleteRecurrenceException, .upsertCalendar:
                // Exceptions never change a master's own stored interval, and calendar upserts
                // never change event times — neither affects the index.
                break
            }
        }
    }

    /// Spec 2.5: clears only the cache entries a transaction could actually invalidate, rather
    /// than the whole cache — the entire point of `OccurrenceCache` is to survive an edit to one
    /// event without re-expanding every other series in the calendar. Run unconditionally before
    /// applying (not only on success): if `persist` below fails and the in-memory state rolls
    /// back to `previousDatabase`, the cleared entries simply get recomputed from that reverted
    /// state next time they're read, which is correct either way.
    private func invalidateOccurrenceCache(for transaction: EngineTransaction, previousDatabase: LocalCalendarDatabase) {
        for change in transaction.entityChanges {
            switch change {
            case .upsertEvent(let event):
                occurrenceCache.invalidate(masterID: event.id)
            case .deleteEvent(let id):
                occurrenceCache.invalidate(masterID: id)
            case .upsertRecurrenceException(let exception):
                occurrenceCache.invalidate(masterID: exception.masterEventID)
            case .deleteRecurrenceException(let id):
                if let masterID = previousDatabase.recurrenceExceptions.first(where: { $0.id == id })?.masterEventID {
                    occurrenceCache.invalidate(masterID: masterID)
                }
            case .upsertCalendar, .deleteCalendar:
                // Calendar visibility is filtered before expansion (`visibleEvents`), never
                // inside it, so no cached occurrence set depends on a calendar's own fields.
                // `.deleteCalendar` cascades event deletions the same way SQL's `ON DELETE
                // CASCADE` does; the orphaned cache entries are simply never read again (ids are
                // never reused) rather than actively swept here.
                break
            }
        }
    }

    /// The pre-Phase-2 persist-then-rollback-on-failure shape, kept for the handful of paths
    /// that still genuinely rewrite the whole database rather than one entity's worth of it:
    /// wipe, sample-data merge, and (indirectly, via `save(_:)`) the flat-file repository.
    @discardableResult
    private func withBulkMutation(_ mutate: () -> Void) -> Bool {
        let previousDatabase = database
        mutate()
        occurrenceCache.invalidateAll()

        guard persist() else {
            apply(previousDatabase)
            occurrenceCache.invalidateAll()
            conflictIndex.rebuild(from: events)
            return false
        }

        conflictIndex.rebuild(from: events)
        return true
    }

    private func performCalendarTransaction(
        changes: [EntityChange],
        journalEntityID: UUID,
        journalOperation: JournalOperation,
        outboxOperation: MutationOperation
    ) -> Bool {
        let entry = ChangeJournalEntry(id: UUID(), entityType: .calendar, entityID: journalEntityID, operation: journalOperation, fieldDiff: nil, source: .userEdit, occurredAt: .now, appliedMutationID: nil)
        let mutation = PendingMutation(id: UUID(), objectID: journalEntityID, objectType: .calendar, operation: outboxOperation, createdAt: .now, changeJournalEntryID: entry.id)
        return withPersistedMutation(EngineTransaction(entityChanges: changes, outboxRows: [mutation], journalEntries: [entry]))
    }

    /// Builds `.upsertCalendar` changes for whichever calendar needs `isDefault` set so exactly
    /// one calendar in `candidateCalendars` ends up marked default. Empty when the invariant
    /// already holds — the common case, since every mutation that could break it (deleting the
    /// default calendar, clearing `isDefault` via `updateCalendar`) is rare.
    private func defaultCalendarCorrections(for candidateCalendars: [BetterCalendar]) -> [EntityChange] {
        guard !candidateCalendars.contains(where: \.isDefault), var target = candidateCalendars.first else {
            return []
        }
        target.isDefault = true
        target.updatedAt = .now
        target.versionNumber += 1
        return [.upsertCalendar(target)]
    }

    /// Spec 0.12/2.13's retention window. Defined in `EngineRetentionPolicy` so the in-memory
    /// purge below and the `deleted_objects.purge_after` column the repository writes cannot
    /// disagree about when a tombstone expires.
    private static let tombstoneRetentionInterval = EngineRetentionPolicy.tombstoneRetentionInterval

    private func purgeExpiredTombstones(now: Date = .now) {
        let expirationCutoff = now.addingTimeInterval(-Self.tombstoneRetentionInterval)
        let expiredIDs = deletedEventTombstones.filter { $0.deletedAt < expirationCutoff }.map(\.id)
        guard !expiredIDs.isEmpty else { return }

        _ = withPersistedMutation(EngineTransaction(removedTombstoneIDs: expiredIDs))
    }

    private func ensureDefaultCalendar() {
        if calendars.isEmpty {
            calendars = [BetterCalendar.localDefault()]
        }

        if !calendars.contains(where: \.isDefault), let firstID = calendars.first?.id {
            for index in calendars.indices {
                calendars[index].isDefault = calendars[index].id == firstID
            }
        }
    }

    private func normalizedEndDate(for draft: EventDraft) -> Date {
        if draft.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
            let startOfDay = calendar.startOfDay(for: draft.startDate)
            let proposedEnd = calendar.startOfDay(for: draft.endDate)
            if proposedEnd > startOfDay {
                return proposedEnd
            }
            return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? draft.endDate
        }

        return draft.endDate
    }

    private func reminderRecords(for draft: EventDraft) -> [EventReminder] {
        // `.none` is a UI sentinel for "no reminder selected" and must never be persisted.
        // Dedupe is order-preserving so the reminder list round-trips predictably.
        let requestedOffsets = draft.reminderOffsets
            .filter { $0 != .none }
            .orderPreservingUniqued()

        guard !requestedOffsets.isEmpty else { return [] }

        // Reuse existing reminders' stable IDs when the offset is unchanged, so editing an
        // event that keeps the same reminders doesn't force every notification to be
        // cancelled and rescheduled. Each existing reminder can satisfy at most one
        // requested offset.
        var availableExistingReminders = draft.id.flatMap { eventID in
            events.first(where: { $0.id == eventID })?.reminders
        } ?? []

        return requestedOffsets.map { offset in
            if let matchIndex = availableExistingReminders.firstIndex(where: { $0.offset == offset }) {
                return availableExistingReminders.remove(at: matchIndex)
            }
            return EventReminder(id: UUID(), offset: offset)
        }
    }

    private func sortEvents() {
        events.sort { $0.startDate < $1.startDate }
    }

    private var database: LocalCalendarDatabase {
        LocalCalendarDatabase(
            schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
            calendars: calendars,
            events: events,
            pendingMutations: pendingMutations,
            deletedEventTombstones: deletedEventTombstones,
            settings: settings,
            recurrenceExceptions: recurrenceExceptions
        )
    }

    private func apply(_ database: LocalCalendarDatabase) {
        calendars = database.calendars
        events = database.events
        pendingMutations = database.pendingMutations
        deletedEventTombstones = database.deletedEventTombstones
        settings = database.settings
        recurrenceExceptions = database.recurrenceExceptions
    }

    /// Whole-database bulk persist, for `withBulkMutation`.
    private func persist() -> Bool {
        do {
            try repository.save(database)
            lastError = nil
            reconcileNotifications()
            return true
        } catch {
            lastError = "Calendar changes could not be saved locally."
            return false
        }
    }

    /// Incremental persist, for `withPersistedMutation(_:)`.
    private func persist(_ transaction: EngineTransaction) -> Bool {
        do {
            try repository.apply(transaction)
            lastError = nil
            reconcileNotifications()
            return true
        } catch {
            lastError = "Calendar changes could not be saved locally."
            return false
        }
    }

    private func reconcileNotifications(authorizationRequestPolicy: NotificationAuthorizationRequestPolicy = .never) {
        notificationScheduler.reconcile(events: events, calendars: calendars, now: .now, authorizationRequestPolicy: authorizationRequestPolicy, allDayAlertHour: settings.allDayReminderHour, recurrenceExceptions: recurrenceExceptions)
    }
}

struct UndoAction {
    var message: String
    var actionTitle: String
    var perform: () -> Void
}

protocol LocalCalendarRepository {
    func load() throws -> LocalCalendarDatabase

    /// Whole-database replacement, for the bulk paths that genuinely rewrite everything:
    /// seeding, sample data, and "delete all local data". Spec 2.2 takes the per-mutation path
    /// off this method and onto ``apply(_:)``.
    func save(_ database: LocalCalendarDatabase) throws

    /// Spec 2.2: apply one `EngineTransaction` atomically.
    ///
    /// Implementations must be all-or-nothing. That is what makes spec 2.13's "a tombstone is
    /// written in the same transaction as the delete" a property of the storage layer rather
    /// than a rule two call sites have to remember. `SQLiteCalendarRepository` does this with
    /// one GRDB write transaction and per-row upserts; the flat-file and test repositories,
    /// which rewrite their whole store on every write anyway, get the same guarantee for free
    /// via `save(database.applying(transaction))`.
    func apply(_ transaction: EngineTransaction) throws
    /// BC-SRCH-001 (spec 1.13): candidate event IDs matching `query`, found via an indexed
    /// query rather than loading every event into memory to substring-scan it. No ranking
    /// guarantee beyond "these matched" — the caller (the store, which already holds every
    /// event's full data in memory) applies the exact tie-breaking rules spec 1.13 lists.
    func searchEventIDs(matching query: String) throws -> [UUID]

    /// M7's Settings diagnostics surface (spec 2.20): journal size and the last-applied
    /// migration's identifier/checksum, read live from storage. Meaningful only for a SQL-backed
    /// repository — the flat-file and stub repositories have no `change_journal`/
    /// `schema_metadata` tables and return `.unavailable`.
    func diagnostics() throws -> RepositoryDiagnostics
}

struct RepositoryDiagnostics: Equatable {
    var changeJournalRowCount: Int?
    var lastAppliedMigrationIdentifier: String?
    var migrationChecksum: String?

    static let unavailable = RepositoryDiagnostics(changeJournalRowCount: nil, lastAppliedMigrationIdentifier: nil, migrationChecksum: nil)
}

struct JSONCalendarRepository: LocalCalendarRepository {
    private let fileName: String
    private let fileURLOverride: URL?
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileName: String = "BetterCalendarLocalDatabase.json", fileManager: FileManager = .default) {
        self.fileURLOverride = fileURL
        self.fileName = fileName
        self.fileManager = fileManager
    }

    func load() throws -> LocalCalendarDatabase {
        let fileURL = try databaseURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .seed
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.calendarDecoder.decode(LocalCalendarDatabase.self, from: data)
            return try migrate(decoded)
        } catch {
            try preserveUnreadableFile(at: fileURL)
            throw error
        }
    }

    /// No FTS index in the flat-file repository — falls back to a plain substring scan over
    /// the (already fully in-memory, by this repository's own design) loaded database. Covers
    /// the same fields as the SQLite FTS5 index (title/notes/location/calendar name/URL host)
    /// so ranking behaves identically regardless of which repository is behind the store.
    func searchEventIDs(matching query: String) throws -> [UUID] {
        let database = try load()
        let lowercasedQuery = query.lowercased()
        let calendarNamesByID = Dictionary(uniqueKeysWithValues: database.calendars.map { ($0.id, $0.name) })

        return database.events
            .filter { event in
                event.title.lowercased().contains(lowercasedQuery)
                    || (event.notes?.lowercased().contains(lowercasedQuery) ?? false)
                    || (event.location?.lowercased().contains(lowercasedQuery) ?? false)
                    || (calendarNamesByID[event.calendarID]?.lowercased().contains(lowercasedQuery) ?? false)
                    || (event.urlString.flatMap { URL(string: $0)?.host }?.lowercased().contains(lowercasedQuery) ?? false)
            }
            .map(\.id)
    }

    func diagnostics() throws -> RepositoryDiagnostics {
        .unavailable
    }

    func save(_ database: LocalCalendarDatabase) throws {
        let fileURL = try databaseURL()
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try protectExistingFileBeforeOverwrite(at: fileURL)
        let data = try JSONEncoder.calendarEncoder.encode(database)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Read–modify–write against the single JSON file. Atomicity comes from the `.atomic`
    /// write in `save`: the file is replaced wholesale or not at all, so a transaction can
    /// never be observed half-applied. There is no incremental path to take here — the
    /// flat-file format has no rows to update in place.
    func apply(_ transaction: EngineTransaction) throws {
        guard !transaction.isEmpty else { return }
        try save(try load().applying(transaction))
    }

    private func databaseURL() throws -> URL {
        if let fileURLOverride {
            return fileURLOverride
        }

        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: fileName)
    }

    private func migrate(_ database: LocalCalendarDatabase) throws -> LocalCalendarDatabase {
        guard database.schemaVersion <= LocalCalendarDatabase.currentSchemaVersion else {
            throw LocalCalendarRepositoryError.unsupportedSchemaVersion(database.schemaVersion)
        }

        return LocalCalendarDatabase(
            schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
            calendars: database.calendars,
            events: database.events,
            pendingMutations: database.pendingMutations,
            deletedEventTombstones: database.deletedEventTombstones,
            settings: database.settings,
            recurrenceExceptions: database.recurrenceExceptions
        )
    }

    private func protectExistingFileBeforeOverwrite(at fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.calendarDecoder.decode(LocalCalendarDatabase.self, from: data)
            _ = try migrate(decoded)
        } catch {
            try preserveUnreadableFile(at: fileURL)
        }
    }

    @discardableResult
    private func preserveUnreadableFile(at fileURL: URL) throws -> URL {
        let recoveryURL = uniqueRecoveryURL(for: fileURL)
        try fileManager.copyItem(at: fileURL, to: recoveryURL)
        return recoveryURL
    }

    private func uniqueRecoveryURL(for fileURL: URL) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        let timestamp = Self.recoveryTimestampFormatter.string(from: Date())
        var suffix = "unreadable-\(timestamp)"
        var candidate = directory.appendingPathComponent("\(baseName).\(suffix)").appendingPathExtension(fileExtension)
        var copyNumber = 2

        while fileManager.fileExists(atPath: candidate.path) {
            suffix = "unreadable-\(timestamp)-\(copyNumber)"
            candidate = directory.appendingPathComponent("\(baseName).\(suffix)").appendingPathExtension(fileExtension)
            copyNumber += 1
        }

        return candidate
    }

    private static var recoveryTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

struct ImportSummary: Equatable {
    var importedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var events: [CalendarEvent]
    var recurrenceExceptions: [RecurrenceException] = []
}

extension LocalCalendarDatabase {
    static var seed: LocalCalendarDatabase {
        let schoolCalendar = BetterCalendar.localDefault()
        let personalCalendar = BetterCalendar(
            id: UUID(),
            name: "Personal",
            colorName: .success,
            isVisible: true,
            isDefault: false,
            sortOrder: 1,
            createdAt: .now,
            updatedAt: .now
        )

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let classStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today) ?? today
        let studyStart = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: today) ?? today
        let workoutStart = calendar.date(bySettingHour: 16, minute: 30, second: 0, of: today) ?? today

        return LocalCalendarDatabase(
            schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
            calendars: [schoolCalendar, personalCalendar],
            events: [
                CalendarEvent(
                    id: UUID(),
                    calendarID: schoolCalendar.id,
                    title: "Calculus Lecture",
                    startDate: classStart,
                    endDate: classStart.addingTimeInterval(50 * 60),
                    isAllDay: false,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    location: "Mason Hall",
                    urlString: nil,
                    notes: nil,
                    reminders: [EventReminder(id: UUID(), offset: .minutesBefore(10))],
                    recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday], end: .never),
                    providerMetadata: .local,
                    createdAt: .now,
                    updatedAt: .now
                ),
                CalendarEvent(
                    id: UUID(),
                    calendarID: personalCalendar.id,
                    title: "Workout",
                    startDate: workoutStart,
                    endDate: workoutStart.addingTimeInterval(60 * 60),
                    isAllDay: false,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    location: "IM Building",
                    urlString: nil,
                    notes: nil,
                    reminders: [],
                    recurrence: nil,
                    providerMetadata: .local,
                    createdAt: .now,
                    updatedAt: .now
                ),
                CalendarEvent(
                    id: UUID(),
                    calendarID: schoolCalendar.id,
                    title: "Physics Study Session",
                    startDate: studyStart,
                    endDate: studyStart.addingTimeInterval(90 * 60),
                    isAllDay: false,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    location: "Library",
                    urlString: nil,
                    notes: "Review problem set.",
                    reminders: [EventReminder(id: UUID(), offset: .minutesBefore(30))],
                    recurrence: nil,
                    providerMetadata: .local,
                    createdAt: .now,
                    updatedAt: .now
                )
            ],
            pendingMutations: [],
            deletedEventTombstones: []
        )
    }
}

enum LocalCalendarRepositoryError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Calendar data uses unsupported schema version \(version)."
        }
    }
}

private extension JSONEncoder {
    static var calendarEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var calendarDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
