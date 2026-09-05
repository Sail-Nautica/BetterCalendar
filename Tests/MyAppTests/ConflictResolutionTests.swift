import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3E.9's Conflicts block: the policy of spec 3.25, and the guarantee underneath it.
///
/// That guarantee is the reason this file exists at all. Every path here can be argued about —
/// whether a title conflict should really resolve itself, whether "newest" is the right
/// tie-breaker — but none of them may lose a version the user typed. The `EventVersion`
/// assertions are the ones that would matter at three in the morning.
@MainActor
final class ConflictResolutionTests: XCTestCase {

    // MARK: - Classification (spec 3.25)

    func testOverlappingLowRiskFieldsResolveToTheNewestWrite() {
        let localIsNewer = ConflictResolver.resolve(
            operation: .update,
            localFields: [.title],
            deviceFields: [.title],
            localEditedAt: Self.later,
            deviceModifiedAt: Self.now
        )
        XCTAssertEqual(localIsNewer, .keepLocal)

        let deviceIsNewer = ConflictResolver.resolve(
            operation: .update,
            localFields: [.title],
            deviceFields: [.title],
            localEditedAt: Self.now,
            deviceModifiedAt: Self.later
        )
        XCTAssertEqual(deviceIsNewer, .keepDevice)
    }

    /// The line is drawn at reversibility. A title resolved the wrong way is retyped in seconds;
    /// a time resolved the wrong way sends somebody to a meeting that moved.
    func testTimeRecurrenceAndAvailabilityConflictsAreNeverResolvedAutomatically() {
        let cases: [(Set<DeviceEventField>, ConflictResolver.Resolution.Reason)] = [
            ([.startDate], .time),
            ([.endDate], .time),
            ([.isAllDay], .time),
            ([.timeZone], .time),
            ([.recurrence], .recurrence),
            ([.availability], .availability)
        ]

        for (fields, expected) in cases {
            let resolution = ConflictResolver.resolve(
                operation: .update,
                localFields: fields,
                deviceFields: fields,
                localEditedAt: Self.later,
                deviceModifiedAt: Self.now
            )
            XCTAssertEqual(resolution, .askTheUser(reason: expected), "for \(fields)")
        }
    }

    /// One high-risk field in the overlap is enough, however many low-risk ones travel with it.
    func testAMixedOverlapAsksTheUser() {
        let resolution = ConflictResolver.resolve(
            operation: .update,
            localFields: [.title, .startDate],
            deviceFields: [.title, .startDate],
            localEditedAt: Self.later,
            deviceModifiedAt: Self.now
        )

        XCTAssertEqual(resolution, .askTheUser(reason: .time))
    }

    /// Spec 3.25: deleting something somebody else just changed is where guessing wrong is least
    /// recoverable — whatever they changed.
    func testALocalDeleteAgainstAnExternalEditAlwaysAsksTheUser() {
        let resolution = ConflictResolver.resolve(
            operation: .delete,
            localFields: [.title],
            deviceFields: [.title],
            localEditedAt: Self.later,
            deviceModifiedAt: Self.now
        )

        XCTAssertEqual(resolution, .askTheUser(reason: .deletion))
    }

    func testAnUnknownBasisAsksRatherThanGuesses() {
        // No local timestamp to order against.
        XCTAssertEqual(
            ConflictResolver.resolve(operation: .update, localFields: [.title], deviceFields: [.title], localEditedAt: nil, deviceModifiedAt: Self.now),
            .askTheUser(reason: .unknown)
        )
        // Inputs that do not add up: Phase 3D would have merged a disjoint pair, so reaching the
        // resolver with one means the classification disagrees with what produced the conflict.
        XCTAssertEqual(
            ConflictResolver.resolve(operation: .update, localFields: [.title], deviceFields: [.location], localEditedAt: Self.later, deviceModifiedAt: Self.now),
            .askTheUser(reason: .unknown)
        )
    }

    // MARK: - Automatic resolution end to end

    /// The loser is written to history *before* it is dropped. Spec 3.25's "never discard" has no
    /// exception for a decision the engine made on the user's behalf.
    func testWhenTheDeviceWinsTheLosingLocalEditIsPreservedInHistory() async throws {
        let fixture = try await Self.conflictedStore(localEditedAt: Self.now, deviceModifiedAt: Self.later)

        let result = await Self.drain(fixture)

        XCTAssertEqual(result.summary.superseded, 1)
        XCTAssertEqual(result.transaction.eventVersions.count, 1, "the losing version must be snapshotted")
        let snapshot = try XCTUnwrap(result.transaction.eventVersions.first?.snapshotJSON)
        let preserved = try XCTUnwrap(CalendarEvent(snapshotJSON: snapshot))
        XCTAssertEqual(preserved.title, "Mine", "the version preserved is the one the user typed")
        XCTAssertEqual(result.transaction.journalEntries.first?.source, .reconciliation, "the engine did this, not the user")

        // And the mutation is retired rather than left in the queue forever.
        let after = fixture.database.applying(result.transaction)
        XCTAssertEqual(after.pendingMutations.first?.status, .applied)
    }

