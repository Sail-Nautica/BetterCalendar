import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3D M1: the rule that stops the outbox claiming it wrote something it never wrote, and
/// the schema the write-back needs.
///
/// The first block is the one that matters. Through Phase 3C, `MutationProcessor`'s default
/// validator returned `.valid` unconditionally — correct while every calendar was local, and
/// silently wrong from the moment Phase 3B made a writable device calendar a selectable
/// destination: a create on the user's iCloud calendar was marked `applied` on the next launch
/// having never reached EventKit. These tests are the proof that it no longer is.
final class DeviceWriteBackTests: XCTestCase {

    // MARK: - The deferral rule (spec 3D.1)

    func testAMutationBoundForADeviceCalendarIsNotRetiredWithoutAProviderAnswer() {
        let fixture = Self.deviceFixture()

        let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

        guard case .deferred = decision else {
            return XCTFail("expected .deferred, got \(decision)")
        }
        XCTAssertNil(decision.updatedMutation, "a deferred row must be written back unchanged — not at all")
    }

    /// The control case, and the one that proves the fix is surgical: nothing about Phase 1/2
    /// behaviour moves.
    func testAMutationOnALocalCalendarIsRetiredExactlyAsBefore() {
        let fixture = Self.localFixture()

        let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

        guard case .retired(let updated) = decision else {
            return XCTFail("expected .retired, got \(decision)")
        }
        XCTAssertEqual(updated.status, .applied)
    }

    /// A delete is the awkward case: by the time the row is processed the event is gone from
    /// `events`, so the calendar has to come from somewhere else or the rule silently stops
    /// applying to exactly the operation that destroys data.
    func testADeleteResolvesItsCalendarFromThePayloadOnceTheEventRowIsGone() {
        var fixture = Self.deviceFixture(operation: .delete)
        // The delete already removed the event locally, which is what the real pipeline does in
        // the same transaction that enqueues the outbox row.
        fixture.database.events = []

        let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

        guard case .deferred = decision else {
            return XCTFail("expected .deferred for a delete with no event row, got \(decision)")
        }
    }

    /// And if the payload is missing too, the tombstone's snapshot answers. Both are written in
    /// the same transaction as the delete (spec 2.13), so one of them is always there.
    func testADeleteFallsBackToTheTombstoneSnapshotWhenThePayloadIsAbsent() {
        var fixture = Self.deviceFixture(operation: .delete, includePayload: false)
        fixture.database.events = []
        fixture.database.deletedEventTombstones = [
            DeletedObjectTombstone(
                id: UUID(),
                entityType: .event,
                entityID: fixture.event.id,
                title: fixture.event.title,
                deletedAt: Self.now,
                eventSnapshotJSON: fixture.event.encodedSnapshotJSON(),
                deletionSyncedAt: nil
            )
        ]

        let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

        guard case .deferred = decision else {
            return XCTFail("expected .deferred, got \(decision)")
        }
    }

    /// An event whose calendar cannot be determined at all is treated as local, deliberately:
    /// every Phase 1/2 path stays exactly as it was, and the device case is the one that has to
    /// be positively identified rather than assumed.
    func testAnUnresolvableTargetIsTreatedAsLocalRatherThanDeferredForever() {
        var fixture = Self.deviceFixture()
        fixture.database.events = []
        fixture.mutation.payload = nil

        let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

        guard case .retired = decision else {
            return XCTFail("expected .retired, got \(decision)")
        }
    }

    func testReconcileLeavesDeviceRowsPendingAndCountsThemAsDeferred() throws {
        let fixture = Self.deviceFixture()
        let repository = StubCalendarRepository(loadResult: .success(fixture.database))

        let summary = try MutationProcessor.reconcile(repository: repository, now: Self.now)

        XCTAssertEqual(summary.deferred, 1)
        XCTAssertEqual(summary.retired, 0)
        XCTAssertTrue(repository.appliedTransactions.isEmpty, "a pass with nothing to say must write nothing")
        XCTAssertEqual(try repository.load().pendingMutations.first?.status, .pending)
    }

