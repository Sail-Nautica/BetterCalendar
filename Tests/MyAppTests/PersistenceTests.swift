import XCTest
@testable import Better_Calendar

@MainActor
final class PersistenceTests: XCTestCase {
    func testSaveEventReturnsFalseAndRollsBackWhenRepositorySaveFails() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])), saveError: TestRepositoryError.saveFailed)
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Lab"

        XCTAssertFalse(store.saveEvent(from: draft))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.pendingMutations.isEmpty)
        XCTAssertTrue(repository.savedDatabases.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testCalendarMutationRollsBackWhenRepositorySaveFails() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])), saveError: TestRepositoryError.saveFailed)
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let originalCalendarCount = store.calendars.count

        store.addCalendar(named: "Personal", colorName: .success)

        XCTAssertEqual(store.calendars.count, originalCalendarCount)
        XCTAssertTrue(store.pendingMutations.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testFailedLoadUsesSeedDataButDoesNotAttemptToSaveIt() {
        let repository = StubCalendarRepository(loadResult: .failure(TestRepositoryError.loadFailed))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        XCTAssertFalse(store.calendars.isEmpty)
        XCTAssertFalse(store.events.isEmpty)
        XCTAssertTrue(repository.savedDatabases.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testDuplicateEventCreatesStandaloneLocalCopyByDefault() {
        let recurringEvent = TestData.event(
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        )
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [recurringEvent])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        store.duplicateEvent(recurringEvent, startDate: TestData.date("2026-09-09T14:00:00Z"))

        let duplicate = store.events.first { $0.id != recurringEvent.id }
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(duplicate?.title, "Copy of \(recurringEvent.title)")
        XCTAssertEqual(duplicate?.startDate, TestData.date("2026-09-09T14:00:00Z"))
        XCTAssertNil(duplicate?.recurrence)
        XCTAssertEqual(store.pendingMutations.last?.operation, .create)
    }

    func testResizeEventPersistsUpdatedTimeRange() {
        let event = TestData.event()
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [event])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let newStart = TestData.date("2026-09-02T13:30:00Z")
        let newEnd = TestData.date("2026-09-02T15:30:00Z")

        store.resizeEvent(event, startDate: newStart, endDate: newEnd)

        XCTAssertEqual(store.events.first?.startDate, newStart)
        XCTAssertEqual(store.events.first?.endDate, newEnd)
        XCTAssertEqual(repository.savedDatabases.last?.events.first?.startDate, newStart)
        XCTAssertEqual(store.pendingMutations.last?.operation, .update)
    }

    func testLoadingCorruptJSONKeepsOriginalAndCreatesRecoveryCopy() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("BetterCalendarLocalDatabase.json")
        let corruptData = Data("not valid json".utf8)
        try corruptData.write(to: databaseURL)

        let repository = JSONCalendarRepository(fileURL: databaseURL)

        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: databaseURL), corruptData)

        let recoveryFiles = try recoveryFiles(in: directory)
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corruptData)
    }

    func testSavingOverCorruptJSONPreservesRecoveryCopyBeforeReplacingPrimaryFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("BetterCalendarLocalDatabase.json")
        let corruptData = Data("{".utf8)
        try corruptData.write(to: databaseURL)

        let repository = JSONCalendarRepository(fileURL: databaseURL)
        let database = TestData.database()

        try repository.save(database)

        let recoveryFiles = try recoveryFiles(in: directory)
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corruptData)
        XCTAssertEqual(try repository.load(), database)
    }

    // BC-NOT-001
    func testSavingEventWithDuplicateReminderOffsetsPersistsOnlyDistinctReminders() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Lab"
        draft.reminderOffsets = [.minutesBefore(10), .minutesBefore(10), .atStart]

        XCTAssertTrue(store.saveEvent(from: draft))

        let savedOffsets = store.events.first?.reminders.map(\.offset) ?? []
        XCTAssertEqual(savedOffsets, [.minutesBefore(10), .atStart])
    }

    // BC-NOT-001
    func testReminderOffsetNoneIsDroppedAmongOtherOffsetsAndNeverPersisted() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Office Hours"
        draft.reminderOffsets = [.none, .minutesBefore(30), .none]

        XCTAssertTrue(store.saveEvent(from: draft))

        let savedOffsets = store.events.first?.reminders.map(\.offset) ?? []
        XCTAssertEqual(savedOffsets, [.minutesBefore(30)])
    }

    // BC-NOT-001
    func testSavingEventWithOnlyNoneReminderOffsetPersistsNoReminders() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Office Hours"
        draft.reminderOffsets = [.none]

        XCTAssertTrue(store.saveEvent(from: draft))
        XCTAssertTrue(store.events.first?.reminders.isEmpty ?? false)
    }

    // BC-NOT-001
    func testEditingEventPreservesReminderIDForUnchangedOffsetAndAssignsNewIDOnlyToAddedReminder() throws {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Lab"
        draft.reminderOffsets = [.minutesBefore(10)]
        XCTAssertTrue(store.saveEvent(from: draft))

        let firstSavedEvent = try XCTUnwrap(store.events.first)
        let originalReminderID = try XCTUnwrap(firstSavedEvent.reminders.first?.id)

        var editDraft = EventDraft(event: firstSavedEvent)
        editDraft.reminderOffsets = [.minutesBefore(10), .daysBefore(1)]
        XCTAssertTrue(store.saveEvent(from: editDraft))

        let updatedEvent = try XCTUnwrap(store.events.first)
        XCTAssertEqual(updatedEvent.reminders.count, 2)

        let preservedReminder = try XCTUnwrap(updatedEvent.reminders.first { $0.offset == .minutesBefore(10) })
        XCTAssertEqual(preservedReminder.id, originalReminderID)

        let newReminder = try XCTUnwrap(updatedEvent.reminders.first { $0.offset == .daysBefore(1) })
        XCTAssertNotEqual(newReminder.id, originalReminderID)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCalendarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func recoveryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix("BetterCalendarLocalDatabase.unreadable-")
                    && $0.pathExtension == "json"
            }
    }
}
