import XCTest
@testable import Better_Calendar

/// Spec 3E.9's "The window" block: the reconciliation window as persisted state, and the safety
/// rules that let it move.
///
/// The scrolling test is the point of the file. Phase 3C's window was safe because it never went
/// anywhere; the moment it follows the user, "absent from the fetch" stops meaning "deleted on
/// the device" unless the deletion permission stays pinned to the range a pass actually asked
/// for.
@MainActor
final class ReconciliationWindowTests: XCTestCase {

    // MARK: - The state type (spec 3E.3)

    func testAWindowGrowsByUnionRatherThanByReplacement() {
        let march = DateInterval(start: TestData.date("2027-03-01T00:00:00Z"), end: TestData.date("2027-04-01T00:00:00Z"))
        let september = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z"))

        let state = CalendarReconciliationState(calendarID: DeviceTestData.personalRowID)
            .unioned(with: september, at: Self.now)
            .unioned(with: march, at: Self.now)

        // A calendar reconciled over September and then over March has been reconciled over both.
        XCTAssertEqual(state.window?.start, september.start)
        XCTAssertEqual(state.window?.end, march.end)
        XCTAssertTrue(state.covers(september))
        XCTAssertTrue(state.covers(march))
    }

    func testAnUnreconciledCalendarCoversNothing() {
        let state = CalendarReconciliationState(calendarID: DeviceTestData.personalRowID)

        XCTAssertNil(state.window)
        XCTAssertFalse(state.covers(DateInterval(start: Self.now, end: Self.now.addingTimeInterval(60))))
    }

    // MARK: - Persistence (migration v023)

    func testReconciliationStateRoundTripsAndUpdatesInPlace() throws {
        let repository = try makeRepository()
        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)
        try repository.save(TestData.database(calendars: [calendar], events: []))

        let window = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z"))
        try repository.saveReconciliationStates([
            CalendarReconciliationState(calendarID: calendar.id).unioned(with: window, at: Self.now)
        ])

        let stored = try XCTUnwrap(try repository.reconciliationStates()[calendar.id])
        XCTAssertEqual(stored.window, window)
        XCTAssertEqual(stored.lastReconciledAt, Self.now)

        // Upsert rather than insert: a second pass over the same calendar updates the row.
        let wider = DateInterval(start: window.start, end: TestData.date("2026-11-01T00:00:00Z"))
        try repository.saveReconciliationStates([stored.unioned(with: wider, at: Self.later)])

