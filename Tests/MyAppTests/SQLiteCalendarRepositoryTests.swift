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
