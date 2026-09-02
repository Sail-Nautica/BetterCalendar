import XCTest
@testable import Better_Calendar

/// Spec 3B M2: the discovery pass wired into `BetterCalendarStore` — its triggers, what it
/// writes, and the default-destination rules that depend on it.
///
/// `DeviceCalendarDiscoveryTests` covers the planner in isolation; this covers the parts only
/// the store can be wrong about — running a pass when it should not, enqueuing an outbound
/// write for an inbound change, or handing the user a destination that will refuse the write.
@MainActor
final class DeviceCalendarStoreTests: XCTestCase {

    // MARK: - Triggers

    /// Spec 3B.3: launch does no EventKit work at all. The first pass is triggered by the root
    /// view appearing, not by `load()`.
    func testLaunchRunsNoDiscoveryPass() {
        let eventKit = Self.fakeStore()
        _ = Self.makeStore(eventKit: eventKit)

        XCTAssertEqual(eventKit.discoveryCount, 0)
    }

    /// Spec 3B.4: access loss is not disappearance. Below full access the pass does not run, so
    /// nothing is marked unavailable — which is exactly the state a later re-grant restores.
    func testDiscoveryDoesNotRunBelowFullAccess() {
        for status in [CalendarAccessStatus.notDetermined, .denied, .restricted, .writeOnly] {
            let eventKit = Self.fakeStore(status: status)
            let store = Self.makeStore(eventKit: eventKit)

            XCTAssertTrue(store.discoverDeviceCalendars(now: Self.now), "\(status) must not be an error")
            XCTAssertEqual(eventKit.discoveryCount, 0, "no pass may run at \(status)")
            XCTAssertTrue(store.deviceCalendars.isEmpty)
        }
    }

    func testRevokingAccessLeavesMirroredCalendarsUntouched() {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)
        let mirroredBefore = store.deviceCalendars
        XCTAssertEqual(mirroredBefore.count, 3)

        eventKit.simulateExternalChange(to: .denied)
        store.discoverDeviceCalendars(now: Self.later)

