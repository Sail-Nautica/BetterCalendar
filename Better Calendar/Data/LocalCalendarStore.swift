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
    /// Spec 3.4: the device's current answer about calendar access, re-read on every foreground
    /// transition and on every device-calendar surface's appearance — never cached across the
    /// process lifetime and never persisted. It starts `notDetermined` because `load()`
    /// deliberately performs no authorization read: launch touches nothing from EventKit, and
    /// the first read happens when a surface that needs it appears.
    private(set) var calendarAccessStatus: CalendarAccessStatus = .notDetermined
    /// Spec 3B.5: `EKEventStore.defaultCalendarForNewEvents`, as the provider's own identifier.
    /// Refreshed by every discovery pass and held in memory only — it is the device's state, and
    /// a persisted copy disagrees with it the moment the user changes it in Settings.
    private(set) var deviceDefaultCalendarIdentifier: String?
    /// Counts from the last discovery pass — never content (spec 3.24). Surfaced in the
    /// diagnostics section of Settings.
    private(set) var lastDiscoverySummary: DeviceCalendarMirror.Summary?
    /// The same, for the last event-mirroring pass (spec 3C.8).
    private(set) var lastEventMirrorSummary: DeviceEventMirror.Summary?
    /// Counts from the last write-back drain — never content (spec 3.24/3D.8). What
    /// `SRC-STAT-01` reads.
    private(set) var lastWriteBackSummary: DeviceWriteCommitter.Summary?
    /// The window the last event-mirroring pass actually covered. Held so a diagnostics surface
    /// can say what was reconciled rather than implying the whole calendar was — and so Phase 3E
    /// has the value it needs to persist per calendar.
    private(set) var lastEventMirrorWindow: DateInterval?
    var undoAction: UndoAction?

    private let repository: LocalCalendarRepository
    private let notificationScheduler: LocalNotificationScheduling
    /// Spec 3.3/3.4 and 3B.3. Injected so the whole permission and discovery flow runs in CI
    /// against `FakeEventKitStore` with no device, no account and no system prompt (BC-EK-024).
    private let eventKitStore: EventKitStore
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

    init(
        repository: LocalCalendarRepository = SQLiteCalendarRepository(),
        notificationScheduler: LocalNotificationScheduling = UserNotificationScheduler(),
        eventKitStore: EventKitStore = EventKitDeviceStore()
    ) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        self.eventKitStore = eventKitStore
        load()
    }

    /// Spec 3B.5 (BC-EK-019). `isDefault` stays a flag on the row (ADR 0005), but the flagged
    /// calendar can stop being usable — permission revoked, account removed, a shared calendar
    /// turned read-only — so resolving it walks a deterministic fallback chain rather than
    /// handing back a destination that will refuse the write.
    ///
    /// It never falls back to a read-only or unavailable calendar. The final `calendars.first`
    /// is the pre-Phase-3 behaviour, kept as a last resort for the degenerate case where nothing
    /// is writable at all.
    var defaultCalendarID: UUID? {
        if let flagged = calendars.first(where: \.isDefault), flagged.isWritableDestination {
            return flagged.id
        }
        if let deviceDefaultCalendarIdentifier,
           let deviceDefault = calendars.first(where: {
               $0.connectionMethod == .device && $0.providerCalendarID == deviceDefaultCalendarIdentifier && $0.isWritableDestination
           }) {
            return deviceDefault.id
        }
        return writableDestinationCalendars.first?.id ?? calendars.first?.id
    }

    /// Spec 3B.5/3B.8: every calendar the user may be offered as a destination, in display
    /// order. Read-only and unavailable calendars are absent rather than shown and refused.
    var writableDestinationCalendars: [BetterCalendar] {
        calendars.filter(\.isWritableDestination)
    }

    /// Spec 3B.6: the calendars Better Calendar owns, which are the only ones it may rename,
    /// recolour, reorder or delete.
    var localCalendars: [BetterCalendar] {
        calendars.filter { $0.connectionMethod != .device }
    }

    /// Mirrored device calendars, in display order.
    var deviceCalendars: [BetterCalendar] {
        calendars.filter { $0.connectionMethod == .device }
    }

    /// Spec 3.8/BC-EK-004: device calendars grouped by their owning account, accounts in
    /// alphabetical order so the list does not reshuffle between passes.
    var deviceCalendarAccounts: [DeviceCalendarAccount] {
        Dictionary(grouping: deviceCalendars) { $0.accountName ?? "Other" }
            .map { DeviceCalendarAccount(name: $0.key, calendars: $0.value.sorted { $0.sortOrder < $1.sortOrder }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var visibleEvents: [CalendarEvent] {
        // Spec 3B.4: a calendar that is no longer on the device contributes nothing to any view,
        // whatever the user's last visibility choice was — that choice is preserved on the row so
        // reconnecting restores it, but it cannot show events from a calendar that is gone.
        let visibleCalendarIDs = Set(calendars.filter { $0.isVisible && !$0.isUnavailable }.map(\.id))
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

        // Spec 3D.5: a future split is not an edit of this event, it is an edit of the series
        // from one occurrence onward — a different transaction shape entirely, and one
        // `RecurrenceSplitter` has produced since Phase 2 M4.
        if let splitStart = draft.scopedSplitOccurrenceStart,
           let eventID = draft.id,
           let master = events.first(where: { $0.id == eventID }) {
            let didSplit = applySeriesEdit(
                master: master,
                occurrenceStart: splitStart,
                scope: .thisAndFuture
            ) { updated in
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
            }
            if didSplit {
                PrivacyLog.track(.eventSaved)
            }
            return didSplit
        }

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

            // Spec 3D.5: a draft carrying a master and an original start *is* a "this event only"
            // edit, whichever screen produced it. Tagging it here as well as in
            // `RecurrenceSplitter` is what stops the editor's own path — the one the UI actually
            // uses — from being written to the device as a brand-new event beside the occurrence
            // the series still generates.
            outcome = EventMutationUseCases.createEvent(
                newEvent,
                exception: exception,
                in: engineContext(),
                editScope: exception == nil ? nil : .thisEventOnly,
                occurrenceDate: exception == nil ? nil : draft.recurrenceOriginalStart
            )
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

    /// Spec 3D.5's third scope, through the editor.
    ///
    /// `.thisAndFuture` has no seed event to hand the editor the way `.thisEventOnly` does — it
    /// edits the series from a point forward, and the split happens on save. So the caller edits
    /// the master's own fields and this applies them at the chosen occurrence, through
    /// `RecurrenceSplitter`, which is where the split has lived since Phase 2 M4.
    @discardableResult
    func editSeriesFromOccurrence(_ occurrence: CalendarOccurrence, edits: (inout CalendarEvent) -> Void) -> Bool {
        editSeries(occurrence, scope: .thisAndFuture, edits: edits)
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

    /// `editSeries` addressed by master and occurrence start rather than by a
    /// `CalendarOccurrence`, for the save path — which holds a draft, not an occurrence.
    @discardableResult
    func applySeriesEdit(master: CalendarEvent, occurrenceStart: Date, scope: EditScope, edits: (inout CalendarEvent) -> Void) -> Bool {
        let outcome = RecurrenceSplitter.planEdit(
            scope: scope,
            master: master,
            occurrenceKey: OccurrenceKey(recurrenceMasterID: master.id, originalStart: occurrenceStart),
            expectedVersionNumber: master.versionNumber,
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
        case .rejected(let violation):
            lastError = violation.message
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
        guard !changesProviderOwnedFields(of: calendars[index], to: calendar) else {
            // Spec 3B.6: renaming, recolouring or deleting a device calendar mutates a shared
            // system resource in ways a user does not expect a third-party app to perform. The
            // calendar manager does not offer those affordances; this is the model-layer half of
            // the same rule, so a future screen cannot reintroduce them by accident.
            lastError = "\"\(calendar.name)\" is managed by this device's account. Rename, recolour, or remove it in Settings."
            return
        }

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
    ///
    /// Spec 3B.6: the offsets index into `localCalendars`, because those are the only calendars
    /// `CAL-MGR-01` lets the user drag. Device calendars keep their relative order and are
    /// renumbered after them, so the two lists cannot interleave and an offset can never be
    /// resolved against the wrong row.
    func reorderCalendars(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = localCalendars
        let itemsToMove = source.map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: itemsToMove, at: adjustedDestination)
        reordered.append(contentsOf: deviceCalendars)

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
        guard calendar.connectionMethod != .device else {
            // Spec 3B.6. Deleting the mirror row would also be wrong on its own terms: the next
            // discovery pass would import the calendar again as new, losing the user's
            // visibility choice and (from Phase 3C) orphaning every event mirrored onto it.
            lastError = "\"\(calendar.name)\" is managed by this device's account. Remove it in Settings."
            return
        }

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

    // MARK: - Device calendar access (spec 3.3/3.4, Phase 3A)

    /// Spec 3.4's behavior table for the current state, combining the device's answer with the
    /// one bit of the flow this app owns. Every device-calendar surface reads this rather than
    /// switching on the raw status.
    var deviceCalendarAccess: DeviceCalendarAccessState {
        DeviceCalendarAccessState(
            status: calendarAccessStatus,
            hasSeenPrimer: settings.hasSeenCalendarAccessPrimer
        )
    }

    /// Spec 3.4: re-read the device's answer. Called on every transition to the active scene
    /// phase and whenever a device-calendar surface appears — a user can revoke access in
    /// Settings while the app is backgrounded, and on return the app must degrade without
    /// crashing and without losing local data (BC-EK-022).
    ///
    /// Cheap and synchronous by construction: reading the status is a static EventKit call that
    /// creates no event store and shows no prompt.
    func refreshDeviceCalendarAccess() {
        calendarAccessStatus = eventKitStore.authorizationStatus
    }

    /// BC-EK-001: records that `SRC-PERM-01` has been shown. Called for both of the primer's
    /// outcomes — "Not Now" records it and stops there, which is what leaves the single-use
    /// system prompt unburned for whenever the user is ready.
    @discardableResult
    func markCalendarAccessPrimerSeen() -> Bool {
        guard !settings.hasSeenCalendarAccessPrimer else { return true }
        return updateSettings { $0.hasSeenCalendarAccessPrimer = true }
    }

    /// Spec 3.3: presents the system alert, at most once, and only after the primer has
    /// explained it.
    ///
    /// Both preconditions are enforced here rather than in the view, so no future screen can
    /// reach the system alert by calling this directly:
    /// - the primer must have been seen (BC-EK-001), and
    /// - the device must not already have answered — after a denial the app never re-prompts
    ///   in-app, it offers a Settings deep link and stops asking.
    ///
    /// Returns the resulting status; when a precondition fails it returns the live status
    /// unchanged, having asked the system nothing.
    @discardableResult
    func requestDeviceCalendarAccess() async -> CalendarAccessStatus {
        refreshDeviceCalendarAccess()
        guard deviceCalendarAccess.canRequestAccess else {
            return calendarAccessStatus
        }

        // Spec 3.3: always full access. The product must display existing events, so write-only
        // is a state to handle gracefully, never a state to request.
        let result = await eventKitStore.requestAccess(.full)
        calendarAccessStatus = result
        // Spec 3K: counts and enum-like status only — never a calendar name or an account email.
        PrivacyLog.track(.calendarPermissionResult, metadata: result.rawValue)
        // A fresh grant is the first moment there is anything to discover (BC-EK-004) — or, from
        // Phase 3C, anything to mirror.
        await refreshDeviceCalendars()
        return result
    }

    // MARK: - Device calendar discovery (spec 3B.3, Phase 3B)

    /// Mirrors the device's calendars into `calendars`, through `DeviceCalendarMirror`.
    ///
    /// Spec 3B.0: this runs on **explicit triggers only** — a foreground transition, a fresh
    /// grant, or a device-calendar surface appearing. Subscribing to `EKEventStoreChanged` is
    /// Phase 3E's job, and doing it here would mean reacting to event changes with a pass that
    /// only looks at calendars.
    ///
    /// Synchronous on purpose. Enumerating calendars is bounded by their number — dozens at
    /// worst — unlike Phase 3C's event fetch, which is bounded by the size of the user's
    /// calendar and is where moving off the main actor stops being optional (spec 3.27).
    /// `load()` still never calls this, so launch does no EventKit work at all.
    @discardableResult
    func discoverDeviceCalendars(now: Date = .now) -> Bool {
        refreshDeviceCalendarAccess()
        // Spec 3B.4: access loss is not disappearance. Below full access we cannot see the
        // calendars, so we say nothing about them — marking every mirrored row unavailable here
        // would destroy exactly the state a re-grant is supposed to restore.
        guard calendarAccessStatus.canReadDeviceEvents else { return true }

        let snapshot: DeviceCalendarSnapshot
        do {
            snapshot = try eventKitStore.discoverCalendars()
        } catch {
            // Nothing is lost by a failed pass — the mirror simply is not updated — so this
            // does not raise the data-error alert. Raising one on every foreground for a
            // transient store failure would be worse than the failure.
            PrivacyLog.debug("Device calendar discovery failed")
            return false
        }

        deviceDefaultCalendarIdentifier = snapshot.defaultCalendarIdentifierForNewEvents

        let plan = DeviceCalendarMirror.plan(devices: snapshot.calendars, existing: calendars, now: now)
        lastDiscoverySummary = plan.summary
        guard !plan.isEmpty else { return true }

        return applyDiscovery(plan, now: now)
    }

    /// Spec 3C.9/3.34: why this event cannot be edited, or `nil` if it can.
    ///
    /// Answered by the *model layer* — the same two gates `updateEvent` applies — rather than by
    /// the view re-deriving the rule from `isReadOnly`. That matters more than it looks: spec
    /// 3.34 requires the detail view say an event is read-only **before** the user attempts an
    /// edit, and a screen that computes its own answer is a screen that can disagree with the
    /// one the save path will give. Here, what the user is told and what the engine would do are
    /// the same expression.
    func editRefusal(for event: CalendarEvent) -> CapabilityViolation? {
        EventMutationUseCases.capabilityViolation(writingTo: event.calendarID, creating: false, in: database)
            ?? EventMutationUseCases.recurrenceViolation(editing: event, in: database)
    }

    // MARK: - Sync status (spec 3D.8, `SRC-STAT-01`)

    /// Spec 3.21: a failed mutation must remain user-visible, and a conflict the user dismissed
    /// by accident must stay findable. These are what `SRC-STAT-01` reads.
    var outboxRowsNeedingAttention: [PendingMutation] {
        pendingMutations
            .filter { $0.status == .failed || $0.status == .conflicted || $0.status == .parked }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var outboxDepthByStatus: [MutationStatus: Int] {
        Dictionary(grouping: pendingMutations, by: \.status).mapValues(\.count)
    }

    /// The event a stuck mutation is about, for a surface that has to name it.
    ///
    /// Falls back to the outbox payload once the row is gone — a failed *delete* has no event
    /// left to look up, and "some event you deleted" is not something a user can act on.
    func eventTitle(forMutation mutation: PendingMutation) -> String {
        if let event = events.first(where: { $0.id == mutation.objectID }) {
            return event.displayTitle
        }
        if let payload = mutation.payload, let decoded = CalendarEvent(snapshotJSON: payload) {
            return decoded.displayTitle
        }
        return CalendarEvent.untitledPlaceholder
    }

    /// Spec 3.21/3D.8's "try again". Puts a stuck row back in the queue, by the user's explicit
    /// choice rather than by a schedule.
    ///
    /// `createdAt` is reset because it is the anchor `RetryPolicy` measures its 24-hour ceiling
    /// from, and that ceiling exists to stop *unattended* retrying against a wall. A user asking
    /// for another attempt is not that: without the reset, a row that failed two days ago would
    /// be refused before it was tried, and the button would appear to do nothing.
    @discardableResult
    func retryMutation(_ mutation: PendingMutation, now: Date = .now) -> Bool {
        guard let stored = pendingMutations.first(where: { $0.id == mutation.id }) else { return false }

        var retried = stored
        retried.status = .pending
        retried.attemptCount = 0
        retried.nextRetryAt = nil
        retried.failureClass = nil
        retried.createdAt = now
        return withPersistedMutation(EngineTransaction(outboxRows: [retried]))
    }

    // MARK: - Device event mirroring (spec 3C.8, Phase 3C)

    /// Spec 3B.0/3C.0/3D.2: one pass over everything the device owes us and everything we owe
    /// the device, on the triggers Phase 3B established — a foreground transition, a fresh grant,
    /// or a device-calendar surface appearing.
    ///
    /// The order is not arbitrary:
    ///
    /// 1. **Calendars**, because an event whose calendar is not mirrored yet has nowhere to go.
    /// 2. **Our writes**, because a queued local edit should reach the device before we read the
    ///    device back — otherwise the mirror pass sees the pre-edit state, writes it over the
    ///    local row, and the user watches their change revert before it is sent.
    /// 3. **The mirror**, which then reconciles against a device that already has our changes.
    func refreshDeviceCalendars(now: Date = .now) async {
        discoverDeviceCalendars(now: now)
        await drainDeviceWrites(now: now)
        await mirrorDeviceEvents(now: now)
    }

    /// Spec 3.18/3D.2: the write-back drain — plan, perform, commit.
    ///
    /// Driven from the store rather than through `MutationProcessorActor`, which spec 3D.2
    /// originally named. The actor loads and writes through the repository directly, behind the
    /// store's back; a receipt written that way would leave `events` stale until the next full
    /// reload, and the user would keep seeing an event marked pending after it had synced. The
    /// property the actor exists to protect — that launch is not blocked on EventKit — is
    /// supplied here by the seam itself being `async`, and by nothing calling this during
    /// `load()`.
    @discardableResult
    func drainDeviceWrites(now: Date = .now) async -> Bool {
        refreshDeviceCalendarAccess()
        guard calendarAccessStatus.canCreateDeviceEvents else {
            // Nothing is attempted, so nothing is claimed. The rows stay pending and the next
            // pass with access will find them — spec 3D.1's rule, one level up.
            return true
        }

        // Spec 3D.6: access is back, so anything parked for want of it goes back in the queue.
        // Done before planning, so a resumed row is drained by this pass rather than the next.
        let resumed = DeviceWriteCommitter.unpark(in: database, now: now)
        if !resumed.isEmpty, !withPersistedMutation(resumed) {
            return false
        }

        // Spec 3D.4: the patch set comes from the change journal, which is append-only storage
        // rather than part of the in-memory database, so it is read before planning begins.
        let journalEntryIDs = DeviceWritePlanner.journalEntryIDs(in: database, now: now)
        let fieldDiffs = (try? repository.changeJournalFieldDiffs(forEntryIDs: journalEntryIDs)) ?? [:]
        // Spec 3.22: and the state each edit was based on, which is what makes "did the device
        // change a field I am also changing" answerable at all.
        let baseSnapshots = (try? repository.eventVersionSnapshots(forJournalEntryIDs: journalEntryIDs)) ?? [:]
        let planned = DeviceWritePlanner.plan(database: database, fieldDiffs: fieldDiffs, baseSnapshots: baseSnapshots, now: now)
        guard !planned.isEmpty else { return true }

        // Marked in flight *before* any device write is issued, so a crash mid-drain is
        // distinguishable from a create that was never attempted (spec 3D.3).
        let inFlight = DeviceWriteCommitter.markInFlight(planned.writes, in: database, now: now)
        if !inFlight.isEmpty, !withPersistedMutation(inFlight) {
            return false
        }

        let outcomes = await DeviceMutationAdapter(store: eventKitStore).perform(planned.writes)
        let result = DeviceWriteCommitter.commit(planned, outcomes: outcomes, in: database, now: now)
        lastWriteBackSummary = result.summary
        guard !result.transaction.isEmpty else { return true }

        let committed = withPersistedMutation(result.transaction)

        // Spec 3D.5: after a scope write, re-mirror the series rather than trusting the local
        // projection. EventKit performs its own split, and `RecurrenceSplitter`'s version of it
        // is a prediction — the device is the authority for what the series now looks like.
        if committed, planned.writes.contains(where: DeviceWritePlanner.addressesAnOccurrence) {
            await mirrorDeviceEvents(now: now)
        }

        return committed
    }

    /// Spec 3C.8: mirrors the device's events for one bounded window into local rows, through
    /// `DeviceEventMirror`.
    ///
    /// `async` because the fetch is bounded by the size of the user's calendar and spec 3.27
    /// requires that rendering never block on it; the planning and the write are back on the
    /// caller's actor, where every other store mutation happens.
    ///
    /// Returns `false` only when the *write* failed. A failed fetch is not an error state the
    /// user is told about: nothing is lost by a pass that did not run, and raising the data-error
    /// alert on every foreground for a transient store failure would be worse than the failure.
    @discardableResult
    func mirrorDeviceEvents(in requestedWindow: DateInterval? = nil, now: Date = .now) async -> Bool {
        refreshDeviceCalendarAccess()
        // Spec 3.4/BC-EK-003: below full access there is nothing to read, and an empty fetch
        // result must never be mistaken for an empty device — so the pass does not run at all
        // rather than running and concluding every mirrored event was deleted.
        guard calendarAccessStatus.canReadDeviceEvents else { return true }

        let fetchable = DeviceEventMirror.fetchableCalendars(from: calendars)
        guard !fetchable.isEmpty else { return true }

        let window = requestedWindow ?? DeviceEventMirror.defaultWindow(around: now)
        let identifiers = Set(fetchable.compactMap(\.providerCalendarID))
        guard !identifiers.isEmpty else { return true }

        let devices: [DeviceEvent]
        do {
            devices = try await eventKitStore.events(in: window, calendarIdentifiers: identifiers)
        } catch {
            PrivacyLog.debug("Device event fetch failed")
            return false
        }

        let plan = DeviceEventMirror.plan(
            DeviceEventMirror.Input(
                devices: devices,
                window: window,
                // The calendars actually fetched, not the ones that exist. This set is what the
                // bounded-window rule tests deletions against, so it has to be the truth about
                // what was asked rather than a re-derivation that could drift from it.
                fetchedCalendarIDs: Set(fetchable.map(\.id)),
                calendars: calendars,
                existingEvents: events,
                existingExceptions: recurrenceExceptions,
                tombstones: deletedEventTombstones,
                deviceTimeZoneIdentifier: TimeZone.current.identifier
            ),
            now: now
        )

        lastEventMirrorSummary = plan.summary
        lastEventMirrorWindow = window
        guard !plan.isEmpty else { return true }

        // The same atomic path a user edit takes — and, like discovery, carrying no outbox row:
        // this is a change arriving *from* the device, not one to send to it. Notification
        // reconciliation runs inside it, which is where BC-EK-016 is actually enforced: the
        // planner excludes every `.device` calendar, so a mirrored event's alarms produce no
        // local requests however many of them there are.
        return withPersistedMutation(plan.transaction)
    }

    /// Spec 3.2: an inbound change writes through the *same* `EngineTransaction` path as a user
    /// edit, so it is atomic and journalled — but it carries `source: .reconciliation`, because
    /// the journal has to distinguish "the user did this" from "the device told us this", and it
    /// enqueues **no outbox row**: this is a change arriving *from* the device, not one to send
    /// to it.
    private func applyDiscovery(_ plan: DeviceCalendarMirror.Plan, now: Date) -> Bool {
        let existingByID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        var journalEntries: [ChangeJournalEntry] = []

        for change in plan.changes {
            guard case .upsertCalendar(let calendar) = change else { continue }
            let previous = existingByID[calendar.id]
            journalEntries.append(
                ChangeJournalEntry(
                    id: UUID(),
                    entityType: .calendar,
                    entityID: calendar.id,
                    operation: previous == nil ? .create : .update,
                    fieldDiff: FieldDiff.compute(from: previous, to: calendar),
                    source: .reconciliation,
                    occurredAt: now,
                    appliedMutationID: nil
                )
            )
        }

        return withPersistedMutation(EngineTransaction(entityChanges: plan.changes, journalEntries: journalEntries))
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
        case .rejected(let violation):
            // Spec 3.10: nothing was written, locally or anywhere else, so there is nothing to
            // roll back — only something to explain.
            lastError = violation.message
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

        // Spec 3B.3/ADR 0005: the only calendar-level changes Better Calendar makes to a
        // mirrored row are its local-only fields — `isVisible`, `isDefault`, `sortOrder` — and
        // those are ours, never the provider's. An outbox row here would mean "push this
        // calendar change to the device", which Phase 3B does not do and Phase 3D must not
        // start doing by accident. The journal entry still records that the user did it.
        let isMirrored = calendars.first { $0.id == journalEntityID }?.connectionMethod == .device
        let outboxRows = isMirrored
            ? []
            : [PendingMutation(id: UUID(), objectID: journalEntityID, objectType: .calendar, operation: outboxOperation, createdAt: .now, changeJournalEntryID: entry.id)]

        return withPersistedMutation(EngineTransaction(entityChanges: changes, outboxRows: outboxRows, journalEntries: [entry]))
    }

    /// Builds `.upsertCalendar` changes for whichever calendar needs `isDefault` set so exactly
    /// one calendar in `candidateCalendars` ends up marked default. Empty when the invariant
    /// already holds — the common case, since every mutation that could break it (deleting the
    /// default calendar, clearing `isDefault` via `updateCalendar`) is rare.
    /// Whether an edit touches anything the provider owns (spec 3B.3's field-ownership split).
    /// Local calendars own everything, so this is always `false` for them.
    private func changesProviderOwnedFields(of stored: BetterCalendar, to edited: BetterCalendar) -> Bool {
        guard stored.connectionMethod == .device else { return false }
        return edited.name != stored.name
            || edited.colorName != stored.colorName
            || edited.colorHex != stored.colorHex
            || edited.isReadOnly != stored.isReadOnly
            || edited.capabilities != stored.capabilities
            || edited.accountName != stored.accountName
            || edited.provider != stored.provider
            || edited.providerAccountID != stored.providerAccountID
            || edited.providerCalendarID != stored.providerCalendarID
    }

    private func defaultCalendarCorrections(for candidateCalendars: [BetterCalendar]) -> [EntityChange] {
        // Spec 3B.5: never hand the default to a read-only or unavailable calendar. Falls back
        // to the first calendar of any kind only when nothing at all is writable, which is the
        // same degenerate case `defaultCalendarID` guards.
        let preferred = candidateCalendars.first(where: \.isWritableDestination) ?? candidateCalendars.first
        guard !candidateCalendars.contains(where: \.isDefault), var target = preferred else {
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

        // Spec 3B.5: the same "never a read-only or unavailable default" rule as
        // `defaultCalendarCorrections`, applied at launch.
        let preferredID = (calendars.first(where: \.isWritableDestination) ?? calendars.first)?.id
        if !calendars.contains(where: \.isDefault), let preferredID {
            for index in calendars.indices {
                calendars[index].isDefault = calendars[index].id == preferredID
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

    /// Spec 3D.4: the `FieldDiff` each of these journal entries recorded, keyed by entry id.
    ///
    /// The change journal is append-only storage, not part of `LocalCalendarDatabase` — the
    /// in-memory database mirrors what the UI shows, not the durable history. So the write-back
    /// planner, which needs to know *what the user's edit actually touched*, reads it through
    /// here rather than through the snapshot.
    ///
    /// Defaulted to empty: a repository with no journal is not an error, it is a repository whose
    /// callers fall back to writing every modelled field. That is the pre-journal behaviour and
    /// it is still correct, just less surgical.
    func changeJournalFieldDiffs(forEntryIDs entryIDs: Set<UUID>) throws -> [UUID: String]

    /// Spec 2.9/3.22: the full snapshot of what each of these journal entries *superseded* —
    /// the state the edit was based on, keyed by journal entry id.
    ///
    /// `EventVersion` has recorded this on every committed update since Phase 2 M2, and Phase 3D
    /// is its first reader. It is what makes the concurrency check in spec 3.22 answerable: to
    /// know whether the device changed a field this edit also changes, you have to know what that
    /// field looked like when the edit was made — and the local row no longer says, because the
    /// edit itself changed it.
    func eventVersionSnapshots(forJournalEntryIDs entryIDs: Set<UUID>) throws -> [UUID: String]
}

extension LocalCalendarRepository {
    func changeJournalFieldDiffs(forEntryIDs entryIDs: Set<UUID>) throws -> [UUID: String] { [:] }
    func eventVersionSnapshots(forJournalEntryIDs entryIDs: Set<UUID>) throws -> [UUID: String] { [:] }
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
