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

    func load() {
        do {
            let database = try repository.load()
            apply(database)
            ensureDefaultCalendar()
            lastError = nil
            purgeExpiredTombstones()
            reconcileNotifications()
        } catch {
            let fallback = LocalCalendarDatabase.seed
            apply(fallback)
            lastError = "Calendar data could not be loaded. Sample local data is being shown while the existing file is left available for recovery."
            reconcileNotifications()
        }
    }

    func saveEvent(from draft: EventDraft) -> Bool {
        guard draft.validationError == nil else { return false }

        let now = Date.now
        let reminders = reminderRecords(for: draft)
        let recurrence = draft.recurrence.frequency == .never ? nil : draft.recurrence
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let didSave = withPersistedMutation {
            if let eventID = draft.id, let index = events.firstIndex(where: { $0.id == eventID }) {
                events[index].title = trimmedTitle
                events[index].calendarID = draft.calendarID
                events[index].startDate = draft.startDate
                events[index].endDate = normalizedEndDate(for: draft)
                events[index].isAllDay = draft.isAllDay
                events[index].timeZoneIdentifier = draft.timeZoneIdentifier
                events[index].location = draft.location.nilIfBlank
                events[index].urlString = draft.urlString.nilIfBlank
                events[index].notes = draft.notes.nilIfBlank
                events[index].reminders = reminders
                events[index].recurrence = recurrence
                events[index].providerMetadata.syncStatus = .pendingUpdate
                events[index].updatedAt = now
                recordMutation(objectID: eventID, objectType: .event, operation: .update)
            } else {
                // A non-nil `draft.id` here means this is a "This Event" occurrence seed
                // (BC-REC-010) whose id was pre-minted by `seedForOccurrenceEdit` but doesn't
                // exist in `events` yet — honour it so the new replacement gets a stable id
                // rather than a second, throwaway one.
                let eventID = draft.id ?? UUID()
                events.append(
                    CalendarEvent(
                        id: eventID,
                        calendarID: draft.calendarID,
                        title: trimmedTitle,
                        startDate: draft.startDate,
                        endDate: normalizedEndDate(for: draft),
                        isAllDay: draft.isAllDay,
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
                )
                recordMutation(objectID: eventID, objectType: .event, operation: .create)

                if let masterID = draft.recurrenceMasterID, let originalStart = draft.recurrenceOriginalStart,
                   let masterEvent = events.first(where: { $0.id == masterID }) {
                    recurrenceExceptions.append(
                        RecurrenceException(
                            id: UUID(),
                            masterEventID: masterID,
                            originalOccurrenceStart: masterEvent.isAllDay ? nil : originalStart,
                            originalOccurrenceLocalDate: masterEvent.isAllDay ? masterEvent.localDateString(for: originalStart) : nil,
                            exceptionType: .modified,
                            replacementEventID: eventID
                        )
                    )
                }
            }

            sortEvents()
        }

        if didSave && !reminders.isEmpty {
            reconcileNotifications(authorizationRequestPolicy: .ifNeeded)
        }

        return didSave
    }

    func deleteEvent(_ event: CalendarEvent) {
        let didDelete = withPersistedMutation {
            events.removeAll { $0.id == event.id }
            deletedEventTombstones.append(
                DeletedEventTombstone(
                    id: UUID(),
                    eventID: event.id,
                    title: event.title,
                    deletedAt: .now,
                    eventSnapshotJSON: event.encodedSnapshotJSON(),
                    deletionSyncedAt: nil
                )
            )
            recordMutation(objectID: event.id, objectType: .event, operation: .delete)
            undoAction = UndoAction(message: "Deleted \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
                self?.withPersistedMutation {
                    self?.events.append(event)
                    self?.sortEvents()
                    self?.deletedEventTombstones.removeAll { $0.eventID == event.id }
                }
            }
        }
        if didDelete {
            notificationScheduler.cancelNotifications(for: [event.id])
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

        let didDelete = withPersistedMutation {
            if let existingReplacement {
                events.removeAll { $0.id == existingReplacement.id }
            }
            recurrenceExceptions.append(exception)
            recordMutation(objectID: masterEvent.id, objectType: .event, operation: .update)
            undoAction = UndoAction(message: "Deleted this occurrence of \"\(masterEvent.title)\"", actionTitle: "Undo") { [weak self] in
                self?.withPersistedMutation {
                    self?.recurrenceExceptions.removeAll { $0.id == exception.id }
                    if let existingReplacement {
                        self?.events.append(existingReplacement)
                        self?.sortEvents()
                    }
                }
            }
        }
        if didDelete, let existingReplacement {
            notificationScheduler.cancelNotifications(for: [existingReplacement.id])
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

        return withPersistedMutation {
            events.append(restoredEvent)
            sortEvents()
            deletedEventTombstones.removeAll { $0.id == tombstone.id }
            recordMutation(objectID: restoredEvent.id, objectType: .event, operation: .create)
        }
    }

    func moveEvent(_ event: CalendarEvent, to newStartDate: Date) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        let originalEvent = events[index]

        withPersistedMutation {
            guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
            events[index].startDate = newStartDate
            events[index].endDate = newStartDate.addingTimeInterval(max(originalEvent.duration, 15 * 60))
            events[index].updatedAt = .now
            events[index].providerMetadata.syncStatus = .pendingUpdate
            recordMutation(objectID: event.id, objectType: .event, operation: .update)
            sortEvents()
            undoAction = UndoAction(message: "Moved \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                self.withPersistedMutation {
                    guard let currentIndex = self.events.firstIndex(where: { $0.id == originalEvent.id }) else { return }
                    self.events[currentIndex] = originalEvent
                    self.sortEvents()
                }
            }
        }
    }

    func resizeEvent(_ event: CalendarEvent, startDate: Date, endDate: Date) {
        guard endDate > startDate,
              let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        let originalEvent = events[index]

        withPersistedMutation {
            guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
            events[index].startDate = startDate
            events[index].endDate = endDate
            events[index].updatedAt = .now
            events[index].providerMetadata.syncStatus = .pendingUpdate
            recordMutation(objectID: event.id, objectType: .event, operation: .update)
            sortEvents()
            undoAction = UndoAction(message: "Resized \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                self.withPersistedMutation {
                    guard let currentIndex = self.events.firstIndex(where: { $0.id == originalEvent.id }) else { return }
                    self.events[currentIndex] = originalEvent
                    self.sortEvents()
                }
            }
        }
    }

    func duplicateEvent(_ event: CalendarEvent, startDate: Date? = nil, includeRecurrence: Bool = false) {
        let duplicateStartDate = startDate ?? event.startDate
        let duplicateEndDate = duplicateStartDate.addingTimeInterval(max(event.duration, event.isAllDay ? 24 * 60 * 60 : 15 * 60))
        let now = Date.now

        withPersistedMutation {
            let duplicate = CalendarEvent(
                id: UUID(),
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
                providerMetadata: ProviderMetadata.local,
                createdAt: now,
                updatedAt: now
            )
            events.append(duplicate)
            recordMutation(objectID: duplicate.id, objectType: .event, operation: .create)
            sortEvents()
            undoAction = UndoAction(message: "Duplicated \"\(event.title)\"", actionTitle: "Undo") { [weak self] in
                self?.withPersistedMutation {
                    self?.events.removeAll { $0.id == duplicate.id }
                }
            }
        }
    }

    func addCalendar(named name: String, colorName: CalendarColorName) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        withPersistedMutation {
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
            calendars.append(calendar)
            recordMutation(objectID: calendar.id, objectType: .calendar, operation: .create)
            ensureDefaultCalendar()
        }
    }

    func updateCalendar(_ calendar: BetterCalendar) {
        guard let index = calendars.firstIndex(where: { $0.id == calendar.id }) else { return }
        withPersistedMutation {
            calendars[index] = calendar
            calendars[index].updatedAt = .now
            recordMutation(objectID: calendar.id, objectType: .calendar, operation: .update)
            ensureDefaultCalendar()
        }
    }

    func setDefaultCalendar(_ calendar: BetterCalendar) {
        withPersistedMutation {
            for index in calendars.indices {
                calendars[index].isDefault = calendars[index].id == calendar.id
                calendars[index].updatedAt = .now
            }
            recordMutation(objectID: calendar.id, objectType: .calendar, operation: .update)
        }
    }

    /// Reorders calendars per a drag gesture's `.onMove` offsets/destination (spec 1.3), then
    /// renumbers `sortOrder` sequentially so it stays a stable, persisted ordering rather than
    /// being re-derived from array position at save time.
    ///
    /// This is a manual reimplementation of `Array.move(fromOffsets:toOffset:)` — that method
    /// is a SwiftUI extension, and the Data layer must not import SwiftUI.
    func reorderCalendars(fromOffsets source: IndexSet, toOffset destination: Int) {
        withPersistedMutation {
            var reordered = calendars
            let itemsToMove = source.map { reordered[$0] }
            for index in source.sorted(by: >) {
                reordered.remove(at: index)
            }
            let adjustedDestination = destination - source.filter { $0 < destination }.count
            reordered.insert(contentsOf: itemsToMove, at: adjustedDestination)

            calendars = reordered
            for index in calendars.indices {
                calendars[index].sortOrder = index
                calendars[index].updatedAt = .now
            }
        }
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
        withPersistedMutation {
            calendars[index].isVisible.toggle()
            calendars[index].updatedAt = .now
            recordMutation(objectID: calendar.id, objectType: .calendar, operation: .update)
        }
    }

    func deleteCalendar(_ calendar: BetterCalendar, moveEventsTo replacementID: UUID?) {
        guard !calendar.isDefault || replacementID != nil else { return }
        withPersistedMutation {
            let affectedEvents = events.filter { $0.calendarID == calendar.id }

            if let replacementID {
                for index in events.indices where events[index].calendarID == calendar.id {
                    events[index].calendarID = replacementID
                    events[index].updatedAt = .now
                    recordMutation(objectID: events[index].id, objectType: .event, operation: .update)
                }
            } else {
                events.removeAll { $0.calendarID == calendar.id }
                for event in affectedEvents {
                    deletedEventTombstones.append(
                        DeletedEventTombstone(
                            id: UUID(),
                            eventID: event.id,
                            title: event.title,
                            deletedAt: .now,
                            eventSnapshotJSON: event.encodedSnapshotJSON(),
                            deletionSyncedAt: nil
                        )
                    )
                    recordMutation(objectID: event.id, objectType: .event, operation: .delete)
                }
            }

            calendars.removeAll { $0.id == calendar.id }
            recordMutation(objectID: calendar.id, objectType: .calendar, operation: .delete)
            ensureDefaultCalendar()
        }
    }

    /// Applies a settings change through the same persist-then-rollback-on-failure path as
    /// every other mutation (BC-SET-001, spec 1.20).
    @discardableResult
    func updateSettings(_ mutate: (inout AppSettings) -> Void) -> Bool {
        withPersistedMutation {
            mutate(&settings)
        }
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
    @discardableResult
    func deleteAllLocalData() -> Bool {
        withPersistedMutation {
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
        return withPersistedMutation {
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
        let expander = RecurrenceExpander()

        return visibleEvents
            .flatMap { event in
                expander.occurrences(of: event, in: paddedRange, exceptions: recurrenceExceptions.filter { $0.masterEventID == event.id })
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

    func exportICS() -> String {
        ICSCalendarCodec.export(events: events, calendars: calendars)
    }

    func importICS(_ text: String) -> ImportSummary {
        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: defaultCalendarID)
        guard !summary.events.isEmpty else { return summary }

        let duplicateCount = summary.events.filter { event in
            events.contains { $0.title == event.title && $0.startDate == event.startDate }
        }.count
        let newEvents = summary.events.filter { event in
            !events.contains { $0.title == event.title && $0.startDate == event.startDate }
        }

        guard !newEvents.isEmpty else {
            return ImportSummary(importedCount: 0, skippedCount: summary.skippedCount + duplicateCount, failedCount: summary.failedCount, events: [])
        }

        let didSave = withPersistedMutation {
            for event in newEvents {
                events.append(event)
                recordMutation(objectID: event.id, objectType: .event, operation: .create)
            }
            sortEvents()
        }

        if didSave {
            return ImportSummary(importedCount: newEvents.count, skippedCount: summary.skippedCount + duplicateCount, failedCount: summary.failedCount, events: newEvents)
        }

        return ImportSummary(importedCount: 0, skippedCount: summary.skippedCount + duplicateCount, failedCount: summary.failedCount + newEvents.count, events: [])
    }

    @discardableResult
    private func withPersistedMutation(_ mutate: () -> Void) -> Bool {
        let previousDatabase = database
        let previousUndoAction = undoAction

        mutate()

        guard persist() else {
            apply(previousDatabase)
            undoAction = previousUndoAction
            return false
        }

        return true
    }

    private func recordMutation(objectID: UUID, objectType: MutationObjectType, operation: MutationOperation) {
        pendingMutations.append(PendingMutation(id: UUID(), objectID: objectID, objectType: objectType, operation: operation, createdAt: .now))
    }

    /// Spec 0.12: "retain soft-deleted data for a cleanup period." The spec gives no exact
    /// number, so 30 days is used as a reasonable, generous recovery window.
    private static let tombstoneRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private func purgeExpiredTombstones(now: Date = .now) {
        let expirationCutoff = now.addingTimeInterval(-Self.tombstoneRetentionInterval)
        guard deletedEventTombstones.contains(where: { $0.deletedAt < expirationCutoff }) else { return }

        withPersistedMutation {
            deletedEventTombstones.removeAll { $0.deletedAt < expirationCutoff }
        }
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
    func save(_ database: LocalCalendarDatabase) throws
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

    func save(_ database: LocalCalendarDatabase) throws {
        let fileURL = try databaseURL()
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try protectExistingFileBeforeOverwrite(at: fileURL)
        let data = try JSONEncoder.calendarEncoder.encode(database)
        try data.write(to: fileURL, options: [.atomic])
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