    func testWhenTheLocalEditIsNewerItIsWrittenToTheDevice() async throws {
        let fixture = try await Self.conflictedStore(localEditedAt: Self.later, deviceModifiedAt: Self.now)

        let result = await Self.drain(fixture)

        XCTAssertEqual(result.summary.applied, 1)
        XCTAssertEqual(fixture.eventKit.deviceEvents.first?.title, "Mine")
        XCTAssertTrue(result.transaction.eventVersions.isEmpty, "the device's own history is not ours to write")
    }

    // MARK: - Asking the user (spec 3E.4)

    func testATimeConflictWaitsForTheUserAndWritesNothing() async throws {
        let fixture = try await Self.conflictedStore(
            localEditedAt: Self.later,
            deviceModifiedAt: Self.now,
            localChange: { $0.startDate = $0.startDate.addingTimeInterval(3_600) },
            deviceChange: { $0.startDate = $0.startDate.addingTimeInterval(7_200) },
            localFields: [.startDate]
        )

        let result = await Self.drain(fixture)

        XCTAssertEqual(result.summary.conflicted, 1)
        XCTAssertTrue(fixture.eventKit.writeLog.isEmpty, "a conflict awaiting an answer must write nothing")
        let after = fixture.database.applying(result.transaction)
        XCTAssertEqual(after.pendingMutations.first?.status, .conflicted)
    }

    // MARK: - The user's two answers

    func testKeepMineRebasesAndRequeuesSoTheNextDrainWritesIt() async throws {
        let fixture = try await Self.storeWithConflictedRow()
        let conflicted = try XCTUnwrap(fixture.store.outboxRowsNeedingAttention.first)
        XCTAssertEqual(conflicted.status, .conflicted)

        XCTAssertTrue(fixture.store.resolveConflictKeepingLocalEdit(conflicted, now: Self.later))

        let requeued = try XCTUnwrap(fixture.store.pendingMutations.first)
        XCTAssertEqual(requeued.status, .pending)
        XCTAssertNil(requeued.failureClass)
        XCTAssertEqual(
            requeued.baseProviderVersion,
            fixture.store.events.first?.providerMetadata.providerVersion,
            "re-based on what the device holds now, or the next drain conflicts again and the button does nothing"
        )
    }

    /// "Keep theirs" is the closest thing to a discard in the whole engine, and it still writes
    /// the version it is setting aside into history first.
    func testKeepTheirsRetiresTheMutationAndPreservesTheLocalEditFirst() async throws {
        let fixture = try await Self.storeWithConflictedRow()
        let conflicted = try XCTUnwrap(fixture.store.outboxRowsNeedingAttention.first)

        XCTAssertTrue(fixture.store.resolveConflictKeepingDeviceVersion(conflicted, now: Self.later))

        XCTAssertTrue(fixture.store.outboxRowsNeedingAttention.isEmpty, "the queue stops carrying an abandoned edit")
        XCTAssertEqual(fixture.store.pendingMutations.first?.status, .applied)

        // The losing version is durable, not merely gone. Read straight out of `event_versions`
        // rather than through the journal-entry lookup, because the entry this resolution wrote
        // is a *new* one — keying the assertion on the mutation's own entry would prove nothing
        // about what was actually stored.
        let eventID = try XCTUnwrap(fixture.store.events.first?.id)
        let snapshots = try fixture.readDatabase { db in
            try String.fetchAll(db, sql: "SELECT snapshot_json FROM event_versions WHERE event_id = ?", arguments: [eventID.uuidString])
        }
        XCTAssertEqual(snapshots.count, 1, "the abandoned edit must still be recoverable from history")
        XCTAssertEqual(CalendarEvent(snapshotJSON: try XCTUnwrap(snapshots.first))?.title, "Mine")
    }

    func testResolvingSomethingThatIsNotConflictedDoesNothing() async throws {
        let fixture = try await Self.storeWithConflictedRow()
        let conflicted = try XCTUnwrap(fixture.store.outboxRowsNeedingAttention.first)
        XCTAssertTrue(fixture.store.resolveConflictKeepingDeviceVersion(conflicted, now: Self.later))

        // Already resolved: a second answer is a no-op rather than a second history entry.
        XCTAssertFalse(fixture.store.resolveConflictKeepingDeviceVersion(conflicted, now: Self.later))
        XCTAssertFalse(fixture.store.resolveConflictKeepingLocalEdit(conflicted, now: Self.later))
    }

