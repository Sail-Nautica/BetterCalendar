import XCTest
@testable import Better_Calendar

/// Spec 3E.9's Observation and Triggers blocks: the wiring that makes a change made in Apple
/// Calendar reach Better Calendar without the user opening it.
///
/// The coalescing tests are the point. `EKEventStoreChanged` arrives in bursts during an account
/// sync, and a pass per notification would spend a dozen device fetches answering one question —
/// on a phone, on the user's battery.
@MainActor
final class DeviceChangeObservationTests: XCTestCase {

    // MARK: - Observation (spec 3.23)

    func testAChangeNotificationTriggersExactlyOnePass() async throws {
        let fixture = try await Self.observingStore()
        let fetchesBefore = fixture.eventKit.eventFetchCount

        fixture.eventKit.simulateExternalChangeNotification()
        await Self.settle()

        XCTAssertEqual(fixture.eventKit.eventFetchCount, fetchesBefore + 1)
    }

    /// The burst an account sync produces. Ten notifications, one pass.
    func testABurstOfNotificationsProducesOnePass() async throws {
        let fixture = try await Self.observingStore()
        let fetchesBefore = fixture.eventKit.eventFetchCount

        fixture.eventKit.simulateExternalChangeNotification(count: 10)
        await Self.settle()

        XCTAssertEqual(
            fixture.eventKit.eventFetchCount,
            fetchesBefore + 1,
            "a burst must be coalesced into one pass, not ten"
        )
    }

    /// Spec 3.23: never two passes concurrently. A caller arriving mid-pass schedules exactly one
    /// more — not one per caller — because two passes would each diff against a database the
    /// other is writing.
    func testConcurrentRequestsNeverProduceTwoOverlappingPasses() async throws {
        let fixture = try await Self.observingStore()
        let fetchesBefore = fixture.eventKit.eventFetchCount

        async let first: Bool = fixture.store.reconcileDeviceCalendars(refreshingSources: false, now: Self.now)
        async let second: Bool = fixture.store.reconcileDeviceCalendars(refreshingSources: false, now: Self.now)
        async let third: Bool = fixture.store.reconcileDeviceCalendars(refreshingSources: false, now: Self.now)
        _ = await (first, second, third)

        // The invariant spec 3.23 actually states. Asserted rather than a fetch count, because
        // how many passes three concurrent requests collapse into depends on scheduling this
        // test does not control — whereas "two passes were inside the fetch at once" is either
        // true or it is not.
        XCTAssertEqual(fixture.eventKit.peakConcurrentEventFetches, 1, "two passes must never run at once")

        // And they were collapsed: three requests cost fewer than three passes.
        let passes = fixture.eventKit.eventFetchCount - fetchesBefore
        XCTAssertLessThan(passes, 3, "concurrent requests must coalesce")
        XCTAssertGreaterThanOrEqual(passes, 1, "but at least one pass must actually run")
    }

    /// Spec 3.23: `refreshSourcesIfNecessary` triggers network activity, so it runs on a
    /// foreground and not on a pass that is *reacting* to the device telling us something it
    /// already knows.
    func testSourcesAreRefreshedOnForegroundButNotOnAChangeNotification() async throws {
        let fixture = try await Self.observingStore()

        await fixture.store.reconcileDeviceCalendars(refreshingSources: true, now: Self.now)
        XCTAssertEqual(fixture.eventKit.refreshSourcesCount, 1)

        fixture.eventKit.simulateExternalChangeNotification()
        await Self.settle()

        XCTAssertEqual(
            fixture.eventKit.refreshSourcesCount,
            1,
            "a change-notification pass must not go to the network"
        )
    }

    func testObservationStopsWhenAsked() async throws {
        let fixture = try await Self.observingStore()
        fixture.store.stopObservingDeviceCalendarChanges()
        let fetchesBefore = fixture.eventKit.eventFetchCount

        fixture.eventKit.simulateExternalChangeNotification()
        await Self.settle()

        XCTAssertEqual(fixture.eventKit.eventFetchCount, fetchesBefore)
    }

    /// BC-EK-006, completed: the event appears without anyone foregrounding the app.
    func testAnEventCreatedOnTheDeviceAppearsWithoutAForeground() async throws {
        let fixture = try await Self.observingStore()
        XCTAssertTrue(fixture.store.events.isEmpty)

        fixture.eventKit.simulateDeviceEventChange(to: [
            DeviceTestData.event(identifier: "new-1", externalIdentifier: "new-ext-1", title: "Dentist")
        ])
        fixture.eventKit.simulateExternalChangeNotification()
        await Self.settle()

        XCTAssertEqual(fixture.store.events.map(\.title), ["Dentist"])
    }

    // MARK: - Triggers (spec 3E.2)

    /// Turning a calendar on is a trigger: its events have never been fetched, and waiting for
    /// the next foreground to show them is a worse answer than one pass.
    func testTurningADeviceCalendarOnMirrorsItsEventsWithoutWaitingForAForeground() async throws {
        let fixture = try await Self.observingStore(deviceEvents: [
            DeviceTestData.event(identifier: "holiday-1", externalIdentifier: "holiday-ext-1", calendarIdentifier: "cal-holidays", title: "Labor Day")
        ])
        // The subscribed holiday calendar is mirrored but hidden by default (spec 3.8), so its
        // event is not fetched.
        XCTAssertTrue(fixture.store.events.isEmpty)

        guard let holidays = fixture.store.deviceCalendars.first(where: { $0.providerCalendarID == "cal-holidays" }) else {
            return XCTFail("the holiday calendar should be mirrored")
        }
        fixture.store.toggleCalendarVisibility(holidays)
        await Self.settle()

        XCTAssertEqual(fixture.store.events.map(\.title), ["Labor Day"])
    }

    /// BC-EK-005 still holds under the new trigger: turning one off removes its events from the
    /// views without deleting them.
    func testTurningADeviceCalendarOffDeletesNothing() async throws {
        let fixture = try await Self.observingStore(deviceEvents: [DeviceTestData.event()])
        XCTAssertEqual(fixture.store.events.count, 1)

        guard let personal = fixture.store.deviceCalendars.first(where: { $0.providerCalendarID == "cal-personal" }) else {
            return XCTFail("the personal calendar should be mirrored")
        }
        fixture.store.toggleCalendarVisibility(personal)
        await Self.settle()

        XCTAssertEqual(fixture.store.events.count, 1, "the row is retained")
        XCTAssertTrue(fixture.store.visibleEvents.isEmpty, "and hidden from every view")
        XCTAssertTrue(fixture.store.deletedEventTombstones.isEmpty)
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-04T09:00:00Z")

    private struct Fixture {
        var store: BetterCalendarStore
        var eventKit: FakeEventKitStore
    }

    /// Long enough for the coalescing window to elapse and the pass it schedules to finish.
    private static func settle() async {
        try? await Task.sleep(for: .seconds(BetterCalendarStore.changeCoalescingInterval + 1.0))
    }

    private static func observingStore(deviceEvents: [DeviceEvent] = []) async throws -> Fixture {
        let eventKit = FakeEventKitStore(
            status: .fullAccess,
            snapshot: DeviceTestData.snapshot(),
            deviceEvents: deviceEvents
        )
        let store = BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(calendars: [], events: []))),
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        await store.refreshDeviceCalendars(now: now)
        store.observeDeviceCalendarChanges()
        return Fixture(store: store, eventKit: eventKit)
    }
}
