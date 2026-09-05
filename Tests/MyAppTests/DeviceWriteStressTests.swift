import XCTest
@testable import Better_Calendar

/// Spec 3J's write-back reliability targets: zero duplicate device events across 1,000
/// create-crash-retry cycles, and zero lost local edits across 1,000 concurrent-external-edit
/// cycles.
///
/// Same economics as the Phase 2 loops `CrashRecoveryStressTests` runs — a smoke variant on every
/// PR, the full 1,000 on the nightly — but selected by **test name** rather than by an
/// environment variable.
///
/// That difference is deliberate. `CrashRecoveryStressTests` reads `BC_STRESS` from
/// `ProcessInfo`, and xcodebuild does not forward its own environment to the macOS test runner:
/// setting it on the invocation, as `.github/workflows/ci.yml` does, changes nothing, and the
/// nightly job has been running the 50-cycle variant while reporting the 1,000-cycle one. A
/// subclass that overrides the count cannot fail that way — `-only-testing` selects it, and
/// running it demonstrably takes twenty times as long.
@MainActor
class DeviceWriteStressTests: XCTestCase {
    /// Overridden by `DeviceWriteFullStressTests`.
    var cycleCount: Int { 50 }

    /// The failure this exists to rule out is the one a user cannot undo without noticing it
    /// first: a create that reached EventKit, then crashed before its receipt was recorded, and
    /// was reissued on the next launch — leaving two identical events on their real calendar.
    ///
    /// Each cycle plans and performs a create whose row is already `.inFlight`, which is exactly
    /// the state a crash mid-drain leaves behind.
    func testZeroDuplicateDeviceEventsAcrossManyCreateCrashRetryCycles() async throws {
        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)
        let eventKit = FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot(), deviceEvents: [])
        let adapter = DeviceMutationAdapter(store: eventKit)

        for index in 0..<cycleCount {
            let start = Self.baseStart.addingTimeInterval(Double(index) * 86_400)
            let event = TestData.event(
                id: UUID(),
                calendarID: calendar.id,
                title: "Cycle \(index)",
                startDate: start,
                endDate: start.addingTimeInterval(1_800)
            )
            let mutation = PendingMutation(
                id: UUID(),
                objectID: event.id,
                objectType: .event,
                operation: .create,
                createdAt: Self.now,
                payload: event.encodedSnapshotJSON(),
                status: .inFlight
            )
            let database = TestData.database(calendars: [calendar], events: [event], pendingMutations: [mutation])

            // Two drains for every one create: the first lands it, the second is the retry that
            // a crash between the write and the receipt would produce.
            for _ in 0..<2 {
                let plan = DeviceWritePlanner.plan(database: database, now: Self.now)
                _ = await adapter.perform(plan.writes)
            }
        }

        XCTAssertEqual(
            eventKit.deviceEvents.count,
            cycleCount,
            "each cycle must leave exactly one device event across \(cycleCount) create-crash-retry cycles"
        )
        XCTAssertEqual(
            Set(eventKit.deviceEvents.map(\.title)).count,
            cycleCount,
            "and no two of them may be the same event written twice"
        )
    }

    /// Spec 3J: zero lost local edits across concurrent-external-edit cycles.
    ///
    /// Every cycle races a local edit against a device-side change to the *same* field. The
    /// outcome that matters is not who wins — Phase 3E decides that — but that the local edit is
    /// still there afterwards, on the row and in the outbox, for a resolution to be made from.
    func testZeroLostLocalEditsAcrossManyConcurrentExternalEditCycles() async throws {
        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)

        for index in 0..<cycleCount {
            let identifier = "ek-\(index)"
            let eventKit = FakeEventKitStore(
                status: .fullAccess,
                snapshot: DeviceTestData.snapshot(),
                deviceEvents: [
                    DeviceTestData.event(
                        identifier: identifier,
                        externalIdentifier: "ext-\(index)",
                        calendarIdentifier: "cal-personal",
                        title: "Theirs \(index)",
                        startDate: Self.baseStart,
                        endDate: Self.baseStart.addingTimeInterval(1_800),
                        lastModified: Self.now.addingTimeInterval(Double(index))
                    )
                ]
            )

            var local = TestData.event(id: UUID(), calendarID: calendar.id, title: "Mine \(index)")
            local.providerMetadata = ProviderMetadata(
                provider: .apple,
                providerObjectID: identifier,
                // Deliberately stale: the device has moved on since this edit was based on it.
                providerVersion: "0",
                syncStatus: .synced
            )
            let mutation = PendingMutation(
                id: UUID(),
                objectID: local.id,
                objectType: .event,
                operation: .update,
                createdAt: Self.now,
                payload: local.encodedSnapshotJSON(),
                status: .pending,
                baseProviderVersion: "0"
            )
            let database = TestData.database(calendars: [calendar], events: [local], pendingMutations: [mutation])

            let plan = DeviceWritePlanner.plan(database: database, now: Self.now)
            let outcomes = await DeviceMutationAdapter(store: eventKit).perform(plan.writes)
            let result = DeviceWriteCommitter.commit(plan, outcomes: outcomes, in: database, now: Self.now)
            let after = database.applying(result.transaction)

            // The device is untouched and the local edit survives, whichever way it was
            // classified — nothing is silently overwritten and nothing is silently dropped.
            XCTAssertEqual(eventKit.deviceEvents.first?.title, "Theirs \(index)", "cycle \(index): the device must not be overwritten")
            XCTAssertEqual(after.events.first?.title, "Mine \(index)", "cycle \(index): the local edit must survive")
            let row = try XCTUnwrap(after.pendingMutations.first, "cycle \(index): the mutation must still exist")
            XCTAssertNotEqual(row.status, .applied, "cycle \(index): nothing was written, so nothing may be marked applied")
            XCTAssertNotNil(row.payload, "cycle \(index): the edit's payload is the copy a resolution is made from")
        }
    }

    /// Spec 3J's third loop: zero resurrections. A delete that reached the device must not be
    /// undone by a later mirror pass reporting the event it no longer has.
    func testZeroResurrectionsAcrossManyDeleteThenReconcileCycles() async throws {
        let eventKit = FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot(), deviceEvents: [])
        let repository = try makeRepository()
        try repository.save(TestData.database(calendars: [TestData.calendar()], events: []))
        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        await store.refreshDeviceCalendars(now: Self.now)
        let deviceCalendarID = try XCTUnwrap(store.deviceCalendars.first { $0.providerCalendarID == "cal-personal" }?.id)

        for index in 0..<cycleCount {
            var draft = EventDraft(calendarID: deviceCalendarID, startDate: Self.baseStart.addingTimeInterval(Double(index) * 86_400))
            draft.title = "Doomed \(index)"
            draft.endDate = draft.startDate.addingTimeInterval(1_800)
            _ = store.saveEvent(from: draft)
            await store.drainDeviceWrites(now: Self.now)

            guard let created = store.events.first(where: { $0.title == "Doomed \(index)" }) else {
                return XCTFail("cycle \(index): the event should have been created")
            }
            store.deleteEvent(created)
            await store.drainDeviceWrites(now: Self.now)

            // The delayed reconciliation: the device is asked again, right after the delete.
            await store.mirrorDeviceEvents(now: Self.now)

            XCTAssertFalse(
                store.events.contains { $0.title == "Doomed \(index)" },
                "cycle \(index): a deleted event must not be resurrected by a later pass"
            )
        }

        XCTAssertTrue(eventKit.deviceEvents.isEmpty, "every created event was deleted from the device too")
    }

    // MARK: - Fixtures

    fileprivate static let now = TestData.date("2026-09-04T09:00:00Z")
    fileprivate static let baseStart = TestData.date("2026-09-10T14:00:00Z")

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}

/// Spec 3J's full loops. Runs on the nightly only:
///
/// ```
/// xcodebuild test -only-testing:MyAppTests/DeviceWriteFullStressTests …
/// ```
///
/// Excluded from the PR gate with `-skip-testing:MyAppTests/DeviceWriteFullStressTests`, because
/// 3,000 full cycles on every push would dominate CI for no added signal.
@MainActor
final class DeviceWriteFullStressTests: DeviceWriteStressTests {
    override var cycleCount: Int { 1_000 }
}
