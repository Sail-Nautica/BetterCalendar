import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 2.18's launch sequence, and BC-ENG-005/BC-ENG-006 specifically — both are properties
/// of running `LaunchRecovery.run(_:)` across simulated launches against a real SQLite file, not
/// just of the pure decision functions it composes.
final class LaunchRecoveryTests: XCTestCase {

    /// BC-ENG-005: "Every mutating operation is retried automatically after a simulated crash."
    /// In this architecture the entity write and the outbox enqueue are one atomic transaction
    /// (spec 2.13), so the only thing a crash can leave behind is an outbox row that never got
    /// to `.applied` because the processor never ran — exactly what happens between every M2
    /// use case call and the next launch. This simulates that gap directly: apply a create
    /// transaction (as `EventMutationUseCases.createEvent` would), then run `LaunchRecovery`
    /// twice, standing in for two subsequent app launches, and confirm the mutation is finalized
    /// on the first and left alone (not reprocessed, not duplicated) on the second.
    func testBC_ENG_005_APendingMutationFromASimulatedCrashIsFinalizedExactlyOnceAcrossLaunches() throws {
        let fixture = try makeRepository()
        let event = TestData.event(id: UUID(), title: "Crashed before the processor ran")

        let outcome = EventMutationUseCases.createEvent(event, in: .init(database: try fixture.repository.load()))
        guard case .applied(let transaction) = outcome else {
            return XCTFail("expected the create to apply")
        }
        try fixture.repository.apply(transaction)

        try fixture.readDatabase { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM pending_mutations WHERE object_id = ?", arguments: [event.id.uuidString]), "pending")
        }

        // Launch #1: the crash's aftermath is reconciled.
        let firstLaunch = LaunchRecovery.run(repository: fixture.repository)
        XCTAssertEqual(firstLaunch.outboxSummary.retired, 1)
        try fixture.readDatabase { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM pending_mutations WHERE object_id = ?", arguments: [event.id.uuidString]), "applied")
        }
        XCTAssertEqual(try fixture.repository.load().events.filter { $0.id == event.id }.count, 1)

        // Launch #2: nothing left to reconcile, and critically, the event is not duplicated.
        let secondLaunch = LaunchRecovery.run(repository: fixture.repository)
        XCTAssertEqual(secondLaunch.outboxSummary.retired, 0)
        XCTAssertEqual(try fixture.repository.load().events.filter { $0.id == event.id }.count, 1, "the mutation must not be replayed a second time")
    }

    func testExpiredTombstonesArePrunedDuringLaunchRecovery() throws {
        let fixture = try makeRepository()
        let event = try fixture.seedEvent()
        let now = TestData.date("2026-09-01T00:00:00Z")

        let deleteOutcome = EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: 1, in: .init(database: try fixture.repository.load(), now: now.addingTimeInterval(-31 * 24 * 60 * 60)))
        guard case .applied(let transaction) = deleteOutcome else {
            return XCTFail("expected the delete to apply")
        }
        try fixture.repository.apply(transaction)
        XCTAssertEqual(try fixture.repository.load().deletedEventTombstones.count, 1)

        let outcome = LaunchRecovery.run(repository: fixture.repository, now: now)

        XCTAssertEqual(outcome.purgedTombstoneCount, 1)
        XCTAssertTrue(outcome.database.deletedEventTombstones.isEmpty)
        XCTAssertTrue(try fixture.repository.load().deletedEventTombstones.isEmpty)
    }

    func testChecksumMismatchIsFlaggedButDataIsNotDiscarded() throws {
        let fixture = try makeRepository()
        _ = try fixture.seedEvent()

        try fixture.writeDatabase { db in
            try db.execute(sql: "UPDATE schema_metadata SET value = 'fnv1a64:deadbeefdeadbeef' WHERE key = 'migration_checksum'")
        }

        let outcome = LaunchRecovery.run(repository: fixture.repository)

        XCTAssertTrue(outcome.needsRecoveryPrompt)
        XCTAssertEqual(outcome.database.events.count, 1, "a checksum mismatch is flagged, never used as a reason to discard data")
    }

    func testRecoveryJournalEntryIsWrittenWhenTombstonesArePruned() throws {
        let fixture = try makeRepository()
        let event = try fixture.seedEvent()
        let now = TestData.date("2026-09-01T00:00:00Z")

        let deleteOutcome = EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: 1, in: .init(database: try fixture.repository.load(), now: now.addingTimeInterval(-31 * 24 * 60 * 60)))
        guard case .applied(let transaction) = deleteOutcome else {
            return XCTFail("expected the delete to apply")
        }
        try fixture.repository.apply(transaction)

        let outcome = LaunchRecovery.run(repository: fixture.repository, now: now)
        XCTAssertTrue(outcome.wroteRecoveryJournalEntry)

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE source = 'recovery'"), 1)
        }
    }

    func testNoRecoveryJournalEntryIsWrittenOnAnUneventfulLaunch() throws {
        let fixture = try makeRepository()
        _ = try fixture.seedEvent()

        let outcome = LaunchRecovery.run(repository: fixture.repository)
        XCTAssertFalse(outcome.wroteRecoveryJournalEntry)

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE source = 'recovery'"), 0)
        }
    }

    // MARK: - Store integration

    /// `BetterCalendarStore.load()` now delegates to `LaunchRecovery` — this confirms the
    /// wiring itself, not the recovery logic (covered above).
    @MainActor
    func testStoreLoadSurfacesTheRecoveryPromptThroughLastError() throws {
        let fixture = try makeRepository()
        _ = try fixture.seedEvent()
        try fixture.writeDatabase { db in
            try db.execute(sql: "UPDATE schema_metadata SET value = 'fnv1a64:deadbeefdeadbeef' WHERE key = 'migration_checksum'")
        }

        let store = BetterCalendarStore(repository: fixture.repository, notificationScheduler: NoopNotificationScheduler())

        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.events.count, 1, "the flagged database is still loaded, not replaced with seed data")
    }

    // MARK: - Fixture

    private struct RepositoryFixture {
        let repository: SQLiteCalendarRepository
        let databaseURL: URL

        func seedEvent() throws -> CalendarEvent {
            let event = TestData.event(id: UUID())
            try repository.save(TestData.database(events: [event]))
            return event
        }

        func readDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).read(body)
        }

        func writeDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).write(body)
        }
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeRepository() throws -> RepositoryFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "LaunchRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        // `repository.load()` on a freshly migrated, still-empty database returns an in-memory
        // `.seed` without persisting it — an explicit `save` is what actually gets a calendar
        // row into SQL, which every event a test creates needs a foreign key to.
        try repository.save(TestData.database(events: []))

        return RepositoryFixture(repository: repository, databaseURL: databaseURL)
    }
}
