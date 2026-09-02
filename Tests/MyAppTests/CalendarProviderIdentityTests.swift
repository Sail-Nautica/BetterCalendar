import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3.6/3.10/3.12/3.16: the Phase 3 prerequisites — the changes that had to land *before*
/// any EventKit code exists, because they alter types every later adapter builds on.
///
/// Nothing here talks to EventKit. Every test constructs a calendar shaped the way a mirrored
/// device calendar will be (an account, a provider identifier, read-only, arbitrary color) and
/// asserts the engine already treats it correctly. That is the point: when Phase 3's adapter
/// starts producing these values for real, the behavior they trigger is already proven.
final class CalendarProviderIdentityTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    // MARK: - Spec 3.6: provider identity survives the round trip

    /// The headline gap this work closed: `calendarArguments` used to hardcode every provider
    /// column, so a calendar with real provider identity could not be stored at all.
    func testDeviceShapedCalendarProviderIdentityRoundTripsThroughSQLite() throws {
        let repository = try makeRepository()
        let deviceCalendar = Self.deviceCalendar()

        try repository.save(TestData.database(calendars: [deviceCalendar], events: []))
        let loaded = try repository.load()

        let stored = try XCTUnwrap(loaded.calendars.first)
        XCTAssertEqual(stored.provider, .apple)
        XCTAssertEqual(stored.connectionMethod, .device)
        XCTAssertEqual(stored.providerAccountID, "ek-source-icloud")
        XCTAssertEqual(stored.providerCalendarID, "ek-calendar-work")
        XCTAssertEqual(stored.accountName, "iCloud")
        XCTAssertEqual(stored.timeZoneIdentifier, "America/Detroit")
        XCTAssertTrue(stored.isReadOnly)
        XCTAssertEqual(stored.capabilities, .readOnly)
    }

    /// The other half of the same guarantee: an ordinary local calendar must round-trip exactly
    /// as it always did, with no provider identity invented for it.
    func testLocalCalendarRoundTripsWithoutGainingProviderIdentity() throws {
        let repository = try makeRepository()
        let local = TestData.calendar()

        try repository.save(TestData.database(calendars: [local], events: []))
        let stored = try XCTUnwrap(try repository.load().calendars.first)

        XCTAssertEqual(stored, local, "a local calendar must survive the round trip unchanged")
        XCTAssertEqual(stored.provider, .betterCalendar)
        XCTAssertEqual(stored.connectionMethod, .local)
        XCTAssertNil(stored.providerAccountID)
        XCTAssertNil(stored.providerCalendarID, "the local UUID is not a provider identifier")
        XCTAssertNil(stored.colorHex, "a design-token color must not round-trip as a raw hex")
        XCTAssertFalse(stored.isReadOnly)
    }

    /// Spec 3.6: device calendars carry arbitrary RGB, which must survive verbatim rather than
    /// being snapped to one of the six design tokens on the way to disk.
    func testArbitraryProviderColorSurvivesRoundTripWhileTokenColorsStayTokens() throws {
        let repository = try makeRepository()
        var deviceCalendar = Self.deviceCalendar()
        deviceCalendar.colorHex = "#7B2D8E"

        try repository.save(TestData.database(calendars: [deviceCalendar, TestData.calendar(id: TestData.secondCalendarID, name: "School", isDefault: false, sortOrder: 1)], events: []))
        let loaded = try repository.load()

        let device = try XCTUnwrap(loaded.calendars.first { $0.id == deviceCalendar.id })
        XCTAssertEqual(device.colorHex, "#7B2D8E", "the provider's own color must be preserved exactly")

        let local = try XCTUnwrap(loaded.calendars.first { $0.id == TestData.secondCalendarID })
        XCTAssertNil(local.colorHex)
        XCTAssertEqual(local.colorName, .betterBlue)
    }

    /// Spec 3.6: the tolerant-decoding rule. A calendar encoded before provider identity existed
    /// — which is every calendar in every shipped build — must decode as what it was.
    func testCalendarDecodedWithoutProviderFieldsIsLocalAndWritable() throws {
        let legacyJSON = """
        {
            "id": "\(TestData.calendarID.uuidString)",
            "name": "School",
            "colorName": "Better Blue",
            "isVisible": true,
            "isDefault": true,
            "sortOrder": 0,
            "createdAt": 780000000,
            "updatedAt": 780000000
        }
        """

        let decoded = try JSONDecoder().decode(BetterCalendar.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.provider, .betterCalendar)
        XCTAssertEqual(decoded.connectionMethod, .local)
        XCTAssertEqual(decoded.capabilities, .localDefaults)
        XCTAssertFalse(decoded.isReadOnly)
        XCTAssertTrue(decoded.allowsEventEditing, "a legacy calendar must remain fully editable")
        XCTAssertTrue(decoded.allowsEventCreation)
    }

    /// Capabilities are stored as a JSON blob precisely so the set can grow without a migration;
    /// a blob missing a field must fall back to the permissive default rather than failing shut.
    func testPartialCapabilitiesBlobDecodesToPermissiveDefaults() throws {
        let partialJSON = #"{"allowsContentModifications": false}"#

        let decoded = try JSONDecoder().decode(CalendarCapabilities.self, from: Data(partialJSON.utf8))

        XCTAssertFalse(decoded.allowsContentModifications, "the stated field must win")
        XCTAssertTrue(decoded.allowsEventCreation, "an absent field falls back to the default")
        XCTAssertTrue(decoded.supportsRecurrence)
    }

    // MARK: - Spec 3.10 (BC-EK-010): read-only enforced at the model layer

    /// The rule that matters: the rejection happens *before* an `EngineTransaction` exists, so
    /// there is no local write to roll back and the user never sees a change that then vanishes.
    func testCreatingOnAReadOnlyCalendarIsRejectedAndWritesNothing() throws {
        let fixture = try makeReadOnlyCalendarFixture()
        let newEvent = TestData.event(id: UUID(), calendarID: Self.readOnlyCalendarID, title: "Should never exist")

        let outcome = EventMutationUseCases.createEvent(newEvent, in: fixture.context)

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .creationNotAllowed)
        XCTAssertEqual(violation.calendarID, Self.readOnlyCalendarID)
        XCTAssertEqual(violation.calendarName, "Holidays")

        let reloaded = try fixture.repository.load()
        XCTAssertFalse(reloaded.events.contains { $0.id == newEvent.id }, "nothing may be written locally")
        XCTAssertTrue(reloaded.pendingMutations.isEmpty, "a rejected mutation must not reach the outbox")
    }

    func testEditingAnEventOnAReadOnlyCalendarIsRejected() throws {
        let fixture = try makeReadOnlyCalendarFixture()

        let outcome = EventMutationUseCases.updateEvent(
            eventID: Self.readOnlyEventID,
            expectedVersionNumber: 1,
            in: fixture.context
        ) { $0.title = "Renamed" }

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .readOnly)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.first { $0.id == Self.readOnlyEventID }?.title, "Thanksgiving")
    }

    /// Deleting is a content modification too — and rejecting it before the tombstone is minted
    /// is what stops the undo banner offering to restore something that was never removed.
    func testDeletingAnEventOnAReadOnlyCalendarIsRejectedAndWritesNoTombstone() throws {
        let fixture = try makeReadOnlyCalendarFixture()

        let outcome = EventMutationUseCases.deleteEvent(
            eventID: Self.readOnlyEventID,
            expectedVersionNumber: 1,
            in: fixture.context
        )

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .readOnly)

        let reloaded = try fixture.repository.load()
        XCTAssertTrue(reloaded.events.contains { $0.id == Self.readOnlyEventID })
        XCTAssertTrue(reloaded.deletedEventTombstones.isEmpty, "a refused delete must not write a tombstone")
    }

    /// A move has two calendars, and the destination is the one that has to accept a new event.
    func testMovingAnEventOntoAReadOnlyCalendarIsRejected() throws {
        let fixture = try makeReadOnlyCalendarFixture()

        let outcome = EventMutationUseCases.moveEventToCalendar(
            eventID: TestData.eventID,
            calendarID: Self.readOnlyCalendarID,
            expectedVersionNumber: 1,
            in: fixture.context
        )

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .creationNotAllowed)
        XCTAssertEqual(violation.calendarID, Self.readOnlyCalendarID, "the destination is what refused, not the source")
    }

    func testDuplicatingAnEventOnAReadOnlyCalendarIsRejected() throws {
        let fixture = try makeReadOnlyCalendarFixture()
        let source = try XCTUnwrap(fixture.context.database.events.first { $0.id == Self.readOnlyEventID })

        let outcome = EventMutationUseCases.duplicateEvent(source, in: fixture.context)

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .creationNotAllowed)
    }

    /// The whole point of separating `isReadOnly` from `capabilities`: a writable calendar stays
    /// writable, so this gate cannot regress ordinary editing.
    func testWritableCalendarsAreUnaffectedByTheCapabilityGate() throws {
        let fixture = try makeReadOnlyCalendarFixture()
        let newEvent = TestData.event(id: UUID(), calendarID: TestData.calendarID, title: "Ordinary event")

        let outcome = EventMutationUseCases.createEvent(newEvent, in: fixture.context)

        guard case .applied = outcome else {
            return XCTFail("a writable calendar must still accept events, got \(outcome)")
        }
    }

    // MARK: - Spec 3.16 (BC-EK-016): the double-notification rule

    /// The bug this prevents: a mirrored event's alarms are delivered by the system, so
    /// scheduling our own notification for one means the user is notified twice per event.
    func testDeviceCalendarEventsAreExcludedFromNotificationPlanning() {
        let planner = LocalNotificationPlanner()
        let now = TestData.date("2026-09-02T08:00:00Z")

        var deviceCalendar = Self.deviceCalendar()
        deviceCalendar.isReadOnly = false
        deviceCalendar.capabilities = .localDefaults

        var mirroredEvent = TestData.event(
            id: UUID(),
            calendarID: deviceCalendar.id,
            title: "Mirrored standup",
            startDate: TestData.date("2026-09-02T14:00:00Z"),
            endDate: TestData.date("2026-09-02T15:00:00Z")
        )
        mirroredEvent.reminders = [
            EventReminder(id: UUID(), offset: .minutesBefore(10)),
            EventReminder(id: UUID(), offset: .atStart)
        ]

        let plan = planner.plan(
            events: [mirroredEvent],
            calendars: [deviceCalendar],
            pendingIdentifiers: [],
            now: now,
            horizonEnd: TestData.date("2026-09-09T08:00:00Z")
        )

        XCTAssertTrue(
            plan.requestsToSchedule.isEmpty,
            "a device calendar's alarms are the system's job — scheduling our own notifies the user twice"
        )
    }

    /// The exclusion must be surgical: a local event alongside a mirrored one still notifies.
    func testLocalEventsStillNotifyWhenDeviceCalendarsArePresent() {
        let planner = LocalNotificationPlanner()
        let now = TestData.date("2026-09-02T08:00:00Z")

        let deviceCalendar = Self.deviceCalendar()
        let localCalendar = TestData.calendar()

        var mirroredEvent = TestData.event(id: UUID(), calendarID: deviceCalendar.id, title: "Mirrored")
        mirroredEvent.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(10))]

        var localEvent = TestData.event(id: UUID(), calendarID: localCalendar.id, title: "Mine")
        localEvent.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(10))]

        let plan = planner.plan(
            events: [mirroredEvent, localEvent],
            calendars: [deviceCalendar, localCalendar],
            pendingIdentifiers: [],
            now: now,
            horizonEnd: TestData.date("2026-09-09T08:00:00Z")
        )

        XCTAssertEqual(plan.requestsToSchedule.count, 1)
        XCTAssertEqual(plan.requestsToSchedule.first?.eventID, localEvent.id)
    }

    /// Because the exclusion lives in the planner, an event that *becomes* device-owned has its
    /// existing notification reconciled away rather than left orphaned — that diff is exactly
    /// what `identifiersToCancel` is for.
    func testNotificationsAreCancelledWhenAnEventBecomesDeviceOwned() {
        let planner = LocalNotificationPlanner()
        let now = TestData.date("2026-09-02T08:00:00Z")

        var calendar = TestData.calendar()
        var event = TestData.event(
            id: UUID(),
            calendarID: calendar.id,
            startDate: TestData.date("2026-09-02T14:00:00Z"),
            endDate: TestData.date("2026-09-02T15:00:00Z")
        )
        event.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(10))]

        let before = planner.plan(
            events: [event],
            calendars: [calendar],
            pendingIdentifiers: [],
            now: now,
            horizonEnd: TestData.date("2026-09-09T08:00:00Z")
        )
        let scheduledIdentifiers = Set(before.requestsToSchedule.map(\.identifier))
        XCTAssertFalse(scheduledIdentifiers.isEmpty, "precondition: the local event schedules something")

        calendar.connectionMethod = .device
        let after = planner.plan(
            events: [event],
            calendars: [calendar],
            pendingIdentifiers: scheduledIdentifiers,
            now: now,
            horizonEnd: TestData.date("2026-09-09T08:00:00Z")
        )

        XCTAssertTrue(after.requestsToSchedule.isEmpty)
        XCTAssertEqual(Set(after.identifiersToCancel), scheduledIdentifiers, "stale requests must be cancelled, not orphaned")
    }

    // MARK: - Spec 3.12: the untitled-event placeholder

    /// EventKit and RFC 5545 both allow an empty title; Phase 1's editor does not, so nothing in
    /// the app produced one until now. Every display surface goes through `displayTitle`.
    func testUntitledEventsRenderAPlaceholderRatherThanEmptyText() {
        XCTAssertEqual(TestData.event(title: "").displayTitle, "(No title)")
        XCTAssertEqual(TestData.event(title: "   ").displayTitle, "(No title)", "whitespace is not a title")
        XCTAssertEqual(TestData.event(title: "Calculus").displayTitle, "Calculus")
        XCTAssertEqual(TestData.event(title: "  Calculus  ").displayTitle, "Calculus", "titles are trimmed for display")
    }

    // MARK: - Fixtures

    private static let readOnlyCalendarID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private static let readOnlyEventID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!

    /// Shaped the way Phase 3's adapter will populate a mirrored EventKit calendar.
    private static func deviceCalendar(
        id: UUID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        name: String = "Work"
    ) -> BetterCalendar {
        BetterCalendar(
            id: id,
            name: name,
            colorName: .betterBlue,
            isVisible: true,
            isDefault: false,
            sortOrder: 0,
            createdAt: TestData.date("2026-09-01T12:00:00Z"),
            updatedAt: TestData.date("2026-09-01T12:00:00Z"),
            versionNumber: 1,
            provider: .apple,
            connectionMethod: .device,
            providerAccountID: "ek-source-icloud",
            providerCalendarID: "ek-calendar-work",
            accountName: "iCloud",
            isReadOnly: true,
            timeZoneIdentifier: "America/Detroit",
            capabilities: .readOnly
        )
    }

    private struct Fixture {
        var repository: SQLiteCalendarRepository
        var context: EventMutationUseCases.Context
    }

    /// One writable local calendar with an event on it, and one read-only calendar with an event
    /// on it — so every rejection test can also prove the writable side still works.
    private func makeReadOnlyCalendarFixture() throws -> Fixture {
        let repository = try makeRepository()

        var readOnlyCalendar = Self.deviceCalendar(id: Self.readOnlyCalendarID, name: "Holidays")
        readOnlyCalendar.providerCalendarID = "ek-calendar-holidays"

        let readOnlyEvent = TestData.event(
            id: Self.readOnlyEventID,
            calendarID: Self.readOnlyCalendarID,
            title: "Thanksgiving",
            startDate: TestData.date("2026-11-26T00:00:00Z"),
            endDate: TestData.date("2026-11-27T00:00:00Z")
        )

        try repository.save(
            TestData.database(
                calendars: [TestData.calendar(), readOnlyCalendar],
                events: [TestData.event(), readOnlyEvent]
            )
        )

        return Fixture(
            repository: repository,
            context: EventMutationUseCases.Context(database: try repository.load(), now: TestData.date("2026-09-02T12:00:00Z"))
        )
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "CalendarProviderIdentityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
