import GRDB
import XCTest
@testable import Better_Calendar

@MainActor
final class SQLiteCalendarRepositoryTests: XCTestCase {
    func testMigrationsCreateSpecifiedCalendarSchemaTables() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        _ = try repository.load()

        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try databaseQueue.read { db in
            let tableNames = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual')"))
            let expectedTables = [
                "calendars",
                "events",
                "event_recurrence_rules",
                "event_recurrence_exceptions",
                "event_reminders",
                "event_attachments",
                "event_links",
                "event_tags",
                "event_search",
                "pending_mutations",
                "deleted_objects",
                "application_settings",
                "schema_metadata"
            ]

            for tableName in expectedTables {
                XCTAssertTrue(tableNames.contains(tableName), "Expected table \(tableName)")
            }

            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertEqual(migrations, SQLiteCalendarRepository.migrationIdentifiers)
        }
    }

    func testAllDayEventsStoreLocalDatesInsteadOfUTCInstants() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let timeZoneID = "America/Detroit"
        var event = TestData.event(
            title: "Fall Break",
            startDate: localDate(year: 2026, month: 10, day: 12, timeZoneID: timeZoneID),
            endDate: localDate(year: 2026, month: 10, day: 14, timeZoneID: timeZoneID),
            isAllDay: true
        )
        event.timeZoneIdentifier = timeZoneID

        try repository.save(TestData.database(events: [event]))

        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try databaseQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM events WHERE id = ?", arguments: [event.id.uuidString]))
            let eventType: String = row["event_type"]
            let startInstant: String? = row["start_instant"]
            let endInstant: String? = row["end_instant"]
            let startLocalDate: String? = row["start_local_date"]
            let endLocalDateExclusive: String? = row["end_local_date_exclusive"]

            XCTAssertEqual(eventType, "allDay")
            XCTAssertNil(startInstant)
            XCTAssertNil(endInstant)
            XCTAssertEqual(startLocalDate, "2026-10-12")
            XCTAssertEqual(endLocalDateExclusive, "2026-10-14")
        }

        let loaded = try repository.load()
        let loadedEvent = try XCTUnwrap(loaded.events.first)
        XCTAssertTrue(loadedEvent.isAllDay)
        XCTAssertEqual(localDateString(loadedEvent.startDate), "2026-10-12")
        XCTAssertEqual(localDateString(loadedEvent.endDate), "2026-10-14")
    }

    func testTimedEventsStoreInstantsInsteadOfLocalDateStrings() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let event = TestData.event(
            startDate: TestData.date("2026-09-02T14:00:00Z"),
            endDate: TestData.date("2026-09-02T15:00:00Z"),
            isAllDay: false
        )

        try repository.save(TestData.database(events: [event]))

        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try databaseQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM events WHERE id = ?", arguments: [event.id.uuidString]))
            let eventType: String = row["event_type"]
            let startInstant: String? = row["start_instant"]
            let endInstant: String? = row["end_instant"]
            let startLocalDate: String? = row["start_local_date"]
            let endLocalDateExclusive: String? = row["end_local_date_exclusive"]

            XCTAssertEqual(eventType, "timed")
            XCTAssertNotNil(startInstant)
            XCTAssertNotNil(endInstant)
            XCTAssertNil(startLocalDate)
            XCTAssertNil(endLocalDateExclusive)
        }
    }

    // BC-EVT-011
    func testFloatingEventPersistsAsFloatingAndReloadsWithoutCollapsingToTimed() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let event = TestData.event(
            startDate: TestData.date("2026-09-04T00:00:00Z"),
            endDate: TestData.date("2026-09-04T01:00:00Z"),
            timeType: .floating,
            timeZoneIdentifier: "America/Detroit"
        )

        try repository.save(TestData.database(events: [event]))

        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try databaseQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM events WHERE id = ?", arguments: [event.id.uuidString]))
            let eventType: String = row["event_type"]
            let startInstant: String? = row["start_instant"]
            let startLocalDate: String? = row["start_local_date"]

            XCTAssertEqual(eventType, "floating")
            XCTAssertNotNil(startInstant, "Floating events store instants, exactly like timed events.")
            XCTAssertNil(startLocalDate)
        }

        let reloaded = try XCTUnwrap(try repository.load().events.first)
        XCTAssertEqual(reloaded.timeType, .floating, "Loading must not downgrade a stored floating event to timed.")
        XCTAssertFalse(reloaded.isAllDay)
    }

    func testSnapshotReplacementRollsBackWhenTransactionFails() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let original = TestData.database()
        try repository.save(original)

        let firstDefault = TestData.calendar(id: TestData.calendarID, name: "School", isDefault: true)
        let secondDefault = TestData.calendar(id: TestData.secondCalendarID, name: "Personal", isDefault: true)
        let invalidDatabase = TestData.database(calendars: [firstDefault, secondDefault], events: [])

        XCTAssertThrowsError(try repository.save(invalidDatabase))

        let loaded = try repository.load()
        XCTAssertEqual(loaded.calendars, original.calendars)
        XCTAssertEqual(loaded.events.map(\.id), original.events.map(\.id))
        XCTAssertEqual(loaded.events.map(\.title), original.events.map(\.title))
        XCTAssertEqual(loaded.events.map(\.calendarID), original.events.map(\.calendarID))
    }

    // BC-NOT-001
    func testEventWithThreeRemindersRoundTripsThroughSQLiteWithAllOffsetsPreserved() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let reminders = [
            EventReminder(id: UUID(), offset: .atStart),
            EventReminder(id: UUID(), offset: .minutesBefore(10)),
            EventReminder(id: UUID(), offset: .daysBefore(1))
        ]
        var event = TestData.event()
        event.reminders = reminders

        try repository.save(TestData.database(events: [event]))
        let loaded = try repository.load()

        let loadedEvent = try XCTUnwrap(loaded.events.first)
        XCTAssertEqual(loadedEvent.reminders.count, 3)
        XCTAssertEqual(Set(loadedEvent.reminders.map(\.id)), Set(reminders.map(\.id)))
        XCTAssertEqual(Set(loadedEvent.reminders.map(\.offset)), Set(reminders.map(\.offset)))
    }

    // BC-SET-001
    func testApplicationSettingsRoundTripThroughSQLite() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        var settings = AppSettings.defaultSettings
        settings.defaultEventDurationMinutes = 45
        settings.defaultReminderOffset = .minutesBefore(15)
        settings.firstWeekday = .monday
        settings.showWeekends = false
        settings.timeFormat = .twentyFourHour
        settings.defaultCalendarView = .week
        settings.allDayReminderHour = 8
        settings.snapIntervalMinutes = 10
        settings.appearance = .dark
        settings.reduceCalendarAnimation = true
        settings.hasCompletedOnboarding = true
        settings.lastSelectedTab = .agenda
        settings.lastSelectedDate = TestData.date("2026-09-05T00:00:00Z")
        settings.secondaryTimeZoneIdentifier = "America/Los_Angeles"

        var database = TestData.database(events: [])
        database.settings = settings
        try repository.save(database)

        let loaded = try repository.load()
        XCTAssertEqual(loaded.settings, settings)
    }

    // BC-SET-001
    func testUnsetOptionalSettingsRoundTripAsNilRatherThanStaleValues() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        var withOptionals = TestData.database(events: [])
        withOptionals.settings.firstWeekday = .sunday
        withOptionals.settings.lastSelectedDate = TestData.date("2026-09-05T00:00:00Z")
        try repository.save(withOptionals)

        var cleared = withOptionals
        cleared.settings.firstWeekday = nil
        cleared.settings.lastSelectedDate = nil
        try repository.save(cleared)

        let loaded = try repository.load()
        XCTAssertNil(loaded.settings.firstWeekday)
        XCTAssertNil(loaded.settings.lastSelectedDate)
    }

    // BC-SRCH-001
    func testSearchEventIDsFindsMatchesAcrossTitleNotesLocationCalendarNameAndURLHost() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let calendar = TestData.calendar(name: "Coursework")
        let titleMatch = TestData.event(id: UUID(), calendarID: calendar.id, title: "Calculus Review")
        let notesMatch = TestData.event(id: UUID(), calendarID: calendar.id, title: "Study Session", notes: "Bring calculus notes")
        let locationMatch = TestData.event(id: UUID(), calendarID: calendar.id, title: "Meeting", location: "Calculus Building")
        let urlMatch = TestData.event(id: UUID(), calendarID: calendar.id, title: "Webinar", urlString: "https://calculus.example.com/join")
        let noMatch = TestData.event(id: UUID(), calendarID: calendar.id, title: "Unrelated")

        try repository.save(TestData.database(calendars: [calendar], events: [titleMatch, notesMatch, locationMatch, urlMatch, noMatch]))

        let matches = Set(try repository.searchEventIDs(matching: "calculus"))

        XCTAssertTrue(matches.contains(titleMatch.id))
        XCTAssertTrue(matches.contains(notesMatch.id))
        XCTAssertTrue(matches.contains(locationMatch.id))
        XCTAssertTrue(matches.contains(urlMatch.id))
        XCTAssertFalse(matches.contains(noMatch.id))
    }

    // BC-SRCH-001
    func testSearchEventIDsMatchesByCalendarName() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let calendar = TestData.calendar(name: "Astronomy")
        let event = TestData.event(calendarID: calendar.id, title: "Weekly Lecture")

        try repository.save(TestData.database(calendars: [calendar], events: [event]))

        let matches = try repository.searchEventIDs(matching: "astronomy")

        XCTAssertEqual(matches, [event.id])
    }

    // BC-SRCH-001
    func testSearchEventIDsReturnsEmptyForBlankQuery() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database())

        XCTAssertTrue(try repository.searchEventIDs(matching: "   ").isEmpty)
    }

    // BC-REC-011
    func testDaysOfMonthAndSetPositionsRoundTripThroughSQLite() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let event = TestData.event(
            recurrence: RecurrenceRule(frequency: .monthly, interval: 1, weekdays: [.friday], setPositions: [-1], end: .never)
        )

        try repository.save(TestData.database(events: [event]))
        let loaded = try repository.load()

        let loadedRecurrence = try XCTUnwrap(loaded.events.first?.recurrence)
        XCTAssertEqual(loadedRecurrence.setPositions, [-1])
        XCTAssertEqual(loadedRecurrence.weekdays, [.friday])
        XCTAssertEqual(loadedRecurrence.daysOfMonth, [])
    }

    // BC-REC-010
    func testRecurrenceExceptionRoundTripsThroughSQLite() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let master = TestData.event(
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        )
        let replacement = TestData.event(
            id: UUID(),
            title: "Standup (moved room)",
            startDate: TestData.date("2026-09-14T14:00:00Z"),
            endDate: TestData.date("2026-09-14T14:30:00Z")
        )
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .modified,
            replacementEventID: replacement.id
        )

        var database = TestData.database(events: [master, replacement])
        database.recurrenceExceptions = [exception]
        try repository.save(database)

        let loaded = try repository.load()

        let loadedException = try XCTUnwrap(loaded.recurrenceExceptions.first)
        XCTAssertEqual(loadedException.masterEventID, master.id)
        XCTAssertEqual(loadedException.exceptionType, .modified)
        XCTAssertEqual(loadedException.replacementEventID, replacement.id)
        XCTAssertEqual(loadedException.originalOccurrenceStart, TestData.date("2026-09-14T14:00:00Z"))
    }

    // BC-REC-010
    func testReplacementEventRecurrenceMasterIDAndOriginalStartRoundTrip() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        // recurrence_master_id is a foreign key onto events(id), so the master must actually
        // exist in the same save.
        let master = TestData.event(
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        )
        let originalStart = TestData.date("2026-09-14T14:00:00Z")
        var replacement = TestData.event(id: UUID(), title: "Standup (moved room)")
        replacement.recurrenceMasterID = master.id
        replacement.recurrenceOriginalStart = originalStart

        try repository.save(TestData.database(events: [master, replacement]))
        let loaded = try repository.load()

        let loadedReplacement = try XCTUnwrap(loaded.events.first { $0.id == replacement.id })
        XCTAssertEqual(loadedReplacement.recurrenceMasterID, master.id)
        XCTAssertEqual(loadedReplacement.recurrenceOriginalStart, originalStart)
    }

    // BC-CAL-001
    func testCalendarSortOrderRoundTripsAndReorderPersists() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let first = TestData.calendar(id: TestData.calendarID, name: "School", isDefault: true, sortOrder: 1)
        let second = TestData.calendar(id: TestData.secondCalendarID, name: "Personal", isDefault: false, sortOrder: 0)

        try repository.save(TestData.database(calendars: [first, second], events: []))
        let loaded = try repository.load()

        XCTAssertEqual(loaded.calendars.map(\.name), ["Personal", "School"], "Calendars load ordered by sort_order, not insertion order.")
        XCTAssertEqual(loaded.calendars.map(\.sortOrder), [0, 1])
    }

    // BC-DEL-001
    func testDeletedEventTombstoneRoundTripsSnapshotJSONThroughSQLite() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        let event = TestData.event(title: "Deleted Lecture")
        let tombstone = DeletedEventTombstone(
            id: UUID(),
            eventID: event.id,
            title: event.title,
            deletedAt: TestData.date("2026-09-05T00:00:00Z"),
            eventSnapshotJSON: event.encodedSnapshotJSON(),
            deletionSyncedAt: nil
        )

        try repository.save(TestData.database(events: [], deletedEventTombstones: [tombstone]))
        let loaded = try repository.load()

        let loadedTombstone = try XCTUnwrap(loaded.deletedEventTombstones.first)
        XCTAssertEqual(loadedTombstone.id, tombstone.id)
        let restoredEvent = try XCTUnwrap(loadedTombstone.eventSnapshotJSON.flatMap(CalendarEvent.init(snapshotJSON:)))
        XCTAssertEqual(restoredEvent.id, event.id)
        XCTAssertEqual(restoredEvent.title, event.title)
    }

    private func makeTemporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCalendarSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(SQLiteCalendarRepository.databaseFileName)
    }

    private func localDate(year: Int, month: Int, day: Int, timeZoneID: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func localDateString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }
}