    /// Spec 3.18: launch reconciles the outbox *without* provider I/O, so a device row is still
    /// waiting — and still `pending` — when the adapter runs shortly afterwards.
    func testLaunchRecoveryDoesNotRetireADeviceRow() throws {
        let fixture = Self.deviceFixture()
        let repository = StubCalendarRepository(loadResult: .success(fixture.database))

        let outcome = LaunchRecovery.run(repository: repository, now: Self.now)

        XCTAssertEqual(outcome.outboxSummary.deferred, 1)
        XCTAssertEqual(outcome.outboxSummary.retired, 0)
        XCTAssertEqual(outcome.database.pendingMutations.first?.status, .pending)
    }

    /// The regression this whole milestone exists to prevent, stated as one assertion.
    func testACreateOnADeviceCalendarIsNeverMarkedAppliedWithoutReachingTheDevice() throws {
        let fixture = Self.deviceFixture()
        let repository = StubCalendarRepository(loadResult: .success(fixture.database))

        // Three launches in a row, which is what it used to take exactly one of.
        for _ in 0..<3 {
            _ = LaunchRecovery.run(repository: repository, now: Self.now)
        }

        let stored = try XCTUnwrap(try repository.load().pendingMutations.first)
        XCTAssertEqual(stored.status, .pending)
        XCTAssertEqual(stored.attemptCount, 0, "deferring is not attempting; the retry budget is untouched")
        XCTAssertNil(stored.nextRetryAt)
    }

    // MARK: - The failure taxonomy (spec 3.21 / 3D.6)

    /// Spec 3D.6's central rule: a user who denies access for a week and then re-grants it must
    /// find their queued edits waiting, not a queue that spent its 24-hour window against a wall.
    func testAPermissionFailureParksTheMutationWithoutSpendingAnAttempt() {
        let fixture = Self.deviceFixture()

        let decision = MutationProcessor.decide(
            fixture.mutation,
            in: fixture.database,
            now: Self.now,
            validate: { _, _ in .permissionFailure }
        )

        guard case .parked(let updated) = decision else {
            return XCTFail("expected .parked, got \(decision)")
        }
        XCTAssertEqual(updated.status, .parked)
        XCTAssertEqual(updated.attemptCount, 0, "a permission failure must not consume a retry attempt")
        XCTAssertNil(updated.nextRetryAt, "parking is not a scheduled retry")
        XCTAssertEqual(updated.failureClass, .permission)
        XCTAssertEqual(updated.lastFailureAt, Self.now)
    }

