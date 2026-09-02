import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3B — Phase 3B M1: the discovery foundation.
///
/// Nothing here touches EventKit or a screen. `DeviceCalendarMirror` is a pure function over
/// value types, which is exactly what makes the rules that matter — the matching key, the split
/// between provider-owned and local-only fields, and idempotence — assertable rather than
/// hoped for.
@MainActor
final class DeviceCalendarDiscoveryTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    // MARK: - Spec 3B.2: attributing a source to a provider

    func testEachSourceTypeMapsToItsSpecifiedProvider() {
        XCTAssertEqual(Self.source(type: .local, title: "On My iPhone").provider, .deviceLocal)
        XCTAssertEqual(Self.source(type: .exchange, title: "Work").provider, .exchange)
        XCTAssertEqual(Self.source(type: .subscribed, title: "Subscribed").provider, .subscribed)
        XCTAssertEqual(Self.source(type: .birthdays, title: "Birthdays").provider, .apple)
        XCTAssertEqual(Self.source(type: .mobileMe, title: "iCloud").provider, .apple)
    }

    /// Spec 3B.2: a source is Google only when its identity says so, never by elimination. A
    /// wrong `.otherAccount` is a cosmetic grouping error; a wrong `.google` becomes a false
    /// match in Phase 3F's duplicate-connection rule.
    func testCalDAVIsAttributedNarrowlyAndNeverGuessesGoogle() {
        XCTAssertEqual(Self.source(type: .calDAV, title: "Gmail").provider, .google)
        XCTAssertEqual(Self.source(type: .calDAV, title: "someone@googlemail.com").provider, .google)
        XCTAssertEqual(Self.source(type: .calDAV, title: "iCloud").provider, .apple)
        XCTAssertEqual(Self.source(type: .calDAV, title: "Fastmail").provider, .otherAccount)
        XCTAssertEqual(Self.source(type: .calDAV, title: "").provider, .otherAccount)
    }

    /// Spec 3.10: birthday and subscribed calendars are always read-only, and EventKit
    /// documents that a subscribed CalDAV calendar reports `.calDAV`, not `.subscription` —
    /// so ambience has to follow `isSubscribed`, not `type`.
    func testAmbientAndReadOnlyDerivationFollowsSubscriptionRatherThanType() {
        let holidayFeed = Self.deviceCalendar(identifier: "holidays", title: "US Holidays", type: .calDAV, isSubscribed: true)
        XCTAssertTrue(holidayFeed.isAmbient)
        XCTAssertTrue(holidayFeed.isReadOnly)
        XCTAssertFalse(holidayFeed.capabilities.allowsEventCreation)
        XCTAssertTrue(holidayFeed.capabilities.isSubscribed)

        let birthdays = Self.deviceCalendar(identifier: "birthdays", title: "Birthdays", type: .birthday, allowsContentModifications: false)
        XCTAssertTrue(birthdays.isAmbient)
        XCTAssertTrue(birthdays.isReadOnly)

        let work = Self.deviceCalendar(identifier: "work", title: "Work", type: .calDAV)
        XCTAssertFalse(work.isAmbient)
        XCTAssertFalse(work.isReadOnly)
        XCTAssertTrue(work.capabilities.allowsEventCreation)
        XCTAssertTrue(work.capabilities.supportsReminders)
    }

    // MARK: - Spec 3B.3: first discovery

    func testFirstDiscoveryMirrorsEveryCalendarWithItsProviderIdentity() {
        let plan = DeviceCalendarMirror.plan(
            devices: Self.threeCalendarDevice(),
            existing: [TestData.calendar()],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )

        XCTAssertEqual(plan.summary.added, 3)
        XCTAssertEqual(plan.summary.updated, 0)
        XCTAssertEqual(plan.summary.markedUnavailable, 0)

        let mirrored = Self.calendars(in: plan)
        XCTAssertEqual(mirrored.count, 3)

        let work = try? XCTUnwrap(mirrored.first { $0.providerCalendarID == "work" })
        XCTAssertEqual(work?.name, "Work")
        XCTAssertEqual(work?.connectionMethod, .device)
        XCTAssertEqual(work?.provider, .exchange)
        XCTAssertEqual(work?.providerAccountID, "source-exchange")
        XCTAssertEqual(work?.accountName, "Work Exchange")
        XCTAssertEqual(work?.colorHex, "#7B2D8E")
        XCTAssertFalse(work?.isReadOnly ?? true)
        XCTAssertNil(work?.timeZoneIdentifier, "EKCalendar has no time zone to mirror")
    }

    /// Spec 3.8's default display rule: everything on, except the large ambient calendars that
    /// would swamp a day view on first connect.
    func testAmbientCalendarsAreMirroredHiddenAndEverythingElseVisible() {
        let plan = DeviceCalendarMirror.plan(
            devices: Self.threeCalendarDevice(),
            existing: [TestData.calendar()],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )
        let mirrored = Self.calendars(in: plan)

        XCTAssertEqual(mirrored.first { $0.providerCalendarID == "work" }?.isVisible, true)
        XCTAssertEqual(mirrored.first { $0.providerCalendarID == "personal" }?.isVisible, true)
        XCTAssertEqual(mirrored.first { $0.providerCalendarID == "holidays" }?.isVisible, false)
    }

    /// Discovery must not touch the user's local calendars, steal their default, or interleave
    /// itself into their ordering.
    func testDiscoveryLeavesLocalCalendarsAndTheExistingDefaultAlone() {
        let local = TestData.calendar()
        let plan = DeviceCalendarMirror.plan(
            devices: Self.threeCalendarDevice(),
            existing: [local],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )

        XCTAssertFalse(
            Self.calendars(in: plan).contains { $0.id == local.id },
            "a local calendar must not appear in a discovery plan at all"
        )
        XCTAssertTrue(Self.calendars(in: plan).allSatisfy { !$0.isDefault }, "discovery never sets a default")
        XCTAssertTrue(
            Self.calendars(in: plan).allSatisfy { $0.sortOrder > local.sortOrder },
            "device calendars sort after the local ones that were already there"
        )
    }

    // MARK: - Spec 3B.3: subsequent discovery

    /// The property that lets Phase 3E run this on every foreground: an unchanged device costs
    /// one comparison and produces no writes.
    func testDiscoveryAgainstAnUnchangedDeviceProducesNoChanges() {
        let devices = Self.threeCalendarDevice()
        let first = DeviceCalendarMirror.plan(
            devices: devices,
            existing: [TestData.calendar()],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )
        let mirrored = [TestData.calendar()] + Self.calendars(in: first)

        let second = DeviceCalendarMirror.plan(devices: devices, existing: mirrored, now: Self.later)

        XCTAssertTrue(second.isEmpty, "a second pass over an unchanged device must write nothing")
        XCTAssertTrue(second.summary.isNoOp)
        XCTAssertEqual(second.summary.unchanged, 3)
    }

    /// A device calendar coloured exactly like one of the six design tokens is the case where a
    /// normalisation mismatch between the planner and the repository would rewrite the row on
    /// every pass, forever.
    func testATokenColouredDeviceCalendarIsStillIdempotent() {
        let device = Self.deviceCalendar(identifier: "work", title: "Work", type: .calDAV, colorHex: CalendarColorName.success.hexValue)
        let first = DeviceCalendarMirror.plan(devices: [device], existing: [], now: Self.now, makeIdentifier: Self.deterministicIdentifiers())

        let mirrored = Self.calendars(in: first)
        XCTAssertEqual(mirrored.first?.colorName, .success)
        XCTAssertNil(mirrored.first?.colorHex, "a token colour must not round-trip as a raw hex")

        let second = DeviceCalendarMirror.plan(devices: [device], existing: mirrored, now: Self.later)
        XCTAssertTrue(second.isEmpty)
    }

    /// Spec 3B.3's field-ownership split, which is the safety property of the whole mirror.
    func testAnUpstreamRenameUpdatesInPlaceAndPreservesEveryLocalOnlyField() {
        let device = Self.deviceCalendar(identifier: "work", title: "Work", type: .calDAV, colorHex: "#7B2D8E")
        let first = DeviceCalendarMirror.plan(devices: [device], existing: [], now: Self.now, makeIdentifier: Self.deterministicIdentifiers())

        // The user hides it, makes it their default, and drags it up the list.
        var mirrored = try! XCTUnwrap(Self.calendars(in: first).first)
        mirrored.isVisible = false
        mirrored.isDefault = true
        mirrored.sortOrder = 0

        var renamed = device
        renamed.title = "Work (2026)"
        renamed.colorHex = "#112233"
        renamed.allowsContentModifications = false

        let second = DeviceCalendarMirror.plan(devices: [renamed], existing: [mirrored], now: Self.later)
        let updated = try! XCTUnwrap(Self.calendars(in: second).first)

        XCTAssertEqual(second.summary.updated, 1)
        XCTAssertEqual(updated.id, mirrored.id, "the row id is stable, or Phase 3C reparents every event on it")
        XCTAssertEqual(updated.name, "Work (2026)")
        XCTAssertEqual(updated.colorHex, "#112233")
        XCTAssertTrue(updated.isReadOnly)
        XCTAssertEqual(updated.versionNumber, mirrored.versionNumber + 1)
        XCTAssertEqual(updated.updatedAt, Self.later)

        XCTAssertFalse(updated.isVisible, "the user hid this calendar; a rename upstream must not unhide it")
        XCTAssertTrue(updated.isDefault, "isDefault is local-only mirror state (ADR 0005)")
        XCTAssertEqual(updated.sortOrder, 0, "ordering is the user's")
    }

    /// Identity is the account plus the provider's calendar identifier — never the name.
    func testTwoAccountsWithIdenticallyNamedCalendarsStayDistinct() {
        let icloudWork = Self.deviceCalendar(identifier: "cal-1", title: "Work", type: .calDAV, source: Self.source(type: .mobileMe, title: "iCloud", identifier: "source-icloud"))
        let exchangeWork = Self.deviceCalendar(identifier: "cal-1", title: "Work", type: .exchange, source: Self.source(type: .exchange, title: "Work Exchange", identifier: "source-exchange"))

        let plan = DeviceCalendarMirror.plan(
            devices: [icloudWork, exchangeWork],
            existing: [],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )

        XCTAssertEqual(plan.summary.added, 2, "the same calendar identifier under two accounts is two calendars")
        XCTAssertEqual(Set(Self.calendars(in: plan).map(\.providerAccountID)), ["source-icloud", "source-exchange"])
    }

    // MARK: - Spec 3B.4: availability

    func testACalendarThatDisappearsIsMarkedUnavailableRatherThanDeleted() {
        let devices = Self.threeCalendarDevice()
        let first = DeviceCalendarMirror.plan(devices: devices, existing: [], now: Self.now, makeIdentifier: Self.deterministicIdentifiers())
        var mirrored = Self.calendars(in: first)

        // The user hid one of them; losing the account must not lose that.
        let holidayIndex = try! XCTUnwrap(mirrored.firstIndex { $0.providerCalendarID == "holidays" })
        mirrored[holidayIndex].isVisible = true

        let remaining = devices.filter { $0.source.identifier != "source-exchange" }
        let second = DeviceCalendarMirror.plan(devices: remaining, existing: mirrored, now: Self.later)

        XCTAssertEqual(second.summary.markedUnavailable, 1)
        XCTAssertFalse(
            second.changes.contains { if case .deleteCalendar = $0 { true } else { false } },
            "a vanished calendar is marked, never deleted"
        )

        let marked = try! XCTUnwrap(Self.calendars(in: second).first)
        XCTAssertTrue(marked.isUnavailable)
        XCTAssertEqual(marked.unavailableSince, Self.later)
        XCTAssertFalse(marked.isWritableDestination, "an unavailable calendar is not a destination")
    }

    /// Re-marking an already-unavailable calendar would rewrite `unavailableSince` on every
    /// pass — and that timestamp is what Phase 3E's retention limit measures from.
    func testAnAlreadyUnavailableCalendarIsNotReMarked() {
        var row = Self.mirroredRow()
        row.isUnavailable = true
        row.unavailableSince = Self.now

        let plan = DeviceCalendarMirror.plan(devices: [], existing: [row], now: Self.later)

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary.unchanged, 1)
    }

    /// BC-EK-022 at the calendar level: re-adding an account reconnects its calendars by
    /// provider identity instead of importing a second copy of each.
    func testAReturningCalendarReconnectsToItsOwnRowRatherThanDuplicating() {
        let device = Self.deviceCalendar(identifier: "work", title: "Work", type: .calDAV)
        var row = Self.mirroredRow(providerCalendarID: "work", name: "Work")
        row.isUnavailable = true
        row.unavailableSince = Self.now
        row.isVisible = false

        let plan = DeviceCalendarMirror.plan(devices: [device], existing: [row], now: Self.later)

        XCTAssertEqual(plan.summary.reconnected, 1)
        XCTAssertEqual(plan.summary.added, 0, "reconnection is not a re-import")

        let reconnected = try! XCTUnwrap(Self.calendars(in: plan).first)
        XCTAssertEqual(reconnected.id, row.id)
        XCTAssertFalse(reconnected.isUnavailable)
        XCTAssertNil(reconnected.unavailableSince)
        XCTAssertFalse(reconnected.isVisible, "the state the user left it in comes back with it")
    }

    /// Spec 3B.4: an unavailable calendar refuses writes at the model layer, and says why in
    /// its own words rather than claiming to be read-only.
    func testWritingToAnUnavailableCalendarIsRejectedWithItsOwnReason() {
        var row = Self.mirroredRow()
        row.isUnavailable = true

        let violation = EventMutationUseCases.capabilityViolation(
            writingTo: row.id,
            creating: true,
            in: TestData.database(calendars: [row], events: [])
        )

        XCTAssertEqual(violation?.reason, .unavailable)
        XCTAssertTrue(violation?.message.contains("isn't available") ?? false)
    }

    // MARK: - Spec 3B.7: colour

    func testProviderColoursRenderFromHexAndFallBackToTheTokenWhenUnparseable() {
        var calendar = Self.mirroredRow()
        calendar.colorHex = "#7B2D8E"
        XCTAssertEqual(calendar.displaySwatch, CalendarSwatch(hex: "#7B2D8E"))

        calendar.colorHex = "not a colour"
        XCTAssertEqual(calendar.displaySwatch, calendar.colorName.swatch, "an unreadable hex renders as the token, not as nothing")

        calendar.colorHex = nil
        XCTAssertEqual(calendar.displaySwatch, calendar.colorName.swatch)
    }

    func testSwatchParsingAcceptsTheShapesProvidersActuallySend() {
        XCTAssertEqual(CalendarSwatch(hex: "#FFFFFF")?.relativeLuminance, 1.0)
        XCTAssertEqual(CalendarSwatch(hex: "000000")?.relativeLuminance, 0.0)
        XCTAssertEqual(CalendarSwatch(hex: "#7b2d8e"), CalendarSwatch(hex: "#7B2D8E"), "hex is case-insensitive")
        XCTAssertEqual(CalendarSwatch(hex: "#7B2D8EFF"), CalendarSwatch(hex: "#7B2D8E"), "alpha is dropped, not honoured")
        XCTAssertNil(CalendarSwatch(hex: "#12345"))
        XCTAssertNil(CalendarSwatch(hex: "#GGGGGG"))
        XCTAssertNil(CalendarSwatch(hex: ""))
    }

    func testForegroundContrastFollowsTheSwatchRatherThanBeingFixed() {
        XCTAssertTrue(CalendarSwatch(hex: "#17243D")?.prefersLightForeground ?? false, "white text on navy")
        XCTAssertFalse(CalendarSwatch(hex: "#FFEE88")?.prefersLightForeground ?? true, "dark text on pale yellow")
    }

    // MARK: - The seam

    func testTheFakeStoreReportsWhatItIsScriptedToAndCountsDiscoveries() throws {
        let store = FakeEventKitStore(snapshot: DeviceCalendarSnapshot(calendars: Self.threeCalendarDevice(), defaultCalendarIdentifierForNewEvents: "work"))

        let snapshot = try store.discoverCalendars()

        XCTAssertEqual(snapshot.calendars.count, 3)
        XCTAssertEqual(snapshot.defaultCalendarIdentifierForNewEvents, "work")
        XCTAssertEqual(store.discoveryCount, 1)
        XCTAssertEqual(store.authorizationStatus, .fullAccess, "the fake still answers 3A's questions")
    }

    // MARK: - Persistence

    func testAMirroredCalendarRoundTripsThroughSQLiteIncludingAvailability() throws {
        let repository = try makeRepository()
        let plan = DeviceCalendarMirror.plan(
            devices: Self.threeCalendarDevice(),
            existing: [TestData.calendar()],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )
        var mirrored = Self.calendars(in: plan)
        mirrored[0].isUnavailable = true
        mirrored[0].unavailableSince = Self.later

        try repository.save(TestData.database(calendars: [TestData.calendar()] + mirrored, events: []))
        let loaded = try repository.load().calendars

        for original in mirrored {
            let stored = try XCTUnwrap(loaded.first { $0.id == original.id })
            XCTAssertEqual(stored, original, "\(original.name) did not survive the round trip")
        }
    }

    /// The other half: a reloaded mirror still compares equal to the device, so a relaunch does
    /// not produce a pass full of spurious updates.
    func testDiscoveryIsStillIdempotentAcrossASaveAndReload() throws {
        let repository = try makeRepository()
        let devices = Self.threeCalendarDevice()
        let first = DeviceCalendarMirror.plan(
            devices: devices,
            existing: [TestData.calendar()],
            now: Self.now,
            makeIdentifier: Self.deterministicIdentifiers()
        )

        try repository.save(TestData.database(calendars: [TestData.calendar()] + Self.calendars(in: first), events: []))
        let reloaded = try repository.load().calendars

        let second = DeviceCalendarMirror.plan(devices: devices, existing: reloaded, now: Self.later)
        XCTAssertTrue(second.isEmpty, "a relaunch must not rewrite every mirrored calendar")
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-02T12:00:00Z")
    private static let later = TestData.date("2026-09-03T12:00:00Z")

    private static func source(
        type: DeviceCalendarSourceType,
        title: String,
        identifier: String? = nil
    ) -> DeviceCalendarSource {
        DeviceCalendarSource(identifier: identifier ?? "source-\(type.rawValue)", title: title, type: type)
    }

    private static func deviceCalendar(
        identifier: String,
        title: String,
        type: DeviceCalendarType,
        source: DeviceCalendarSource? = nil,
        colorHex: String? = nil,
        isSubscribed: Bool = false,
        allowsContentModifications: Bool = true
    ) -> DeviceCalendar {
        DeviceCalendar(
            identifier: identifier,
            source: source ?? Self.source(type: .calDAV, title: "iCloud", identifier: "source-icloud"),
            title: title,
            type: type,
            colorHex: colorHex,
            isSubscribed: isSubscribed,
            allowsContentModifications: allowsContentModifications
        )
    }

    /// A device with three accounts' worth of shapes: a writable Exchange calendar, a writable
    /// iCloud one, and a subscribed holiday feed.
    private static func threeCalendarDevice() -> [DeviceCalendar] {
        [
            deviceCalendar(
                identifier: "work",
                title: "Work",
                type: .exchange,
                source: source(type: .exchange, title: "Work Exchange", identifier: "source-exchange"),
                colorHex: "#7B2D8E"
            ),
            deviceCalendar(
                identifier: "personal",
                title: "Personal",
                type: .calDAV,
                source: source(type: .mobileMe, title: "iCloud", identifier: "source-icloud"),
                colorHex: "#2B6CE8"
            ),
            deviceCalendar(
                identifier: "holidays",
                title: "US Holidays",
                type: .calDAV,
                source: source(type: .mobileMe, title: "iCloud", identifier: "source-icloud"),
                isSubscribed: true,
                allowsContentModifications: false
            )
        ]
    }

    private static func mirroredRow(
        providerCalendarID: String = "work",
        name: String = "Work"
    ) -> BetterCalendar {
        BetterCalendar(
            id: UUID(uuidString: "F0000000-0000-0000-0000-00000000000A")!,
            name: name,
            colorName: .betterBlue,
            isVisible: true,
            isDefault: false,
            sortOrder: 1,
            createdAt: now,
            updatedAt: now,
            provider: .apple,
            connectionMethod: .device,
            providerAccountID: "source-icloud",
            providerCalendarID: providerCalendarID,
            accountName: "iCloud"
        )
    }

    /// Sequential identifiers so a plan's rows can be named in an assertion, and so two runs of
    /// the same test produce the same plan.
    private static func deterministicIdentifiers() -> () -> UUID {
        var next = 0
        return {
            next += 1
            return UUID(uuidString: String(format: "E0000000-0000-0000-0000-%012X", next))!
        }
    }

    private static func calendars(in plan: DeviceCalendarMirror.Plan) -> [BetterCalendar] {
        plan.changes.compactMap {
            if case .upsertCalendar(let calendar) = $0 { calendar } else { nil }
        }
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DeviceCalendarDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
