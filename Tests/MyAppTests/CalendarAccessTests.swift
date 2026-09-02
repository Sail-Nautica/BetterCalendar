import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3.3/3.4/3.5 — Phase 3A, the permission and capability model.
///
/// Nothing here talks to EventKit or shows a system prompt. Every test drives
/// `FakeCalendarAuthorization`, which is the point of spec 3.36's fake: no iOS runtime is
/// installed on the primary development machine, the whole suite runs on the macOS destination,
/// and every authorization state — including the transitions a real device can only produce by
/// hand in Settings — has to be reachable there.
@MainActor
final class CalendarAccessTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    // MARK: - Spec 3.4: the behaviour table

    /// The whole of spec 3.4's table, asserted case by case rather than trusted to a switch
    /// statement someone will later extend.
    func testEachAuthorizationStatusReportsItsSpecifiedCapabilities() {
        let expected: [CalendarAccessStatus: (read: Bool, create: Bool, request: Bool, settings: Bool)] = [
            .notDetermined: (read: false, create: false, request: true, settings: false),
            .restricted: (read: false, create: false, request: false, settings: false),
            .denied: (read: false, create: false, request: false, settings: true),
            .writeOnly: (read: false, create: true, request: false, settings: true),
            .fullAccess: (read: true, create: true, request: false, settings: false)
        ]

        for status in CalendarAccessStatus.allCases {
            let row = try? XCTUnwrap(expected[status], "spec 3.4 has no row for \(status)")
            guard let row else { continue }
            XCTAssertEqual(status.canReadDeviceEvents, row.read, "canReadDeviceEvents for \(status)")
            XCTAssertEqual(status.canCreateDeviceEvents, row.create, "canCreateDeviceEvents for \(status)")
            XCTAssertEqual(status.allowsInAppRequest, row.request, "allowsInAppRequest for \(status)")
            XCTAssertEqual(status.isResolvableInSettings, row.settings, "isResolvableInSettings for \(status)")
        }
    }

    /// Spec 3.4: the connect affordance appears only where asking is still possible, and the
    /// Settings deep link only where Settings can actually change the answer.
    func testOnlyTheSpecifiedStatusesOfferEachRecoveryAction() {
        XCTAssertEqual(DeviceCalendarAccessMessage.forStatus(.notDetermined).action, .connect)
        XCTAssertEqual(DeviceCalendarAccessMessage.forStatus(.denied).action, .openSettings)
        XCTAssertEqual(DeviceCalendarAccessMessage.forStatus(.writeOnly).action, .openSettings)
        XCTAssertNil(DeviceCalendarAccessMessage.forStatus(.restricted).action)
        XCTAssertNil(DeviceCalendarAccessMessage.forStatus(.fullAccess).action)
    }

    /// Spec 3.4: `restricted` is not `denied` with different wording. Access is controlled by a
    /// profile or Screen Time, so the copy must not send the user looking for a switch that
    /// will not move.
    func testRestrictedCopyNeverPointsAtSettings() {
        let message = DeviceCalendarAccessMessage.forStatus(.restricted)

        XCTAssertNil(message.action)
        XCTAssertFalse(message.message.contains("Settings"), "restricted cannot be resolved in Settings")
        XCTAssertNotEqual(message.title, DeviceCalendarAccessMessage.forStatus(.denied).title)
        XCTAssertNotEqual(message.message, DeviceCalendarAccessMessage.forStatus(.denied).message)
    }

    /// BC-EK-003, the sentence the `writeOnly` case exists for: the user's device calendars are
    /// not empty, they are unreadable, and the app must never let those two look alike.
    func testWriteOnlyReportsUnreadableRatherThanEmpty() {
        XCTAssertFalse(CalendarAccessStatus.writeOnly.canReadDeviceEvents)
        XCTAssertTrue(CalendarAccessStatus.writeOnly.canCreateDeviceEvents)

        let message = DeviceCalendarAccessMessage.forStatus(.writeOnly)
        XCTAssertTrue(message.message.contains("not an empty calendar"))
    }

    /// UI/UX §9.2: no state falls through to a generic failure message.
    func testEveryStatusProducesItsOwnCopy() {
        var seenTitles: Set<String> = []

        for status in CalendarAccessStatus.allCases {
            let message = DeviceCalendarAccessMessage.forStatus(status)
            XCTAssertFalse(message.title.isEmpty, "\(status) has no title")
            XCTAssertFalse(message.message.isEmpty, "\(status) has no message")
            XCTAssertTrue(seenTitles.insert(message.title).inserted, "\(status) reuses another state's title")
        }
    }

    // MARK: - BC-EK-001: the primer precedes the system prompt

    /// Spec 3.3: never request access on first launch — and, since `load()` performs no
    /// authorization read either, launch touches nothing from EventKit at all.
    func testLaunchAsksTheSystemNothingAndReadsNothing() {
        let authorization = FakeCalendarAuthorization(status: .fullAccess)
        let store = makeStore(authorization: authorization)

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(
            store.calendarAccessStatus,
            .notDetermined,
            "the status is read when a surface needs it, not at launch"
        )

        store.refreshDeviceCalendarAccess()
        XCTAssertEqual(store.calendarAccessStatus, .fullAccess)
    }

    /// BC-EK-001: the explanation comes first. Enforced in the store rather than in the view, so
    /// no future screen can reach the system alert by calling this directly.
    func testAccessRequestIsRefusedUntilThePrimerHasBeenSeen() async {
        let authorization = FakeCalendarAuthorization(status: .notDetermined, grantResult: .fullAccess)
        let store = makeStore(authorization: authorization)

        let result = await store.requestDeviceCalendarAccess()

        XCTAssertEqual(result, .notDetermined)
        XCTAssertEqual(authorization.requestCount, 0, "the system prompt must not appear before the primer")
        XCTAssertFalse(store.deviceCalendarAccess.canRequestAccess)
    }

    /// Spec 3.3: "Not Now" is a first-class choice, and taking it must not burn the single-use
    /// system prompt.
    func testDismissingThePrimerDoesNotBurnTheSystemPrompt() {
        let authorization = FakeCalendarAuthorization(status: .notDetermined)
        let store = makeStore(authorization: authorization)

        store.markCalendarAccessPrimerSeen()
        store.refreshDeviceCalendarAccess()

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(store.calendarAccessStatus, .notDetermined)
        XCTAssertTrue(store.settings.hasSeenCalendarAccessPrimer)
        XCTAssertTrue(store.deviceCalendarAccess.canRequestAccess, "the affordance still works whenever the user is ready")
        XCTAssertFalse(
            store.deviceCalendarAccess.shouldPresentPrimerAutomatically,
            "the primer auto-presents once, not on every visit"
        )
    }

    /// Spec 3.3: request full access, because the product must display existing events.
    /// Write-only is a state to handle gracefully, never a state to request.
    func testConnectingRequestsFullAccessExactlyOnce() async {
        let authorization = FakeCalendarAuthorization(status: .notDetermined, grantResult: .fullAccess)
        let store = makeStore(authorization: authorization)

        store.markCalendarAccessPrimerSeen()
        let result = await store.requestDeviceCalendarAccess()

        XCTAssertEqual(result, .fullAccess)
        XCTAssertEqual(authorization.requestedLevels, [.full])
        XCTAssertEqual(store.calendarAccessStatus, .fullAccess)
        XCTAssertTrue(store.deviceCalendarAccess.canReadDeviceEvents)
    }

    /// Spec 3.3: the system prompt can only ever be shown once. Treat it as a single-use
    /// resource — including after it has been spent successfully.
    func testTheSystemPromptIsNeverRequestedTwice() async {
        let authorization = FakeCalendarAuthorization(status: .notDetermined, grantResult: .fullAccess)
        let store = makeStore(authorization: authorization)
        store.markCalendarAccessPrimerSeen()

        await store.requestDeviceCalendarAccess()
        let second = await store.requestDeviceCalendarAccess()

        XCTAssertEqual(second, .fullAccess)
        XCTAssertEqual(authorization.requestCount, 1)
    }

    /// Spec 3.3: after a denial the app must never re-prompt in-app. It offers a Settings deep
    /// link and otherwise stops asking.
    func testDeniedAccessIsNeverRePromptedInApp() async {
        let authorization = FakeCalendarAuthorization(status: .notDetermined, grantResult: .denied)
        let store = makeStore(authorization: authorization)
        store.markCalendarAccessPrimerSeen()

        let first = await store.requestDeviceCalendarAccess()
        let second = await store.requestDeviceCalendarAccess()

        XCTAssertEqual(first, .denied)
        XCTAssertEqual(second, .denied)
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertFalse(store.deviceCalendarAccess.canRequestAccess)
        XCTAssertEqual(store.deviceCalendarAccess.message.action, .openSettings)
    }

    // MARK: - BC-EK-002 / BC-EK-022: degradation

    /// BC-EK-002: denying calendar access leaves every Phase 1/2 local-calendar feature fully
    /// working. Not "mostly" — the app is a complete local calendar with access refused.
    func testLocalCalendarFeaturesAreUnaffectedByDeniedAccess() {
        let store = makeStore(authorization: FakeCalendarAuthorization(status: .denied))
        store.refreshDeviceCalendarAccess()

        XCTAssertEqual(store.calendarAccessStatus, .denied)

        let calendarID = try? XCTUnwrap(store.defaultCalendarID)
        guard let calendarID else { return }

        var draft = EventDraft(calendarID: calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Lab"
        XCTAssertTrue(store.saveEvent(from: draft), "creating a local event must still work")

        guard let saved = store.events.first(where: { $0.title == "Lab" }) else {
            return XCTFail("the created event is missing")
        }

        store.addCalendar(named: "Personal", colorName: .success)
        guard let personal = store.calendars.first(where: { $0.name == "Personal" }) else {
            return XCTFail("creating a local calendar must still work")
        }

        // Every mutation bumps the event's `versionNumber` (spec 2.14), so each step re-reads
        // the row rather than reusing a stale copy — otherwise the optimistic-concurrency guard
        // rejects the next write and this test would measure that instead of BC-EK-002.
        func current() -> CalendarEvent? { store.events.first { $0.id == saved.id } }

        var edited = saved
        edited.title = "Lab Section"
        XCTAssertTrue(store.saveEvent(from: EventDraft(event: edited)), "editing a local event must still work")
        XCTAssertEqual(current()?.title, "Lab Section")

        guard let beforeMove = current() else { return XCTFail("the edited event is missing") }
        store.moveEvent(beforeMove, to: TestData.date("2026-09-03T14:00:00Z"))
        XCTAssertEqual(
            current()?.startDate,
            TestData.date("2026-09-03T14:00:00Z"),
            "moving a local event must still work"
        )

        guard let beforeReparent = current() else { return XCTFail("the moved event is missing") }
        XCTAssertTrue(
            store.moveEventToCalendar(beforeReparent, calendarID: personal.id),
            "moving a local event between local calendars must still work"
        )
        XCTAssertEqual(current()?.calendarID, personal.id)

        guard let beforeDelete = current() else { return XCTFail("the reparented event is missing") }
        store.deleteEvent(beforeDelete)
        XCTAssertNil(current(), "deleting a local event must still work")

        XCTAssertNil(store.lastError, "a refused permission is not a data error")
    }

    /// BC-EK-022: a user can revoke access in Settings while the app is backgrounded. On the
    /// next foreground read the app must degrade — which means changing exactly one thing.
    func testRevokingAccessWhileBackgroundedChangesNothingButTheStatus() {
        let authorization = FakeCalendarAuthorization(status: .fullAccess)
        let store = makeStore(authorization: authorization)
        store.refreshDeviceCalendarAccess()

        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Seminar"
        XCTAssertTrue(store.saveEvent(from: draft))

        let eventsBefore = store.events
        let calendarsBefore = store.calendars
        let settingsBefore = store.settings

        authorization.simulateExternalChange(to: .denied)
        store.refreshDeviceCalendarAccess()

        XCTAssertEqual(store.calendarAccessStatus, .denied)
        XCTAssertEqual(store.events, eventsBefore)
        XCTAssertEqual(store.calendars, calendarsBefore)
        XCTAssertEqual(store.settings, settingsBefore)
        XCTAssertNil(store.lastError, "losing permission is not a data error and must not alert")
    }

    /// The other half of BC-EK-022: re-granting in Settings is picked up by the foreground read,
    /// without the app prompting again — it has no prompt left to spend.
    func testRegrantingAccessInSettingsIsPickedUpWithoutAnotherPrompt() {
        let authorization = FakeCalendarAuthorization(status: .denied)
        let store = makeStore(authorization: authorization)
        store.refreshDeviceCalendarAccess()
        XCTAssertFalse(store.deviceCalendarAccess.canReadDeviceEvents)

        authorization.simulateExternalChange(to: .fullAccess)
        store.refreshDeviceCalendarAccess()

        XCTAssertEqual(store.calendarAccessStatus, .fullAccess)
        XCTAssertTrue(store.deviceCalendarAccess.canReadDeviceEvents)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    /// Spec 3.4: authorization is re-checked, never cached for the process lifetime. A second
    /// store over the same database reports the device's live answer, not the previous one.
    func testAuthorizationStatusIsReadLiveRatherThanPersisted() throws {
        let repository = try makeRepository()

        let granted = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization(status: .fullAccess)
        )
        granted.refreshDeviceCalendarAccess()
        XCTAssertEqual(granted.calendarAccessStatus, .fullAccess)

        let relaunched = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization(status: .denied)
        )
        XCTAssertEqual(relaunched.calendarAccessStatus, .notDetermined, "nothing about access survives a launch")

        relaunched.refreshDeviceCalendarAccess()
        XCTAssertEqual(relaunched.calendarAccessStatus, .denied)
    }

    // MARK: - Persistence

    /// The one bit of this flow Better Calendar owns, and therefore the only one it stores.
    func testPrimerSeenFlagRoundTripsThroughSQLite() throws {
        let repository = try makeRepository()
        // `load()` returns `.seed` — settings included — for a database with no calendar rows,
        // so a settings round trip has to start from a database that has some.
        try repository.save(TestData.database(events: []))

        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization()
        )
        XCTAssertFalse(store.settings.hasSeenCalendarAccessPrimer)
        XCTAssertTrue(store.markCalendarAccessPrimerSeen())

        XCTAssertTrue(try repository.load().settings.hasSeenCalendarAccessPrimer)

        let relaunched = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization()
        )
        XCTAssertTrue(relaunched.settings.hasSeenCalendarAccessPrimer)
        XCTAssertFalse(relaunched.deviceCalendarAccess.shouldPresentPrimerAutomatically)
    }

    /// Spec 3.3/3A.4: the new key needs no migration. A database written before it existed —
    /// simulated by deleting the row — loads with the primer unseen and every other setting
    /// intact.
    func testDatabaseWithoutThePrimerKeyLoadsWithItUnseen() throws {
        let databaseURL = try makeDatabaseURL()
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database(events: []))

        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization()
        )
        store.markCalendarAccessPrimerSeen()
        store.updateSettings { $0.snapIntervalMinutes = 30 }

        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM application_settings WHERE key = ?",
                arguments: ["has_seen_calendar_access_primer"]
            )
        }

        let loaded = try SQLiteCalendarRepository(fileURL: databaseURL).load()
        XCTAssertFalse(loaded.settings.hasSeenCalendarAccessPrimer)
        XCTAssertEqual(loaded.settings.snapIntervalMinutes, 30, "the missing key must not disturb its neighbours")
    }

    // MARK: - Helpers

    private func makeStore(authorization: FakeCalendarAuthorization) -> BetterCalendarStore {
        BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(events: []))),
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: authorization
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "CalendarAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appending(path: "BetterCalendar.sqlite")
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        SQLiteCalendarRepository(fileURL: try makeDatabaseURL())
    }
}