    func testAPermanentFailureFailsImmediatelyRatherThanRetryingAgainstAWall() {
        let fixture = Self.deviceFixture()

        let decision = MutationProcessor.decide(
            fixture.mutation,
            in: fixture.database,
            now: Self.now,
            validate: { _, _ in .permanentFailure }
        )

        guard case .failed(let updated) = decision else {
            return XCTFail("expected .failed, got \(decision)")
        }
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.failureClass, .permanent)
        XCTAssertNil(updated.nextRetryAt)
    }

    func testAConflictIsRoutedToItsOwnStatusRatherThanRetried() {
        let fixture = Self.deviceFixture()

        let decision = MutationProcessor.decide(
            fixture.mutation,
            in: fixture.database,
            now: Self.now,
            validate: { _, _ in .conflictDetected }
        )

        guard case .conflicted(let updated) = decision else {
            return XCTFail("expected .conflicted, got \(decision)")
        }
        XCTAssertEqual(updated.status, .conflicted)
        XCTAssertEqual(updated.failureClass, .conflict)
        XCTAssertNil(updated.nextRetryAt, "a conflict is not fixed by waiting")
    }

    /// The pre-existing retry path is unchanged apart from now recording *why*.
    func testATransientFailureStillRetriesOnTheExistingBackoffAndRecordsItsClass() {
        let fixture = Self.deviceFixture()

        let decision = MutationProcessor.decide(
            fixture.mutation,
            in: fixture.database,
            now: Self.now,
            jitter: { 0.5 },
            validate: { _, _ in .retryableFailure }
        )

        guard case .retry(let updated) = decision else {
            return XCTFail("expected .retry, got \(decision)")
        }
        XCTAssertEqual(updated.status, .inFlight)
        XCTAssertEqual(updated.attemptCount, 1)
        XCTAssertEqual(updated.failureClass, .transient)
        XCTAssertNotNil(updated.nextRetryAt)
    }

    /// A parked or failed row is terminal for this pass — the drain must not pick it back up on
    /// its own, or parking would be a slow retry loop wearing a different name.
    func testParkedAndFailedRowsAreNotPickedUpByAPass() {
        for status in [MutationStatus.parked, .failed, .conflicted, .applied] {
            var fixture = Self.deviceFixture()
            fixture.mutation.status = status

            let decision = MutationProcessor.decide(fixture.mutation, in: fixture.database, now: Self.now)

            guard case .notDue = decision else {
                return XCTFail("expected .notDue for \(status), got \(decision)")
            }
        }
    }

    // MARK: - Persistence (migration v021)

    func testTheWriteBackColumnsRoundTripThroughSQLite() throws {
        let repository = try makeRepository()
        let mutation = PendingMutation(
            id: UUID(),
            objectID: TestData.eventID,
            objectType: .event,
            operation: .update,
            createdAt: Self.now,
            status: .parked,
            baseProviderVersion: "801000000.000",
            failureClass: .permission,
            lastFailureAt: Self.now
        )

        try repository.save(TestData.database(pendingMutations: [mutation]))
        let stored = try XCTUnwrap(try repository.load().pendingMutations.first)

        XCTAssertEqual(stored.status, .parked)
        XCTAssertEqual(stored.baseProviderVersion, "801000000.000")
        XCTAssertEqual(stored.failureClass, .permission)
        XCTAssertEqual(stored.lastFailureAt, Self.now)
    }

    func testARowThatNeverFailedCarriesNoFailureClass() throws {
        let repository = try makeRepository()
        let mutation = PendingMutation(
            id: UUID(),
            objectID: TestData.eventID,
            objectType: .event,
            operation: .create,
            createdAt: Self.now
        )

        try repository.save(TestData.database(pendingMutations: [mutation]))
        let stored = try XCTUnwrap(try repository.load().pendingMutations.first)

        XCTAssertNil(stored.failureClass)
        XCTAssertNil(stored.lastFailureAt)
        XCTAssertNil(stored.baseProviderVersion)
    }

    func testAMutationSnapshotWrittenBeforePhase3DStillDecodes() throws {
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "objectID": "\(TestData.eventID.uuidString)",
          "objectType": "event",
          "operation": "create",
          "createdAt": "2026-09-01T00:00:00Z",
          "status": "pending",
          "attemptCount": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(PendingMutation.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(decoded.failureClass)
        XCTAssertNil(decoded.baseProviderVersion)
        XCTAssertEqual(decoded.status, .pending)
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-04T09:00:00Z")

    private struct Fixture {
        var database: LocalCalendarDatabase
        var mutation: PendingMutation
        var event: CalendarEvent
    }

    private static func deviceFixture(operation: MutationOperation = .create, includePayload: Bool = true) -> Fixture {
        fixture(calendar: DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID), operation: operation, includePayload: includePayload)
    }

    private static func localFixture() -> Fixture {
        fixture(calendar: TestData.calendar(), operation: .create, includePayload: true)
    }

    private static func fixture(calendar: BetterCalendar, operation: MutationOperation, includePayload: Bool) -> Fixture {
        let event = TestData.event(id: UUID(), calendarID: calendar.id, title: "Queued for the device")
        let mutation = PendingMutation(
            id: UUID(),
            objectID: event.id,
            objectType: .event,
            operation: operation,
            createdAt: now.addingTimeInterval(-60),
            payload: includePayload ? event.encodedSnapshotJSON() : nil
        )

        return Fixture(
            database: TestData.database(calendars: [calendar], events: [event], pendingMutations: [mutation]),
            mutation: mutation,
            event: event
        )
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