        XCTAssertEqual(store.deviceCalendars, mirroredBefore, "losing access must not rewrite the mirror")
        XCTAssertTrue(store.deviceCalendars.allSatisfy { !$0.isUnavailable })
    }

    // MARK: - What a pass writes

    func testFirstPassMirrorsEveryCalendarAndLeavesLocalOnesAlone() {
        let store = Self.makeStore(eventKit: Self.fakeStore())
        let localBefore = store.localCalendars

        store.discoverDeviceCalendars(now: Self.now)

        XCTAssertEqual(store.deviceCalendars.count, 3)
        XCTAssertEqual(store.localCalendars, localBefore, "discovery must not touch a local calendar")
        XCTAssertEqual(store.lastDiscoverySummary?.added, 3)
        XCTAssertEqual(store.deviceDefaultCalendarIdentifier, "work")

        let accounts = store.deviceCalendarAccounts
        XCTAssertEqual(accounts.map(\.name), ["iCloud", "Work Exchange"], "accounts are alphabetical, so the list does not reshuffle between passes")
        XCTAssertEqual(accounts.first { $0.name == "iCloud" }?.calendars.count, 2)
    }

    /// Spec 3.2: an inbound change is journalled as `.reconciliation`, so the journal can tell
    /// "the user did this" from "the device told us this" — and it enqueues no outbox row,
    /// because there is nothing to send back.
    func testDiscoveryJournalsAsReconciliationAndEnqueuesNoOutboundWrite() {
        let store = Self.makeStore(eventKit: Self.fakeStore())

        store.discoverDeviceCalendars(now: Self.now)

        XCTAssertTrue(store.pendingMutations.isEmpty, "an inbound change must never enqueue an outbound write")
    }

    /// The property that makes a foreground trigger affordable, checked through the store rather
    /// than the planner: a second pass over an unchanged device writes nothing at all.
    func testASecondPassOverAnUnchangedDeviceWritesNothing() {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)
        let mirroredBefore = store.deviceCalendars

        store.discoverDeviceCalendars(now: Self.later)

        XCTAssertEqual(eventKit.discoveryCount, 2, "the pass ran")
        XCTAssertEqual(store.deviceCalendars, mirroredBefore, "and changed nothing")
        XCTAssertEqual(store.lastDiscoverySummary?.unchanged, 3)
        XCTAssertTrue(store.lastDiscoverySummary?.isNoOp ?? false)
    }

    /// BC-EK-005: hiding a device calendar is display state. It survives the next pass, removes
    /// nothing, and — because `isVisible` is ours, not the provider's — sends nothing anywhere.
    func testHidingADeviceCalendarPersistsAcrossAPassAndDeletesNothing() {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)

        guard let work = store.deviceCalendars.first(where: { $0.providerCalendarID == "work" }) else {
            return XCTFail("the work calendar is missing")
        }
        store.toggleCalendarVisibility(work)
        XCTAssertEqual(store.deviceCalendars.first { $0.id == work.id }?.isVisible, false)
        XCTAssertTrue(store.pendingMutations.isEmpty, "visibility is local-only and is never pushed to a provider")

        store.discoverDeviceCalendars(now: Self.later)

        XCTAssertEqual(store.deviceCalendars.first { $0.id == work.id }?.isVisible, false, "a pass must not unhide it")
        XCTAssertEqual(store.deviceCalendars.count, 3, "and must not delete it")
    }

    /// BC-EK-022 at calendar level, through the store: removing and re-adding an account
    /// reconnects its calendars instead of importing a second copy.
    func testRemovingAndReaddingAnAccountReconnectsRatherThanDuplicating() {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)
        guard let work = store.deviceCalendars.first(where: { $0.providerCalendarID == "work" }) else {
            return XCTFail("the work calendar is missing")
        }
        store.toggleCalendarVisibility(work)

        let withoutExchange = Self.devices.filter { $0.source.identifier != "source-exchange" }
        eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: withoutExchange, defaultCalendarIdentifierForNewEvents: "personal"))
        store.discoverDeviceCalendars(now: Self.later)

        XCTAssertEqual(store.deviceCalendars.count, 3, "a vanished calendar is marked, never deleted")
        XCTAssertEqual(store.deviceCalendars.first { $0.id == work.id }?.isUnavailable, true)
        XCTAssertFalse(store.visibleEvents.contains { $0.calendarID == work.id })

        eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: Self.devices, defaultCalendarIdentifierForNewEvents: "work"))
        store.discoverDeviceCalendars(now: Self.evenLater)

        XCTAssertEqual(store.deviceCalendars.count, 3, "reconnection is not a re-import")
        let reconnected = store.deviceCalendars.first { $0.id == work.id }
        XCTAssertEqual(reconnected?.isUnavailable, false)
        XCTAssertEqual(reconnected?.isVisible, false, "the state the user left it in comes back with it")
    }

    /// Spec 3.24: counts, never content.
    func testAPassRecordsWhatItDid() {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)

        var renamed = Self.devices
        renamed[0].title = "Work (2026)"
        eventKit.simulateDeviceChange(to: DeviceCalendarSnapshot(calendars: [renamed[0]], defaultCalendarIdentifierForNewEvents: nil))
        store.discoverDeviceCalendars(now: Self.later)

        XCTAssertEqual(store.lastDiscoverySummary?.updated, 1)
        XCTAssertEqual(store.lastDiscoverySummary?.markedUnavailable, 2)
        XCTAssertEqual(store.lastDiscoverySummary?.added, 0)
    }

    // MARK: - Spec 3B.6: a device calendar is a read-only record

    func testRenamingOrDeletingADeviceCalendarIsRefusedAtTheModelLayer() {
        let store = Self.makeStore(eventKit: Self.fakeStore())
        store.discoverDeviceCalendars(now: Self.now)
        guard var work = store.deviceCalendars.first(where: { $0.providerCalendarID == "work" }) else {
            return XCTFail("the work calendar is missing")
        }

        work.name = "Renamed By Us"
        store.updateCalendar(work)

        XCTAssertEqual(store.deviceCalendars.first { $0.id == work.id }?.name, "Work", "a device calendar cannot be renamed here")
        XCTAssertNotNil(store.lastError)
        store.clearLastError()

        store.deleteCalendar(work, moveEventsTo: store.localCalendars.first?.id)
        XCTAssertEqual(store.deviceCalendars.count, 3, "a device calendar cannot be deleted here")
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Spec 3B.5: the default destination

    func testTheDefaultFallsBackThroughItsSpecifiedChain() {
        let store = Self.makeStore(eventKit: Self.fakeStore())
        store.discoverDeviceCalendars(now: Self.now)

        guard let local = store.localCalendars.first else { return XCTFail("no local calendar") }
        XCTAssertEqual(store.defaultCalendarID, local.id, "step 1: the flagged default, while it is writable")

        // Step 2: the flagged default stops being usable, and the device's own default is
        // mirrored and writable.
        var unavailableLocal = local
        unavailableLocal.isUnavailable = true
        store.updateCalendar(unavailableLocal)

        let deviceDefault = store.deviceCalendars.first { $0.providerCalendarID == "work" }
        XCTAssertEqual(store.defaultCalendarID, deviceDefault?.id, "step 2: the device's own default for new events")
    }

    /// The rule that matters most in the chain: a read-only calendar is never chosen, whatever
    /// order it happens to sit in.
    func testTheDefaultIsNeverAReadOnlyOrUnavailableCalendar() {
        let eventKit = Self.fakeStore(defaultCalendarIdentifier: "holidays")
        let store = Self.makeStore(eventKit: eventKit)
        store.discoverDeviceCalendars(now: Self.now)

        guard var local = store.localCalendars.first else { return XCTFail("no local calendar") }
        local.isUnavailable = true
        store.updateCalendar(local)

        let chosen = store.calendars.first { $0.id == store.defaultCalendarID }
        XCTAssertNotNil(chosen)
        XCTAssertFalse(chosen?.isReadOnly ?? true, "the subscribed holiday feed must never be the default")
        XCTAssertFalse(chosen?.isUnavailable ?? true)
        XCTAssertTrue(chosen?.isWritableDestination ?? false)
    }

    func testWritableDestinationsExcludeReadOnlyAndUnavailableCalendars() {
        let store = Self.makeStore(eventKit: Self.fakeStore())
        store.discoverDeviceCalendars(now: Self.now)

        let offered = store.writableDestinationCalendars
        XCTAssertFalse(offered.contains { $0.providerCalendarID == "holidays" }, "a subscribed feed is not a destination")
        XCTAssertEqual(offered.count, 3, "one local plus the two writable device calendars")
        XCTAssertEqual(
            offered.first { $0.providerCalendarID == "work" }?.destinationLabel,
            "Work · Work Exchange",
            "a destination names its account (spec 3.9)"
        )
        XCTAssertEqual(store.localCalendars.first?.destinationLabel, "School", "a local calendar has no account to name")
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-02T12:00:00Z")
    private static let later = TestData.date("2026-09-03T12:00:00Z")
    private static let evenLater = TestData.date("2026-09-04T12:00:00Z")

    private static let exchangeSource = DeviceCalendarSource(identifier: "source-exchange", title: "Work Exchange", type: .exchange)
    private static let icloudSource = DeviceCalendarSource(identifier: "source-icloud", title: "iCloud", type: .mobileMe)

    private static let devices: [DeviceCalendar] = [
        DeviceCalendar(identifier: "work", source: exchangeSource, title: "Work", type: .exchange, colorHex: "#7B2D8E"),
        DeviceCalendar(identifier: "personal", source: icloudSource, title: "Personal", type: .calDAV, colorHex: "#2B6CE8"),
        DeviceCalendar(
            identifier: "holidays",
            source: icloudSource,
            title: "US Holidays",
            type: .calDAV,
            isSubscribed: true,
            allowsContentModifications: false
        )
    ]

    private static func fakeStore(
        status: CalendarAccessStatus = .fullAccess,
        defaultCalendarIdentifier: String? = "work"
    ) -> FakeEventKitStore {
        FakeEventKitStore(
            status: status,
            snapshot: DeviceCalendarSnapshot(calendars: devices, defaultCalendarIdentifierForNewEvents: defaultCalendarIdentifier)
        )
    }

    private static func makeStore(eventKit: FakeEventKitStore) -> BetterCalendarStore {
        BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(events: []))),
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
    }
}
