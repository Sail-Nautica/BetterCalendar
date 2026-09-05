import XCTest
@testable import Better_Calendar

/// Spec 3C M3/M4: the event-mirroring pass wired into `BetterCalendarStore`, and the
/// consequences that only the store can be wrong about — running a pass when it should not,
/// fetching a window it did not mean to, or letting a mirrored event schedule a notification the
/// system is already going to deliver.
///
/// `DeviceEventMirrorTests` covers the planner in isolation. This covers the wiring.
@MainActor
final class DeviceEventStoreTests: XCTestCase {

    // MARK: - Triggers and access (spec 3.4, BC-EK-003)

    func testLaunchFetchesNoEvents() {
        let eventKit = Self.fakeStore()
        _ = Self.makeStore(eventKit: eventKit)

        XCTAssertEqual(eventKit.eventFetchCount, 0, "launch must touch nothing from EventKit")
    }

    /// BC-EK-003: write-only fetches nothing. An empty result must never be mistaken for an
    /// empty device — which is why the pass does not run at all rather than running and
    /// concluding every mirrored event was deleted.
    func testNoPassRunsBelowFullAccess() async {
        for status in [CalendarAccessStatus.notDetermined, .denied, .restricted, .writeOnly] {
            let eventKit = Self.fakeStore(status: status)
            let store = Self.makeStore(eventKit: eventKit)

            let succeeded = await store.mirrorDeviceEvents(now: DeviceTestData.now)

            XCTAssertTrue(succeeded, "\(status) must not be an error")
            XCTAssertEqual(eventKit.eventFetchCount, 0, "no fetch may run at \(status)")
            XCTAssertTrue(store.events.isEmpty)
        }
    }

    func testLosingAccessBetweenPassesDeletesNothing() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        let mirrored = store.events
        XCTAssertFalse(mirrored.isEmpty)