    /// Spec 3.25: the user sees the device's version while their edit is pending, and is told so.
    func testAConflictedEventReportsThatALocalEditIsPending() async throws {
        let fixture = try await Self.storeWithConflictedRow()
        let event = try XCTUnwrap(fixture.store.events.first)

        XCTAssertEqual(fixture.store.pendingWriteStatus(for: event), .conflicted)
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-04T09:00:00Z")
    private static let later = TestData.date("2026-09-04T10:00:00Z")
    private static let eventStart = TestData.date("2026-09-15T13:00:00Z")

    private struct Fixture {
        var database: LocalCalendarDatabase
        var eventKit: FakeEventKitStore
        var plan: DeviceWritePlanner.Plan
    }

    private static func drain(_ fixture: Fixture) async -> DeviceWriteCommitter.Result {
        let outcomes = await DeviceMutationAdapter(store: fixture.eventKit).perform(fixture.plan.writes)
        return DeviceWriteCommitter.commit(fixture.plan, outcomes: outcomes, in: fixture.database, now: now)
    }

    /// A local edit and a device edit to the same field, staged so the adapter sees a real
    /// mismatch and has a real base to measure from.
    private static func conflictedStore(
        localEditedAt: Date,
        deviceModifiedAt: Date,
        localChange: (inout CalendarEvent) -> Void = { $0.title = "Mine" },
        deviceChange: (inout DeviceEvent) -> Void = { $0.title = "Theirs" },
        localFields: Set<DeviceEventField> = [.title]
    ) async throws -> Fixture {
        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)

        var base = TestData.event(id: UUID(), calendarID: calendar.id, title: "Original", startDate: eventStart, endDate: eventStart.addingTimeInterval(3_600))
        base.providerMetadata = ProviderMetadata(provider: .apple, providerObjectID: "ek-1", providerVersion: "0", syncStatus: .synced)

        var local = base
        localChange(&local)

        var device = DeviceTestData.event(
            identifier: "ek-1",
            externalIdentifier: "ext-1",
            title: "Original",
            startDate: eventStart,
            endDate: eventStart.addingTimeInterval(3_600),
            lastModified: deviceModifiedAt
        )
        deviceChange(&device)

        let journalEntryID = UUID()
        let mutation = PendingMutation(
            id: UUID(),
            objectID: local.id,
            objectType: .event,
            operation: .update,
            createdAt: localEditedAt,
            payload: local.encodedSnapshotJSON(),
            status: .pending,
            changeJournalEntryID: journalEntryID,
            baseProviderVersion: "0"
        )

        let database = TestData.database(calendars: [calendar], events: [local], pendingMutations: [mutation])
        let eventKit = FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot(), deviceEvents: [device])

        // The journal says what the user touched; `EventVersion` says what they touched it from.
        let plan = DeviceWritePlanner.plan(
            database: database,
            fieldDiffs: [journalEntryID: fieldDiffJSON(for: localFields)],
            baseSnapshots: [journalEntryID: base.encodedSnapshotJSON() ?? "{}"],
            now: now
        )
        return Fixture(database: database, eventKit: eventKit, plan: plan)
    }

    /// A `FieldDiff`-shaped payload naming exactly these fields, which is all the planner reads.
    private static func fieldDiffJSON(for fields: Set<DeviceEventField>) -> String {
        let keys = fields.map { field -> String in
            switch field {
            case .title: "title"
            case .notes: "notes"
            case .location: "location"
            case .url: "urlString"
            case .startDate: "startDate"
            case .endDate: "endDate"
            case .isAllDay: "timeType"
            case .timeZone: "timeZoneIdentifier"
            case .availability: "availability"
            case .alarms: "reminders"
            case .recurrence: "recurrence"
            }
        }
        let body = keys.map { "\"\($0)\":{\"after\":\"x\"}" }.joined(separator: ",")
        return "{\(body)}"
    }

    private struct StoreFixture {
        var store: BetterCalendarStore
        var repository: SQLiteCalendarRepository
        var databaseURL: URL

        /// Reads the tables the domain snapshot deliberately does not carry — `event_versions`
        /// here, which is durable history rather than anything the UI shows.
        func readDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).read(body)
        }
    }

    /// A live store holding one conflicted row, for the resolution actions.
    private static func storeWithConflictedRow() async throws -> StoreFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)

        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)
        var event = TestData.event(id: UUID(), calendarID: calendar.id, title: "Theirs", startDate: eventStart, endDate: eventStart.addingTimeInterval(3_600))
        event.providerMetadata = ProviderMetadata(provider: .apple, providerObjectID: "ek-1", providerVersion: "900", syncStatus: .synced)

        var mine = event
        mine.title = "Mine"
        let mutation = PendingMutation(
            id: UUID(),
            objectID: event.id,
            objectType: .event,
            operation: .update,
            createdAt: now,
            payload: mine.encodedSnapshotJSON(),
            status: .conflicted,
            baseProviderVersion: "0",
            failureClass: .conflict
        )

        try repository.save(TestData.database(calendars: [calendar], events: [event], pendingMutations: [mutation]))
        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot())
        )
        return StoreFixture(store: store, repository: repository, databaseURL: databaseURL)
    }
}