        let updated = try XCTUnwrap(try repository.reconciliationStates()[calendar.id])
        XCTAssertEqual(updated.window, wider)
        XCTAssertEqual(updated.lastReconciledAt, Self.later)
        XCTAssertEqual(try repository.reconciliationStates().count, 1, "one row per calendar")
    }

    // MARK: - The pass (spec 3E.3)

    func testAPassRecordsTheRangeItFetchedForEveryCalendarItFetched() async throws {
        let fixture = try await connectedStore()

        await fixture.store.mirrorDeviceEvents(now: Self.now)

        // The two visible calendars — not the hidden holiday feed, which was never fetched.
        XCTAssertEqual(Set(fixture.store.reconciliationStates.keys).count, 2)
        for state in fixture.store.reconciliationStates.values {
            XCTAssertEqual(state.window, DeviceEventMirror.defaultWindow(around: Self.now))
            XCTAssertEqual(state.lastReconciledAt, Self.now)
        }
    }

    /// The danger a moving window creates, stated directly: scroll a year forward, and every
    /// event in this month is suddenly absent from the fetch.
    func testScrollingFarForwardAndBackDeletesNothingInBetween() async throws {
        let fixture = try await connectedStore(deviceEvents: [
            DeviceTestData.event(identifier: "near", externalIdentifier: "ext-near", title: "This month")
        ])
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        XCTAssertEqual(fixture.store.events.count, 1)

        // A pass over a window a year away. The near event is not in it, and must survive.
        let farAway = DateInterval(
            start: TestData.date("2027-09-01T00:00:00Z"),
            end: TestData.date("2027-10-01T00:00:00Z")
        )
        await fixture.store.mirrorDeviceEvents(in: farAway, now: Self.now)

        XCTAssertEqual(fixture.store.events.count, 1, "a pass elsewhere must not delete what it did not ask about")
        XCTAssertTrue(fixture.store.deletedEventTombstones.isEmpty)

        // And coming back finds it unchanged rather than re-imported.
        let idBefore = fixture.store.events.first?.id
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        XCTAssertEqual(fixture.store.events.count, 1)
        XCTAssertEqual(fixture.store.events.first?.id, idBefore)
    }

    /// The stored window records what has been covered; it does not license deleting from a range
    /// this pass never asked about.
    func testAStoredWindowDoesNotWidenThePermissionToDelete() async throws {
        let fixture = try await connectedStore(deviceEvents: [
            DeviceTestData.event(identifier: "near", externalIdentifier: "ext-near", title: "This month")
        ])
        await fixture.store.mirrorDeviceEvents(now: Self.now)

        // The state now covers this month. A pass over a *different* range still may not delete
        // from this one, even though the recorded window includes it.
        fixture.eventKit.simulateDeviceEventChange(to: [])
        let elsewhere = DateInterval(
            start: TestData.date("2027-09-01T00:00:00Z"),
            end: TestData.date("2027-10-01T00:00:00Z")
        )
        await fixture.store.mirrorDeviceEvents(in: elsewhere, now: Self.now)

        XCTAssertEqual(fixture.store.events.count, 1, "deletion is keyed to the range asked for, not the range ever covered")
    }

    // MARK: - The visible-range trigger (spec 3.23)

    func testAVisibleRangeInsideTheMirroredWindowCostsNoPass() async throws {
        let fixture = try await connectedStore()
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        let fetchesBefore = fixture.eventKit.eventFetchCount

        // Next week is comfortably inside the default window.
        fixture.store.visibleRangeDidChange(
            to: DateInterval(start: Self.now, end: Self.now.addingTimeInterval(7 * 86_400)),
            now: Self.now
        )
        await Self.settle()

        XCTAssertEqual(fixture.eventKit.eventFetchCount, fetchesBefore, "scrolling within the window must be free")
    }

    func testAVisibleRangeBeyondTheMirroredWindowWidensItAndFetches() async throws {
        let fixture = try await connectedStore(deviceEvents: [
            DeviceTestData.event(
                identifier: "far",
                externalIdentifier: "ext-far",
                title: "Next year",
                startDate: TestData.date("2027-09-15T14:00:00Z"),
                endDate: TestData.date("2027-09-15T15:00:00Z")
            )
        ])
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        XCTAssertTrue(fixture.store.events.isEmpty, "next year is outside the default window")

        fixture.store.visibleRangeDidChange(
            to: DateInterval(start: TestData.date("2027-09-01T00:00:00Z"), end: TestData.date("2027-10-01T00:00:00Z")),
            now: Self.now
        )
        await Self.settle()

        XCTAssertEqual(fixture.store.events.map(\.title), ["Next year"])
        // The window grew rather than moved: the default span around now is still covered.
        // Keyed by the id discovery actually minted, not by the fixture's — `DeviceCalendarMirror`
        // assigns a fresh local id to a calendar it has not seen before (spec 3B.3).
        let personalID = try XCTUnwrap(fixture.store.deviceCalendars.first { $0.providerCalendarID == "cal-personal" }?.id)
        let state = try XCTUnwrap(fixture.store.reconciliationStates[personalID])
        XCTAssertTrue(state.covers(DeviceEventMirror.defaultWindow(around: Self.now)))
    }

    // MARK: - Retention (spec 3.26 / 3E.5, ADR 0010)

    func testACalendarUnavailablePastTheLimitHasItsMirroredEventsPurgedAndItsRowKept() async throws {
        let fixture = try await connectedStore(deviceEvents: [DeviceTestData.event()])
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        XCTAssertEqual(fixture.store.events.count, 1)

        // The account is removed from the device, and stays removed.
        fixture.eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: [DeviceTestData.workCalendar]))
        _ = fixture.store.discoverDeviceCalendars(now: Self.now)
        XCTAssertTrue(fixture.store.deviceCalendars.contains { $0.providerCalendarID == "cal-personal" && $0.isUnavailable })

        let longAfter = Self.now.addingTimeInterval(DeviceEventMirror.unavailableRetentionInterval + 86_400)
        fixture.store.purgeLongUnavailableMirroredEvents(now: longAfter)

        XCTAssertTrue(fixture.store.events.isEmpty, "the mirrored events are reconstructible and go")
        XCTAssertTrue(
            fixture.store.deviceCalendars.contains { $0.providerCalendarID == "cal-personal" },
            "the calendar row carries the user's own choices and stays"
        )
    }

    func testACalendarInsideTheLimitKeepsEverything() async throws {
        let fixture = try await connectedStore(deviceEvents: [DeviceTestData.event()])
        await fixture.store.mirrorDeviceEvents(now: Self.now)

        fixture.eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: [DeviceTestData.workCalendar]))
        _ = fixture.store.discoverDeviceCalendars(now: Self.now)

        let shortlyAfter = Self.now.addingTimeInterval(DeviceEventMirror.unavailableRetentionInterval - 86_400)
        fixture.store.purgeLongUnavailableMirroredEvents(now: shortlyAfter)

        XCTAssertEqual(fixture.store.events.count, 1, "a season away is not a deletion")
    }

    /// A Better Calendar-owned event is not reconstructible, so nothing would bring it back.
    func testABetterCalendarOwnedEventOnAnExpiredCalendarIsNeverPurged() async throws {
        let fixture = try await connectedStore()
        _ = fixture.store.discoverDeviceCalendars(now: Self.now)
        guard let personal = fixture.store.deviceCalendars.first(where: { $0.providerCalendarID == "cal-personal" }) else {
            return XCTFail("the personal calendar should be mirrored")
        }

        var draft = EventDraft(calendarID: personal.id, startDate: Self.now.addingTimeInterval(86_400))
        draft.title = "Mine, never pushed"
        draft.endDate = draft.startDate.addingTimeInterval(3_600)
        _ = fixture.store.saveEvent(from: draft)

        fixture.eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: [DeviceTestData.workCalendar]))
        _ = fixture.store.discoverDeviceCalendars(now: Self.now)

        let longAfter = Self.now.addingTimeInterval(DeviceEventMirror.unavailableRetentionInterval + 86_400)
        fixture.store.purgeLongUnavailableMirroredEvents(now: longAfter)

        XCTAssertEqual(fixture.store.events.map(\.title), ["Mine, never pushed"])
    }

    // MARK: - Cost (spec 3.27 / 3J)

    /// Spec 3.27: a pass that finds nothing changed must be cheap enough to run on every
    /// foreground. Idempotence is what makes reacting to every `EKEventStoreChanged` affordable,
    /// so this measures the case that actually recurs.
    func testANoOpPassOverAMonthOfEventsStaysUnderTheBudget() async throws {
        let devices = (0..<200).map { index in
            DeviceTestData.event(
                identifier: "bulk-\(index)",
                externalIdentifier: "bulk-ext-\(index)",
                title: "Event \(index)",
                startDate: Self.now.addingTimeInterval(Double(index) * 3_600),
                endDate: Self.now.addingTimeInterval(Double(index) * 3_600 + 1_800)
            )
        }
        let fixture = try await connectedStore(deviceEvents: devices)
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        XCTAssertEqual(fixture.store.events.count, 200)

        let started = Date()
        await fixture.store.mirrorDeviceEvents(now: Self.now)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(fixture.store.lastEventMirrorSummary?.isNoOp ?? false, "the second pass must find nothing")
        XCTAssertLessThan(elapsed, 0.1, "spec 3J: an unchanged pass over a month's events stays under 100ms")
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-04T09:00:00Z")
    private static let later = TestData.date("2026-09-05T09:00:00Z")

    private struct Fixture {
        var store: BetterCalendarStore
        var eventKit: FakeEventKitStore
    }

    private static func settle() async {
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func connectedStore(deviceEvents: [DeviceEvent] = []) async throws -> Fixture {
        let eventKit = FakeEventKitStore(
            status: .fullAccess,
            snapshot: DeviceTestData.snapshot(),
            deviceEvents: deviceEvents
        )
        let repository = try makeRepository()
        try repository.save(TestData.database(calendars: [TestData.calendar()], events: []))
        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        _ = store.discoverDeviceCalendars(now: Self.now)
        return Fixture(store: store, eventKit: eventKit)
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