        eventKit.simulateExternalChange(to: .denied)
        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertEqual(store.events, mirrored, "access loss is not deletion")
    }

    /// Calendars first, always: an event whose calendar is not mirrored yet has nowhere to go.
    func testRefreshDiscoversCalendarsBeforeMirroringEventsOntoThem() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)

        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        XCTAssertEqual(store.deviceCalendars.count, 3)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.lastEventMirrorSummary?.skippedUnmirroredCalendar, 0)
    }

    // MARK: - What the pass asks for (spec 3C.8)

    /// Spec 3C.8 step 2: only calendars that are mirrored, shown, and still on the device. The
    /// hidden holiday feed is not asked about, which is what makes BC-EK-005 safe.
    func testOnlySelectedAvailableCalendarsAreFetched() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        // The subscribed holiday calendar is mirrored but hidden by default (spec 3.8).
        XCTAssertEqual(eventKit.lastRequestedCalendarIdentifiers, ["cal-personal", "cal-work"])
    }

    func testTheFetchIsBoundedToTheDefaultWindow() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        XCTAssertEqual(eventKit.lastRequestedRange, DeviceEventMirror.defaultWindow(around: DeviceTestData.now))
        XCTAssertEqual(store.lastEventMirrorWindow, DeviceEventMirror.defaultWindow(around: DeviceTestData.now))
    }

    func testAFailedFetchIsNotAUserFacingErrorAndChangesNothing() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        let mirrored = store.events

        eventKit.eventFetchError = TestRepositoryError.loadFailed
        let succeeded = await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertFalse(succeeded)
        XCTAssertNil(store.lastError, "a transient fetch failure must not raise the data-error alert")
        XCTAssertEqual(store.events, mirrored, "nothing is lost by a pass that did not run")
    }

    // MARK: - The round trip through the store (BC-EK-006, BC-EK-012)

    func testAnEventCreatedOnTheDeviceAppearsInEveryView() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        eventKit.simulateDeviceEventChange(to: Self.deviceEvents + [
            // Its own external identifier: that value is the cross-device identity of *one*
            // event (spec 3C.1), and the mirror matches on it, so two fixtures sharing one would
            // be describing the same event twice rather than two events.
            DeviceTestData.event(
                identifier: "evt-new",
                externalIdentifier: "ext-new",
                title: "Dentist",
                startDate: TestData.date("2026-09-15T13:00:00Z"),
                endDate: TestData.date("2026-09-15T14:00:00Z")
            )
        ])
        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertEqual(store.events.count, 3)
        // Reaching the views through the ordinary path is the point of spec 3C.1's first
        // property: no screen can tell a mirrored event from a local one.
        let day = store.visibleOccurrences(on: TestData.date("2026-09-15T13:00:00Z"))
        XCTAssertEqual(day.map(\.event.title), ["Dentist"])
    }

    /// The other half of "in every view": search reads the FTS index, not the events array, so a
    /// mirrored event that never reached the index would be invisible to it while showing up
    /// perfectly well in Day and Week.
    func testAMirroredEventIsFindableThroughSearch() async throws {
        let eventKit = Self.fakeStore()
        let repository = try makeSQLiteRepository()
        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        let matches = try repository.searchEventIDs(matching: "Standup")

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(store.events.first { $0.id == matches[0] }?.title, "Standup")
    }

    func testAnExternalEditUpdatesTheSameRow() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        let originalIDs = Set(store.events.map(\.id))

        eventKit.simulateDeviceEventChange(to: [
            DeviceTestData.event(title: "Standup (30m earlier)", lastModified: TestData.date("2026-09-05T08:00:00Z")),
            Self.deviceEvents[1]
        ])
        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertEqual(Set(store.events.map(\.id)), originalIDs, "an edit must not re-key the row")
        XCTAssertTrue(store.events.contains { $0.title == "Standup (30m earlier)" })
    }

    func testAnExternalDeleteRemovesTheEventAndDoesNotResurrectIt() async {
        let eventKit = Self.fakeStore()
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        XCTAssertEqual(store.events.count, 2)

        eventKit.simulateDeviceEventChange(to: [Self.deviceEvents[1]])
        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.deletedEventTombstones.map(\.deletedBy), [.providerDeletion])

        // BC-EK-012's second half: a delayed report of the deleted event does not bring it back.
        eventKit.simulateDeviceEventChange(to: Self.deviceEvents)
        await store.mirrorDeviceEvents(now: DeviceTestData.now)
        XCTAssertEqual(store.events.count, 1, "the tombstone must suppress the resurrection")
    }

    func testASecondPassOverAnUnchangedDeviceWritesNothing() async {
        let eventKit = Self.fakeStore()
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler(), eventKitStore: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        let writesAfterFirstPass = repository.appliedTransactions.count

        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        XCTAssertEqual(repository.appliedTransactions.count, writesAfterFirstPass, "an unchanged device must cost no write")
        XCTAssertTrue(store.lastEventMirrorSummary?.isNoOp ?? false)
    }

    // MARK: - Notifications (BC-EK-016, spec 3C.7)

    /// The prerequisites could only prove this against a fixture *shaped* to look like a mirrored
    /// event. This proves it against real ones: the rows here were written by the real pass from
    /// a real device event, and the planner is asked about the store's own state.
    func testAMirroredEventWithTwoAlarmsProducesZeroLocalNotificationRequests() async {
        let eventKit = Self.fakeStore()
        eventKit.deviceEvents = [
            DeviceTestData.event(
                title: "Standup",
                startDate: TestData.date("2026-09-20T14:00:00Z"),
                endDate: TestData.date("2026-09-20T14:30:00Z"),
                alarms: [DeviceEventAlarm(relativeOffset: -600), DeviceEventAlarm(relativeOffset: -3_600)]
            )
        ]
        let store = Self.makeStore(eventKit: eventKit)

        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events.first?.reminders.count, 2, "the alarms are mirrored, for display")

        let plan = LocalNotificationPlanner().plan(
            events: store.events,
            calendars: store.calendars,
            pendingIdentifiers: [],
            now: DeviceTestData.now,
            horizonEnd: TestData.date("2026-10-01T00:00:00Z")
        )

        XCTAssertTrue(
            plan.requestsToSchedule.isEmpty,
            "the system delivers a device calendar's alerts; scheduling our own notifies the user twice"
        )
        XCTAssertTrue(plan.identifiersToCancel.isEmpty, "and turning the calendar off leaves no orphans behind")
    }

    func testALocalEventsNotificationsAreUnaffectedByThePresenceOfMirroredEvents() async {
        let localCalendar = TestData.calendar()
        var localEvent = TestData.event(
            startDate: TestData.date("2026-09-20T14:00:00Z"),
            endDate: TestData.date("2026-09-20T15:00:00Z")
        )
        localEvent.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(15))]

        let eventKit = Self.fakeStore()
        eventKit.deviceEvents = [
            DeviceTestData.event(
                startDate: TestData.date("2026-09-21T14:00:00Z"),
                endDate: TestData.date("2026-09-21T14:30:00Z"),
                alarms: [DeviceEventAlarm(relativeOffset: -600)]
            )
        ]
        let store = BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(calendars: [localCalendar], events: [localEvent]))),
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )

        await store.refreshDeviceCalendars(now: DeviceTestData.now)
        XCTAssertEqual(store.events.count, 2, "the mirrored event is present alongside the local one")

        let plan = LocalNotificationPlanner().plan(
            events: store.events,
            calendars: store.calendars,
            pendingIdentifiers: [],
            now: DeviceTestData.now,
            horizonEnd: TestData.date("2026-10-01T00:00:00Z")
        )

        XCTAssertEqual(plan.requestsToSchedule.count, 1, "a local event still gets exactly its own notification")
        XCTAssertEqual(plan.requestsToSchedule.first?.eventID, localEvent.id)
    }

    // MARK: - Editing a mirrored event (spec 3.10, 3C.3, 3C.9)

    func testAReadOnlyCalendarsEventIsRefusedBeforeTheDetailViewOffersAnEdit() async {
        let eventKit = Self.fakeStore()
        eventKit.deviceEvents = [DeviceTestData.event(identifier: "holiday", calendarIdentifier: "cal-holidays", title: "Labor Day")]
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        // The holiday calendar is hidden by default, so make it visible to get its events.
        guard let holidays = store.deviceCalendars.first(where: { $0.providerCalendarID == "cal-holidays" }) else {
            return XCTFail("the holiday calendar should be mirrored")
        }
        store.toggleCalendarVisibility(holidays)
        await store.mirrorDeviceEvents(now: DeviceTestData.now)

        guard let mirrored = store.events.first(where: { $0.title == "Labor Day" }) else {
            return XCTFail("the holiday event should be mirrored")
        }
        XCTAssertEqual(store.editRefusal(for: mirrored)?.reason, .readOnly)
    }

    func testAnUnrepresentableSeriesIsRefusedByTheModelLayer() async {
        let eventKit = Self.fakeStore()
        eventKit.deviceEvents = [
            DeviceTestData.event(
                identifier: "odd",
                title: "Payday",
                recurrenceRules: [
                    DeviceRecurrenceRule(frequency: .monthly, daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.friday)], setPositions: [-1])
                ]
            )
        ]
        let store = Self.makeStore(eventKit: eventKit)
        await store.refreshDeviceCalendars(now: DeviceTestData.now)

        guard let mirrored = store.events.first else { return XCTFail("the event should be mirrored") }
        XCTAssertTrue(mirrored.hasUnrepresentableRecurrence)
        XCTAssertEqual(store.editRefusal(for: mirrored)?.reason, .unrepresentableRecurrence)
    }

    // MARK: - Fixtures

    private static let deviceEvents: [DeviceEvent] = [
        DeviceTestData.event(),
        DeviceTestData.event(
            identifier: "evt-2",
            externalIdentifier: "ext-2",
            calendarIdentifier: "cal-work",
            title: "1:1",
            startDate: TestData.date("2026-09-11T15:00:00Z"),
            endDate: TestData.date("2026-09-11T15:30:00Z")
        )
    ]

    private static func fakeStore(status: CalendarAccessStatus = .fullAccess) -> FakeEventKitStore {
        FakeEventKitStore(
            status: status,
            snapshot: DeviceTestData.snapshot(),
            deviceEvents: deviceEvents
        )
    }

    /// A real SQLite repository, for the assertions that are about what actually reached the
    /// database rather than what is in memory.
    private func makeSQLiteRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }

    private static func makeStore(eventKit: FakeEventKitStore) -> BetterCalendarStore {
        BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(calendars: [], events: []))),
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
    }
}
