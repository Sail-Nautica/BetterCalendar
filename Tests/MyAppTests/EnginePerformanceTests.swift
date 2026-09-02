import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 2.19's engine performance targets, each asserted as an explicit wall-clock bound
/// (`XCTAssertLessThan` on a measured interval) rather than an XCTest baseline — baselines are
/// machine-specific and unusable in CI, per the plan.
final class EnginePerformanceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func elapsedTime(_ block: () throws -> Void) rethrows -> TimeInterval {
        let start = Date()
        try block()
        return Date().timeIntervalSince(start)
    }

    // MARK: - Conflict recomputation (target: < 50ms at 10,000 events)

    func testConflictRecomputeAfterASingleEventMoveStaysUnder50MillisecondsAt10kEvents() {
        let fixture = TestData.largeEventSet(count: 10_000)
        let index = ConflictIndex(events: fixture.events)
        let target = fixture.events[5_000]
        var moved = target
        moved.startDate = target.startDate.addingTimeInterval(3600)
        moved.endDate = target.endDate.addingTimeInterval(3600)

        let elapsed = elapsedTime {
            _ = index.reindex(movedFrom: target, to: moved)
        }

        XCTAssertLessThan(elapsed, 0.05, "spec 2.19: conflict recompute after a single move must stay under 50ms at 10,000 events")
    }

    // MARK: - Free/busy (target: < 100ms over a one-week range)

    func testFreeBusyQueryOverAOneWeekRangeStaysUnder100MillisecondsAt10kEvents() {
        let fixture = TestData.largeEventSet(count: 10_000)
        let query = FreeBusy.Query(rangeStart: TestData.date("2026-06-01T00:00:00Z"), rangeEnd: TestData.date("2026-06-08T00:00:00Z"))

        var result: [DateInterval] = []
        let elapsed = elapsedTime {
            result = FreeBusy.query(query, events: fixture.events, exceptions: fixture.exceptions)
        }

        XCTAssertFalse(result.isEmpty, "sanity check: the fixture's events actually land in this window")
        XCTAssertLessThan(elapsed, 0.1, "spec 2.19: a one-week free/busy query must stay under 100ms at 10,000 events")
    }

    // MARK: - Outbox drain (target: < 2s for 500 queued mutations)

    @MainActor
    func testOutboxDrainOf500QueuedMutationsStaysUnder2Seconds() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EnginePerformanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let repository = SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))

        var events: [CalendarEvent] = []
        var mutations: [PendingMutation] = []
        let base = TestData.date("2026-09-02T14:00:00Z")
        for index in 0..<500 {
            let event = TestData.event(id: UUID(), title: "Event \(index)", startDate: base.addingTimeInterval(TimeInterval(index) * 60), endDate: base.addingTimeInterval(TimeInterval(index) * 60 + 1800))
            events.append(event)
            mutations.append(PendingMutation(id: UUID(), objectID: event.id, objectType: .event, operation: .create, createdAt: TestData.date("2026-09-01T00:00:00Z")))
        }
        try repository.save(TestData.database(events: events, pendingMutations: mutations))

        var summary: MutationProcessor.Summary?
        let elapsed = try elapsedTime {
            summary = try MutationProcessor.reconcile(repository: repository, now: TestData.date("2026-09-01T00:01:00Z"))
        }

        XCTAssertEqual(summary?.retired, 500, "sanity check: every queued mutation was actually processed")
        XCTAssertLessThan(elapsed, 2.0, "spec 2.19: draining 500 queued mutations must stay under 2 seconds")
    }

    // MARK: - Recurrence expansion (target: < 100ms per series over a two-year window)

    func testRecurrenceExpansionOverATwoYearWindowStaysUnder100MillisecondsPerSeries() {
        let event = TestData.event(
            startDate: TestData.date("2026-01-01T09:00:00Z"),
            endDate: TestData.date("2026-01-01T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday, .friday], end: .never)
        )
        let window = DateInterval(start: TestData.date("2026-01-01T00:00:00Z"), end: TestData.date("2028-01-01T00:00:00Z"))
        let expander = RecurrenceExpander()

        var occurrences: [CalendarOccurrence] = []
        let elapsed = elapsedTime {
            occurrences = expander.occurrences(of: event, in: window, exceptions: [])
        }

        XCTAssertFalse(occurrences.isEmpty)
        XCTAssertLessThan(elapsed, 0.1, "spec 2.19: recurrence expansion over a two-year window must stay under 100ms per series")
    }

    // MARK: - Migration (target: < 5s for a 10,000-event database from the earliest schema)

    /// Builds a database at the v002-era schema (the same column set `MigrationTests` uses,
    /// since that is what an installed Phase 1 build would actually have on disk) with 10,000
    /// plain timed events, then times only the forward migration to the latest schema — not the
    /// insert loop that seeds the fixture.
    func testMigratingA10000EventDatabaseFromTheEarliestSchemaStaysUnder5Seconds() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EnginePerformanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: directory.appending(path: "BetterCalendar.sqlite").path, configuration: configuration)
        try SQLiteCalendarRepository.makeMigrator().migrate(queue, upTo: "v002_create_events")

        let calendarID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO calendars (
                        id, provider, provider_account_id, provider_calendar_id, name, color_hex,
                        is_visible, is_read_only, is_default, time_zone_id, sort_order,
                        created_at, updated_at, deleted_at
                    )
                    VALUES (?, 'betterCalendarLocal', NULL, NULL, 'Fixture Calendar', '#4F7DFF', 1, 0, 1, NULL, 0, ?, ?, NULL)
                    """,
                arguments: [calendarID.uuidString, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z"]
            )

            let eventSQL = """
                INSERT INTO events (
                    id, calendar_id, provider, provider_object_id, provider_version,
                    title, notes, location_name, location_latitude, location_longitude, url,
                    event_type, start_instant, end_instant, start_local_date, end_local_date_exclusive,
                    original_timezone_id, availability, status, privacy, color_override,
                    recurrence_master_id, recurrence_original_start, is_recurrence_master,
                    sync_status, created_at, updated_at, deleted_at
                )
                VALUES (?, ?, 'betterCalendarLocal', NULL, NULL, ?, NULL, NULL, NULL, NULL, NULL,
                        'timed', ?, ?, NULL, NULL, 'America/Detroit', 'busy', 'confirmed', 'default', NULL,
                        NULL, NULL, 0, 'synced', ?, ?, NULL)
                """
            let created = "2026-01-02T08:00:00.000Z"
            for index in 0..<10_000 {
                let start = TestData.date("2026-02-03T14:00:00Z").addingTimeInterval(TimeInterval(index) * 1800)
                let end = start.addingTimeInterval(1800)
                try db.execute(sql: eventSQL, arguments: [
                    UUID().uuidString, calendarID.uuidString, "Event \(index)",
                    ISO8601DateFormatter().string(from: start), ISO8601DateFormatter().string(from: end),
                    created, created
                ])
            }
        }

        let elapsed = try elapsedTime {
            try SQLiteCalendarRepository.makeMigrator().migrate(queue)
        }

        let eventCount = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") }
        XCTAssertEqual(eventCount, 10_000, "sanity check: no rows were lost migrating forward")
        XCTAssertLessThan(elapsed, 5.0, "spec 2.19: migrating a 10,000-event database from the earliest schema must stay under 5 seconds")
    }
}
