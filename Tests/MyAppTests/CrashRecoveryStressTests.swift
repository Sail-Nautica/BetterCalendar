import XCTest
@testable import Better_Calendar

/// Spec 2.20's reliability targets: "zero data loss across 1,000 simulated crash-and-restart
/// cycles" and "zero duplicate application of any mutation across 1,000 simulated forced-retry
/// cycles." The full 1,000-cycle loops are expensive enough that running them on every PR would
/// dominate CI time for no added signal (per `Instructions/phase2plan.md`'s own flagged
/// assumption), so this runs a 50-cycle smoke variant by default and the full 1,000 only when
/// `BC_STRESS=1` is set — `.github/workflows/ci.yml`'s nightly job sets it, the PR/push gates
/// don't.
final class CrashRecoveryStressTests: XCTestCase {
    private var cycleCount: Int {
        ProcessInfo.processInfo.environment["BC_STRESS"] == "1" ? 1_000 : 50
    }

    /// Each cycle: apply a create transaction (the entity write and the outbox enqueue are one
    /// atomic SQL transaction — spec 2.13 — so this alone already models "wrote to disk, then
    /// crashed before the mutation processor got a chance to run"), then run `LaunchRecovery`,
    /// standing in for the next app launch. Across every cycle, no event may be lost and none
    /// may be replayed into a duplicate.
    func testZeroDataLossAcrossManySimulatedCrashAndRestartCycles() throws {
        let fixture = try makeRepository()
        let base = TestData.date("2026-09-01T00:00:00Z")

        for index in 0..<cycleCount {
            let event = TestData.event(
                id: UUID(),
                title: "Cycle \(index)",
                startDate: base.addingTimeInterval(TimeInterval(index) * 60),
                endDate: base.addingTimeInterval(TimeInterval(index) * 60 + 1_800)
            )
            let outcome = EventMutationUseCases.createEvent(event, in: .init(database: try fixture.repository.load()))
            guard case .applied(let transaction) = outcome else { return XCTFail("cycle \(index): expected the create to apply") }
            try fixture.repository.apply(transaction)

            let recovered = LaunchRecovery.run(repository: fixture.repository)
            XCTAssertEqual(recovered.outboxSummary.retired, 1, "cycle \(index)")
        }

        let finalDatabase = try fixture.repository.load()
        XCTAssertEqual(finalDatabase.events.count, cycleCount, "no event lost or duplicated across \(cycleCount) crash/restart cycles")
        XCTAssertTrue(finalDatabase.pendingMutations.allSatisfy { $0.status == .applied }, "every mutation reconciled, none left dangling")
    }

    /// Each cycle: create an event, force one retryable failure (a stand-in for a transient
    /// provider blip once Phase 3 has a real one), then let the next reconcile succeed —
    /// confirming the retry itself never re-touches `events`/`calendars` (only the outbox row's
    /// own status, per `MutationProcessor`'s doc comment) and so can never duplicate the entity
    /// it's retrying.
    func testZeroDuplicateApplicationAcrossManyForcedRetryCycles() throws {
        let fixture = try makeRepository()
        let base = TestData.date("2026-09-01T00:00:00Z")

        for index in 0..<cycleCount {
            let event = TestData.event(
                id: UUID(),
                title: "Retry cycle \(index)",
                startDate: base.addingTimeInterval(TimeInterval(index) * 60),
                endDate: base.addingTimeInterval(TimeInterval(index) * 60 + 1_800)
            )
            let outcome = EventMutationUseCases.createEvent(event, in: .init(database: try fixture.repository.load(), now: base))
            guard case .applied(let transaction) = outcome else { return XCTFail("cycle \(index): expected the create to apply") }
            try fixture.repository.apply(transaction)

            let firstReconcile = try MutationProcessor.reconcile(repository: fixture.repository, now: base, jitter: { 0.5 }, validate: { _, _ in .retryableFailure })
            XCTAssertEqual(firstReconcile.retried, 1, "cycle \(index)")

            let secondReconcile = try MutationProcessor.reconcile(repository: fixture.repository, now: base.addingTimeInterval(60), jitter: { 0.5 })
            XCTAssertEqual(secondReconcile.retired, 1, "cycle \(index)")
        }

        let finalDatabase = try fixture.repository.load()
        XCTAssertEqual(finalDatabase.events.count, cycleCount)
        XCTAssertTrue(finalDatabase.pendingMutations.allSatisfy { $0.status == .applied }, "every mutation ends applied exactly once, even after a forced retry")
        XCTAssertEqual(Set(finalDatabase.pendingMutations.map(\.objectID)).count, cycleCount, "no mutation processed into a duplicate outbox row")
    }

    // MARK: - Fixture

    private struct RepositoryFixture {
        let repository: SQLiteCalendarRepository
        let databaseURL: URL
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeRepository() throws -> RepositoryFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "CrashRecoveryStressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database(events: []))

        return RepositoryFixture(repository: repository, databaseURL: databaseURL)
    }
}
