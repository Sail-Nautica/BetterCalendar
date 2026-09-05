import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3F.9: the duplicate-connection rule.
///
/// Most of this is machinery for a problem Phase 5 will create, and the tests are what make it
/// worth shipping now — a detector nothing exercises is a design nobody has checked. The one part
/// that is not hypothetical is the ICS-over-mirror overlap, which is a real duplicate today.
@MainActor
final class DuplicateConnectionTests: XCTestCase {

    // MARK: - Identity (spec 3F.1)

    func testTwoCalendarsFromTheSameAccountAndNameShareAnIdentity() {
        let first = Self.calendar(name: "Work", accountName: "work@example.com")
        let second = Self.calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "other-transport")

        XCTAssertEqual(
            DuplicateConnectionDetector.CalendarConnectionIdentity(first),
            DuplicateConnectionDetector.CalendarConnectionIdentity(second)
        )
    }

    /// Case and whitespace fold; nothing else does. Guessing that "Work" and "Work Calendar" are
    /// one calendar is how a calendar the user still has gets hidden.
    func testIdentityFoldsCaseAndWhitespaceAndNothingElse() {
        let base = Self.calendar(name: "Work", accountName: "work@example.com")

        XCTAssertEqual(
            DuplicateConnectionDetector.CalendarConnectionIdentity(base),
            DuplicateConnectionDetector.CalendarConnectionIdentity(Self.calendar(name: "  work ", accountName: "Work@Example.com"))
        )
        XCTAssertNotEqual(
            DuplicateConnectionDetector.CalendarConnectionIdentity(base),
            DuplicateConnectionDetector.CalendarConnectionIdentity(Self.calendar(name: "Work Calendar", accountName: "work@example.com"))
        )
    }

    /// The provider is part of the key, which is what makes ADR 0007's narrow CalDAV attribution
    /// load-bearing: a calendar wrongly called `.google` becomes a false match here.
    func testTheProviderIsPartOfTheIdentity() {
        var google = Self.calendar(name: "Work", accountName: "work@example.com")
        google.provider = .google
        var exchange = Self.calendar(name: "Work", accountName: "work@example.com")
        exchange.provider = .exchange

        XCTAssertNotEqual(
            DuplicateConnectionDetector.CalendarConnectionIdentity(google),
            DuplicateConnectionDetector.CalendarConnectionIdentity(exchange)
        )
    }

    func testALocalCalendarHasNoConnectionIdentity() {
        XCTAssertNil(DuplicateConnectionDetector.CalendarConnectionIdentity(TestData.calendar()))
    }

    // MARK: - Detection (spec 3F.2)

    func testTwoCalendarsSharingAnIdentityAreDetected() {
        let groups = DuplicateConnectionDetector.duplicateGroups(among: [
            Self.calendar(name: "Work", accountName: "work@example.com"),
            Self.calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "other-transport"),
            Self.calendar(name: "Personal", accountName: "me@example.com")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.calendars.count, 2)
        XCTAssertFalse(groups.first?.isResolved ?? true)
    }

    func testASingleCalendarIsNotAGroup() {
        let groups = DuplicateConnectionDetector.duplicateGroups(among: [
            Self.calendar(name: "Work", accountName: "work@example.com")
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    /// The false-positive case that matters: two people's "Work" calendars on genuinely different
    /// accounts are two calendars, not one seen twice.
    func testTheSameNameOnDifferentAccountsIsNotADuplicate() {
        let groups = DuplicateConnectionDetector.duplicateGroups(among: [
            Self.calendar(name: "Work", accountName: "me@example.com"),
            Self.calendar(name: "Work", accountName: "someone-else@example.com")
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    func testAResolvedGroupIsNotOfferedAgain() {
        var kept = Self.calendar(name: "Work", accountName: "work@example.com")
        kept.duplicateConnectionResolvedAt = Self.now
        var superseded = Self.calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "other")
        superseded.isSupersededByDuplicateConnection = true
        superseded.duplicateConnectionResolvedAt = Self.now

        XCTAssertTrue(DuplicateConnectionDetector.duplicateGroups(among: [kept, superseded]).isEmpty)
        // But it is still listable, so the choice can be changed.
        XCTAssertEqual(DuplicateConnectionDetector.duplicateGroups(among: [kept, superseded], includingResolved: true).count, 1)
    }

    /// Spec 3F.2's account level, and what `sources()` was reserved for: the same account added
    /// twice under different source identifiers.
    func testTheSameAccountConfiguredTwiceIsDetected() {
        let duplicates = DuplicateConnectionDetector.duplicateAccounts(among: [
            DeviceCalendarSource(identifier: "src-google", title: "work@gmail.com", type: .calDAV),
            DeviceCalendarSource(identifier: "src-caldav", title: "Work@Gmail.com", type: .calDAV),
            DeviceCalendarSource(identifier: "src-icloud", title: "iCloud", type: .mobileMe)
        ])

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.sourceIdentifiers, ["src-caldav", "src-google"])
    }

    func testSourcesReachTheDetectorThroughTheSeam() throws {
        let eventKit = FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot())
        // An account with no calendars on it — which `calendars(for:)` cannot report, and which
        // is precisely what `sources()` exists to make visible.
        eventKit.extraSources = [DeviceCalendarSource(identifier: "src-empty", title: "Work Exchange", type: .exchange)]

        let sources = try eventKit.sources()

        XCTAssertEqual(DuplicateConnectionDetector.duplicateAccounts(among: sources).first?.title, "Work Exchange")
    }

    // MARK: - Honouring the choice (spec 3F.3)

    func testResolvingSupersedesEveryOtherRowAndDeletesNothing() async throws {
        let fixture = try await Self.duplicatedStore()
        let group = try XCTUnwrap(fixture.store.unresolvedDuplicateConnections.first)
        let keptID = try XCTUnwrap(group.calendars.first?.id)

        XCTAssertTrue(fixture.store.resolveDuplicateConnection(group, keeping: keptID, now: Self.now))

        let rows = fixture.store.allDeviceCalendarRows.filter { $0.name == "Work" }
        XCTAssertEqual(rows.count, 2, "nothing is deleted — superseding is a choice, and reversible")
        XCTAssertEqual(rows.filter { !$0.isSupersededByDuplicateConnection }.map(\.id), [keptID])
        XCTAssertTrue(rows.allSatisfy { $0.duplicateConnectionResolvedAt != nil })
    }

    func testASupersededCalendarIsNotFetchedAndItsEventsAreRetained() async throws {
        let fixture = try await Self.duplicatedStoreWithEventOnEachSide()
        let group = try XCTUnwrap(fixture.store.unresolvedDuplicateConnections.first)
        let losing = try XCTUnwrap(group.calendars.last)
        let keeping = try XCTUnwrap(group.calendars.first)

        // An event already mirrored onto the row that is about to lose.
        let stranded = try XCTUnwrap(fixture.store.events.first { $0.calendarID == losing.id })

        fixture.store.resolveDuplicateConnection(group, keeping: keeping.id, now: Self.now)

        XCTAssertFalse(
            DeviceEventMirror.fetchableCalendars(from: fixture.store.calendars).contains { $0.id == losing.id },
            "a superseded connection contributes no events"
        )
        XCTAssertTrue(
            fixture.store.events.contains { $0.id == stranded.id },
            "and loses none — retained and hidden, exactly as spec 3.26 requires of any unfetched calendar"
        )
    }

    func testASupersededCalendarIsRefusedAsAWriteDestinationAtTheModelLayer() async throws {
        let fixture = try await Self.duplicatedStore()
        let group = try XCTUnwrap(fixture.store.unresolvedDuplicateConnections.first)
        let losing = try XCTUnwrap(group.calendars.last)
        fixture.store.resolveDuplicateConnection(group, keeping: try XCTUnwrap(group.calendars.first?.id), now: Self.now)

        let outcome = EventMutationUseCases.createEvent(
            TestData.event(id: UUID(), calendarID: losing.id, title: "Should never exist"),
            in: EventMutationUseCases.Context(database: Self.database(of: fixture.store), now: Self.now)
        )

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .supersededConnection)
    }

    func testASupersededCalendarDoesNotAppearAsASeparateCalendar() async throws {
        let fixture = try await Self.duplicatedStore()
        let group = try XCTUnwrap(fixture.store.unresolvedDuplicateConnections.first)
        let losing = try XCTUnwrap(group.calendars.last)
        fixture.store.resolveDuplicateConnection(group, keeping: try XCTUnwrap(group.calendars.first?.id), now: Self.now)

        XCTAssertFalse(fixture.store.deviceCalendars.contains { $0.id == losing.id })
        XCTAssertFalse(fixture.store.writableDestinationCalendars.contains { $0.id == losing.id })
        XCTAssertTrue(fixture.store.allDeviceCalendarRows.contains { $0.id == losing.id }, "still findable where the choice is changed")
    }

    func testTheChoiceCanBeChanged() async throws {
        let fixture = try await Self.duplicatedStore()
        let group = try XCTUnwrap(fixture.store.unresolvedDuplicateConnections.first)
        let first = try XCTUnwrap(group.calendars.first)
        let second = try XCTUnwrap(group.calendars.last)

        fixture.store.resolveDuplicateConnection(group, keeping: first.id, now: Self.now)
        let resolved = try XCTUnwrap(fixture.store.allDuplicateConnections.first)
        fixture.store.resolveDuplicateConnection(resolved, keeping: second.id, now: Self.now)

        XCTAssertEqual(fixture.store.deviceCalendars.filter { $0.name == "Work" }.map(\.id), [second.id])
        XCTAssertTrue(fixture.store.writableDestinationCalendars.contains { $0.id == second.id })
    }

    // MARK: - The Phase 5 migration path (spec 3F.5)

    /// Delete-and-re-import would lose every local id, and with it every undo action, conflict
    /// index entry, and `EventVersion` reference. A move keeps them.
    func testAnUnmatchedEventMovesRatherThanBeingRecreated() {
        let losing = Self.calendar(name: "Work", accountName: "work@example.com")
        let winning = Self.calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "direct")
        var only = TestData.event(id: UUID(), calendarID: losing.id, title: "Only here")
        only.providerMetadata = ProviderMetadata(provider: .google, providerObjectID: "old-transport-id", syncStatus: .synced)

        let plan = ConnectionMethodMigrationPlanner.plan(losing: losing, winning: winning, events: [only], now: Self.now)

        XCTAssertEqual(plan.summary.moved, 1)
        XCTAssertEqual(plan.summary.merged, 0)
        guard case .upsertEvent(let moved) = plan.transaction.entityChanges.first else {
            return XCTFail("expected the event to be moved, not recreated")
        }
        XCTAssertEqual(moved.id, only.id, "the local id survives — that is the whole point")
        XCTAssertEqual(moved.calendarID, winning.id)
        XCTAssertNil(moved.providerMetadata.providerObjectID, "the old transport's identity means nothing to the new one")
        XCTAssertEqual(moved.providerMetadata.syncStatus, .pendingCreate)
    }

    func testAnEventOnBothSidesIsMergedOntoTheWinnersRow() {
        let losing = Self.calendar(name: "Work", accountName: "work@example.com")
        let winning = Self.calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "direct")

        var fromDevice = TestData.event(id: UUID(), calendarID: losing.id, title: "Standup")
        fromDevice.providerMetadata = ProviderMetadata(provider: .google, providerObjectID: "ek-1", syncStatus: .synced, providerExternalID: "shared-uid")
        var fromDirect = TestData.event(id: UUID(), calendarID: winning.id, title: "Standup")
        fromDirect.providerMetadata = ProviderMetadata(provider: .google, providerObjectID: "shared-uid", syncStatus: .synced)

        let plan = ConnectionMethodMigrationPlanner.plan(losing: losing, winning: winning, events: [fromDevice, fromDirect], now: Self.now)

        XCTAssertEqual(plan.summary.merged, 1)
        XCTAssertEqual(plan.transaction.entityChanges, [.deleteEvent(fromDevice.id)])
        XCTAssertEqual(plan.transaction.tombstones.count, 1, "the retired row is recoverable, not merely gone")
        XCTAssertEqual(plan.transaction.journalEntries.first?.source, .migration, "the engine moved this, not the user")
    }

    // MARK: - Cross-provider duplicates (spec 3.30 / 3F.6)

    /// The case that is real today, with no second transport at all: an ICS file re-imported over
    /// events already mirrored from the device.
    func testAnICSReimportOverMirroredEventsIsDetectedAsADuplicate() {
        var mirrored = TestData.event(id: UUID(), title: "Standup")
        mirrored.providerMetadata = ProviderMetadata(
            provider: .apple,
            // What EventKit calls it…
            providerObjectID: "ek-local-identifier",
            syncStatus: .synced,
            // …and the iCalendar UID underneath, which is what an ICS file carries.
            providerExternalID: "uid@example.com"
        )

        var imported = TestData.event(id: UUID(), title: "Standup")
        imported.providerMetadata = ProviderMetadata(provider: .betterCalendar, providerObjectID: "uid@example.com", syncStatus: .synced)

        let candidates = DuplicateDetector.candidates(for: imported, among: [mirrored])

        XCTAssertEqual(candidates.first?.matchedEventID, mirrored.id)
        XCTAssertEqual(candidates.first?.reason, .sameEventDifferentTransport)
        XCTAssertEqual(candidates.first?.confidence, 1.0)
    }

    /// And end to end, through the import path the user actually uses.
    func testCommitImportSkipsAnEventAlreadyMirroredFromTheDevice() async throws {
        let fixture = try await Self.storeWithMirroredEvent()
        let countBefore = fixture.store.events.count

        var imported = TestData.event(id: UUID(), calendarID: try XCTUnwrap(fixture.store.deviceCalendars.first?.id), title: "Standup")
        imported.providerMetadata = ProviderMetadata(provider: .betterCalendar, providerObjectID: "uid@example.com", syncStatus: .synced)
        let summary = fixture.store.commitImport(
            ImportSummary(importedCount: 1, skippedCount: 0, failedCount: 0, events: [imported])
        )

        XCTAssertEqual(fixture.store.events.count, countBefore, "the mirrored event must not be imported a second time")
        XCTAssertEqual(summary.skippedCount, 1)
    }

    func testADifferentEventWithASimilarTitleIsNotADuplicate() {
        var mirrored = TestData.event(id: UUID(), title: "Standup")
        mirrored.providerMetadata = ProviderMetadata(provider: .apple, providerObjectID: "ek-1", syncStatus: .synced, providerExternalID: "uid-a@example.com")

        var other = TestData.event(id: UUID(), title: "Standup", startDate: TestData.date("2026-10-02T14:00:00Z"), endDate: TestData.date("2026-10-02T15:00:00Z"))
        other.providerMetadata = ProviderMetadata(provider: .betterCalendar, providerObjectID: "uid-b@example.com", syncStatus: .synced)

        XCTAssertTrue(DuplicateDetector.candidates(for: other, among: [mirrored]).isEmpty)
    }

    // MARK: - Persistence (migration v024)

    func testTheDuplicateConnectionFieldsRoundTrip() throws {
        let repository = try makeRepository()
        var superseded = Self.calendar(name: "Work", accountName: "work@example.com")
        superseded.isSupersededByDuplicateConnection = true
        superseded.duplicateConnectionResolvedAt = Self.now

        try repository.save(TestData.database(calendars: [superseded], events: []))
        let stored = try XCTUnwrap(try repository.load().calendars.first)

        XCTAssertTrue(stored.isSupersededByDuplicateConnection)
        XCTAssertEqual(stored.duplicateConnectionResolvedAt, Self.now)
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-05T09:00:00Z")

    private static func calendar(
        name: String,
        accountName: String,
        providerCalendarID: String = "cal-1",
        id: UUID = UUID()
    ) -> BetterCalendar {
        BetterCalendar(
            id: id,
            name: name,
            colorName: .betterBlue,
            isVisible: true,
            isDefault: false,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            provider: .google,
            connectionMethod: .device,
            providerAccountID: "src-\(providerCalendarID)",
            providerCalendarID: providerCalendarID,
            accountName: accountName
        )
    }

    private struct Fixture {
        var store: BetterCalendarStore
    }

    /// A store holding the degenerate case spec 3F.4 describes: one account configured twice, so
    /// the same calendar arrives under two source identifiers.
    private static func duplicatedStore(events: [CalendarEvent] = []) async throws -> Fixture {
        let first = calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "cal-a")
        var second = calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "cal-b")
        second.sortOrder = 1

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
        try repository.save(TestData.database(calendars: [first, second], events: events))

        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot())
        )
        return Fixture(store: store)
    }

    /// The store's own snapshot, assembled from what it already publishes — rather than a
    /// test-only accessor on the store, which would be production API existing for one assertion.
    private static func database(of store: BetterCalendarStore) -> LocalCalendarDatabase {
        LocalCalendarDatabase(
            schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
            calendars: store.calendars,
            events: store.events,
            pendingMutations: store.pendingMutations,
            deletedEventTombstones: store.deletedEventTombstones,
            settings: store.settings,
            recurrenceExceptions: store.recurrenceExceptions
        )
    }

    /// The degenerate case, with one mirrored event already sitting on each of the two rows.
    private static func duplicatedStoreWithEventOnEachSide() async throws -> Fixture {
        let first = calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "cal-a")
        var second = calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "cal-b")
        second.sortOrder = 1

        var onSecond = TestData.event(id: UUID(), calendarID: second.id, title: "On the losing connection")
        onSecond.providerMetadata = ProviderMetadata(provider: .apple, providerObjectID: "ek-stranded", syncStatus: .synced)

        return try await store(calendars: [first, second], events: [onSecond])
    }

    private static func storeWithMirroredEvent() async throws -> Fixture {
        let first = calendar(name: "Work", accountName: "work@example.com", providerCalendarID: "cal-a")
        var mirrored = TestData.event(id: UUID(), calendarID: first.id, title: "Standup")
        mirrored.providerMetadata = ProviderMetadata(
            provider: .apple,
            providerObjectID: "ek-1",
            syncStatus: .synced,
            providerExternalID: "uid@example.com"
        )
        return try await store(calendars: [first], events: [mirrored])
    }

    private static func store(calendars: [BetterCalendar], events: [CalendarEvent]) async throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
        try repository.save(TestData.database(calendars: calendars, events: events))

        return Fixture(store: BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot())
        ))
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
