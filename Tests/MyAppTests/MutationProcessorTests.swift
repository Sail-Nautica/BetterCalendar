import XCTest
@testable import Better_Calendar

/// Spec 2.2/2.12/2.13: the outbox-only "mutation processor" pipeline stage. `decide` is tested
/// directly (pure, no I/O); `reconcile` is tested against `StubCalendarRepository` to confirm
/// it persists every decision in one transaction.
final class MutationProcessorTests: XCTestCase {
    private let midpointJitter: () -> Double = { 0.5 }

    private func pendingMutation(
        objectID: UUID = UUID(),
        operation: MutationOperation = .create,
        status: MutationStatus = .pending,
        attemptCount: Int = 0,
        createdAt: Date = TestData.date("2026-09-01T00:00:00Z"),
        nextRetryAt: Date? = nil
    ) -> PendingMutation {
        PendingMutation(
            id: UUID(),
            objectID: objectID,
            objectType: .event,
            operation: operation,
            createdAt: createdAt,
            status: status,
            attemptCount: attemptCount,
            nextRetryAt: nextRetryAt
        )
    }

    // MARK: - decide

    func testValidPendingMutationIsRetiredAsApplied() {
        let mutation = pendingMutation()
        let now = TestData.date("2026-09-01T00:01:00Z")

        let decision = MutationProcessor.decide(mutation, in: TestData.database(pendingMutations: [mutation]), now: now)

        guard case .retired(let updated) = decision else {
            return XCTFail("expected .retired, got \(decision)")
        }
        XCTAssertEqual(updated.status, .applied)
        XCTAssertEqual(updated.lastAttemptAt, now)
    }

    func testAnInFlightMutationNotYetDueIsLeftUntouched() {
        let now = TestData.date("2026-09-01T00:01:00Z")
        let mutation = pendingMutation(status: .inFlight, nextRetryAt: now.addingTimeInterval(60))

        let decision = MutationProcessor.decide(mutation, in: TestData.database(pendingMutations: [mutation]), now: now)

        guard case .notDue = decision else {
            return XCTFail("expected .notDue, got \(decision)")
        }
    }

    func testAppliedAndFailedMutationsAreNeverReconsidered() {
        let now = TestData.date("2026-09-01T00:01:00Z")
        for status: MutationStatus in [.applied, .failed, .conflicted] {
            let mutation = pendingMutation(status: status)
            let decision = MutationProcessor.decide(mutation, in: TestData.database(pendingMutations: [mutation]), now: now)
            guard case .notDue = decision else {
                return XCTFail("expected .notDue for status \(status), got \(decision)")
            }
        }
    }

    func testARetryableFailureSchedulesTheNextAttemptUsingRetryPolicy() {
        let createdAt = TestData.date("2026-09-01T00:00:00Z")
        let now = createdAt
        let mutation = pendingMutation(createdAt: createdAt)

        let decision = MutationProcessor.decide(
            mutation,
            in: TestData.database(pendingMutations: [mutation]),
            now: now,
            jitter: midpointJitter,
            validate: { _, _ in .retryableFailure }
        )

        guard case .retry(let updated) = decision else {
            return XCTFail("expected .retry, got \(decision)")
        }
        XCTAssertEqual(updated.status, .inFlight)
        XCTAssertEqual(updated.attemptCount, 1)
        XCTAssertEqual(updated.nextRetryAt, now.addingTimeInterval(30))
    }

    /// BC-ENG-005's companion property: a `failed` mutation is never dropped — it stays a row
    /// in the outbox with a status a diagnostics surface can read, not deleted.
    func testAMutationPastTheRetryCeilingFailsRatherThanVanishing() {
        let createdAt = TestData.date("2026-09-01T00:00:00Z")
        let now = createdAt.addingTimeInterval(25 * 60 * 60) // past the 24h ceiling
        let mutation = pendingMutation(attemptCount: 40, createdAt: createdAt)

        let decision = MutationProcessor.decide(
            mutation,
            in: TestData.database(pendingMutations: [mutation]),
            now: now,
            jitter: midpointJitter,
            validate: { _, _ in .retryableFailure }
        )

        guard case .failed(let updated) = decision else {
            return XCTFail("expected .failed, got \(decision)")
        }
        XCTAssertEqual(updated.status, .failed)
        XCTAssertNil(updated.nextRetryAt)
        XCTAssertEqual(updated.id, mutation.id, "the row survives with the same identity, it is not replaced or removed")
    }

    // MARK: - Spec 2.13/BC-ENG-006: resurrection guard

    func testACreateMutationForATombstonedEntityIsRetiredWithoutBeingValidated() {
        let entityID = UUID()
        let mutation = pendingMutation(objectID: entityID, operation: .create)
        let tombstone = DeletedObjectTombstone(id: UUID(), entityID: entityID, title: "Deleted", deletedAt: TestData.date("2026-09-01T00:00:00Z"))
        let database = TestData.database(pendingMutations: [mutation], deletedEventTombstones: [tombstone])

        var validateWasCalled = false
        let decision = MutationProcessor.decide(mutation, in: database, now: TestData.date("2026-09-01T00:01:00Z"), validate: { _, _ in
            validateWasCalled = true
            return .valid
        })

        guard case .retired(let updated) = decision else {
            return XCTFail("expected .retired, got \(decision)")
        }
        XCTAssertEqual(updated.status, .applied)
        XCTAssertFalse(validateWasCalled, "a resurrection-guarded mutation short-circuits before validation")
    }

    func testADeleteMutationIsNotResurrectionGuardedByItsOwnTombstone() {
        let entityID = UUID()
        let mutation = pendingMutation(objectID: entityID, operation: .delete)
        let tombstone = DeletedObjectTombstone(id: UUID(), entityID: entityID, title: "Deleted", deletedAt: TestData.date("2026-09-01T00:00:00Z"))
        let database = TestData.database(pendingMutations: [mutation], deletedEventTombstones: [tombstone])

        let decision = MutationProcessor.decide(mutation, in: database, now: TestData.date("2026-09-01T00:01:00Z"))

        guard case .retired(let updated) = decision else {
            return XCTFail("expected the delete's own outbox row to still be retired normally, got \(decision)")
        }
        XCTAssertEqual(updated.status, .applied)
    }

    // MARK: - reconcile

    func testReconcilePersistsEveryDecisionInOneTransaction() throws {
        let applyMe = pendingMutation()
        let notDueYet = pendingMutation(status: .inFlight, nextRetryAt: TestData.date("2030-01-01T00:00:00Z"))
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(pendingMutations: [applyMe, notDueYet])))

        let summary = try MutationProcessor.reconcile(repository: repository, now: TestData.date("2026-09-01T00:01:00Z"))

        XCTAssertEqual(summary, MutationProcessor.Summary(retired: 1, retried: 0, failed: 0))
        XCTAssertEqual(repository.appliedTransactions.count, 1)

        let reloaded = try repository.load()
        XCTAssertEqual(reloaded.pendingMutations.first { $0.id == applyMe.id }?.status, .applied)
        XCTAssertEqual(reloaded.pendingMutations.first { $0.id == notDueYet.id }?.status, .inFlight, "not due yet — left alone")
    }

    func testReconcileIsANoOpWhenNothingIsEligible() throws {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(pendingMutations: [])))
        let summary = try MutationProcessor.reconcile(repository: repository)

        XCTAssertEqual(summary, MutationProcessor.Summary())
        XCTAssertTrue(repository.appliedTransactions.isEmpty, "no transaction should be written when there is nothing to reconcile")
    }
}
