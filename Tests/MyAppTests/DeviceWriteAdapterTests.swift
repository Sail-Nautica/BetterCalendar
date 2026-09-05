import XCTest
@testable import Better_Calendar

/// Spec 3D M2/M3: the write-back path end to end — planner, adapter, committer and the store
/// method that drives all three.
///
/// The two tests that carry this file are the crash-idempotency one and the field-level patch
/// one. They are the two places where getting it wrong is invisible: a duplicate device event
/// looks like the user double-tapped, and a stripped conference link looks like the organizer
/// removed it.
@MainActor
final class DeviceWriteAdapterTests: XCTestCase {

    // MARK: - Create (BC-EK-007)

    func testACreateOnADeviceCalendarReachesTheDeviceAndItsReceiptIsPersisted() async throws {
        let fixture = try await Self.connectedStore()

        _ = fixture.store.saveEvent(from: Self.draft(calendarID: fixture.deviceCalendarID))
        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.eventKit.writeLog.count, 1)
        XCTAssertNil(fixture.eventKit.writeLog[0].identifier, "a first write must be a create")
        XCTAssertEqual(fixture.eventKit.writeLog[0].event.title, "Dentist")

        let stored = try XCTUnwrap(fixture.store.events.first { $0.title == "Dentist" })
        XCTAssertEqual(stored.providerMetadata.providerObjectID, "fake-event-1")
        XCTAssertEqual(stored.providerMetadata.providerExternalID, "fake-external-1")
        XCTAssertNotNil(stored.providerMetadata.providerVersion)
        XCTAssertEqual(stored.providerMetadata.syncStatus, .synced)
        XCTAssertEqual(fixture.store.pendingMutations.first?.status, .applied)
    }

    /// Spec 3D.9/3.19: the local id is the one views, undo actions and the conflict index all
    /// reference. Re-keying it on receipt would invalidate every one of them.
    func testTheReceiptDoesNotRekeyTheLocalRow() async throws {
        let fixture = try await Self.connectedStore()
        _ = fixture.store.saveEvent(from: Self.draft(calendarID: fixture.deviceCalendarID))
        let idBefore = try XCTUnwrap(fixture.store.events.first { $0.title == "Dentist" }?.id)

        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.store.events.first { $0.title == "Dentist" }?.id, idBefore)
    }

    /// Spec 3.19, and the reason `.inFlight` is written before the device is touched: a create
    /// that succeeded but crashed before its receipt landed must be **adopted**, not issued
    /// again.
    ///
    /// Driven through the planner and adapter directly rather than through the store, because the
    /// state being reproduced — an outbox row left `.inFlight` by a process that died — is one no
    /// sequence of store calls can reach. Adding a test-only hook to the store to fake it would
    /// mean the test exercised the hook rather than the mechanism.
    func testACreateThatCrashedBeforeItsReceiptIsAdoptedRatherThanDuplicated() async throws {
        let fixture = Self.crashedCreateFixture()

        let planned = DeviceWritePlanner.plan(database: fixture.database, now: Self.now)
        XCTAssertEqual(planned.count, 1)
        guard case .create(_, let mightAlreadyExist) = try XCTUnwrap(planned.first).operation else {
            return XCTFail("expected a create")
        }
        XCTAssertTrue(mightAlreadyExist, "an in-flight row is one that may already have landed")

        let outcomes = await DeviceMutationAdapter(store: fixture.eventKit).perform(planned)

        guard case .adopted(let receipt) = try XCTUnwrap(outcomes.values.first) else {
            return XCTFail("expected the existing device event to be adopted, got \(String(describing: outcomes.values.first))")
        }
        XCTAssertEqual(receipt.identifier, "already-there")
        XCTAssertTrue(fixture.eventKit.writeLog.isEmpty, "adoption must not issue a second create")
        XCTAssertEqual(fixture.eventKit.deviceEvents.count, 1, "the device must still hold exactly one event")
    }

    /// Spec 2.15's "never merge silently", applied to a decision that creates data: a weak match
    /// creates rather than adopts, because a visible duplicate is a better failure than silently
    /// binding the user's row to somebody else's meeting.
    func testAWeakMatchCreatesRatherThanAdopting() async throws {
        let fixture = Self.crashedCreateFixture(deviceTitle: "Team lunch")

        let planned = DeviceWritePlanner.plan(database: fixture.database, now: Self.now)
        let outcomes = await DeviceMutationAdapter(store: fixture.eventKit).perform(planned)

        guard case .applied = try XCTUnwrap(outcomes.values.first) else {
            return XCTFail("a weak match must fall through to creating")
        }
        XCTAssertEqual(fixture.eventKit.writeLog.count, 1)
        XCTAssertEqual(fixture.eventKit.deviceEvents.count, 2, "the unrelated event is left alone and ours is created")
    }

    /// A create that has never been attempted does not pay for the search at all — spec 3.19's
    /// adoption is for the crash case, not for every create.
    func testAFreshCreateDoesNotSearchTheDevice() async throws {
        var fixture = Self.crashedCreateFixture()
        fixture.database.pendingMutations = fixture.database.pendingMutations.map { row in
            var pending = row
            pending.status = .pending
            return pending
        }

        let planned = DeviceWritePlanner.plan(database: fixture.database, now: Self.now)
        _ = await DeviceMutationAdapter(store: fixture.eventKit).perform(planned)

        XCTAssertEqual(fixture.eventKit.eventFetchCount, 0, "no adoption search for a create that was never issued")
        XCTAssertEqual(fixture.eventKit.writeLog.count, 1)
    }

    // MARK: - Update as a patch (BC-EK-017, spec 3.17/3D.4)

    /// The failure spec 3.17 exists to prevent, stated as a test: a title-only edit must not
    /// strip the video-call link off a meeting.
    func testATitleOnlyEditPatchesOnlyTheTitleAndLeavesEverythingElseIntact() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)

        Self.rename(mirrored, to: "Renamed", in: fixture.store)
        await fixture.store.drainDeviceWrites(now: Self.now)

        let write = try XCTUnwrap(fixture.eventKit.writeLog.first)
        XCTAssertEqual(write.fields, [.title], "the patch set comes from the journal, and the journal saw one field change")
        XCTAssertEqual(write.identifier, "ek-1", "an update addresses the event, it does not create a second one")

        // And the device event still carries everything Better Calendar never modelled.
        let onDevice = try XCTUnwrap(fixture.eventKit.deviceEvents.first)
        XCTAssertEqual(onDevice.title, "Renamed")
        XCTAssertEqual(onDevice.rawFields["conferenceURL"], "https://meet.example.com/abc")
        XCTAssertEqual(onDevice.location, "Room 4")
        XCTAssertEqual(onDevice.notes, "Bring the mocks")
    }

    func testAnEditToSeveralFieldsPatchesExactlyThoseFields() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)

        var draft = EventDraft(event: mirrored)
        draft.title = "Renamed"
        draft.location = "Room 9"
        _ = fixture.store.saveEvent(from: draft)
        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.eventKit.writeLog.first?.fields, [.title, .location])
    }

    // MARK: - Delete (BC-EK-009)

    func testDeletingAMirroredEventRemovesItFromTheDeviceAndMarksTheTombstoneSynced() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)

        fixture.store.deleteEvent(mirrored)
        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.eventKit.removeLog.map(\.identifier), ["ek-1"])
        XCTAssertTrue(fixture.eventKit.deviceEvents.isEmpty)
        XCTAssertNotNil(fixture.store.deletedEventTombstones.first?.deletionSyncedAt)
    }

    /// A delete for something the device no longer has is a success: the effect this mutation
    /// wanted already exists.
    func testDeletingAnEventAlreadyGoneFromTheDeviceSucceeds() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        fixture.eventKit.deviceEvents = []

        fixture.store.deleteEvent(mirrored)
        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.store.pendingMutations.first?.status, .applied)
    }

    // MARK: - Failures (spec 3.21/3D.6)

    func testAPermissionFailureParksTheRowAndLeavesTheLocalEditIntact() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        Self.rename(mirrored, to: "Renamed", in: fixture.store)
        fixture.eventKit.saveFailure = .permission

        await fixture.store.drainDeviceWrites(now: Self.now)

        let row = try XCTUnwrap(fixture.store.pendingMutations.first)
        XCTAssertEqual(row.status, .parked)
        XCTAssertEqual(row.failureClass, .permission)
        XCTAssertEqual(row.attemptCount, 0, "a permission failure must not spend a retry")
        XCTAssertEqual(fixture.store.events.first?.title, "Renamed", "the local edit is still the user's")
    }

    func testATransientFailureRetriesAndAPermanentOneDoesNot() async throws {
        for (failure, expected) in [(DeviceWriteFailure.transient, MutationStatus.inFlight), (.permanent, .failed)] {
            let fixture = try await mirroredEventStore()
            let mirrored = try XCTUnwrap(fixture.store.events.first)
            Self.rename(mirrored, to: "Renamed", in: fixture.store)
            fixture.eventKit.saveFailure = failure

            await fixture.store.drainDeviceWrites(now: Self.now)

            XCTAssertEqual(fixture.store.pendingMutations.first?.status, expected, "for \(failure)")
        }
    }

    /// Spec 3D.1's rule one level up: with no write access nothing is attempted, so nothing is
    /// claimed.
    func testNothingIsAttemptedOrClaimedWithoutWriteAccess() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        Self.rename(mirrored, to: "Renamed", in: fixture.store)
        fixture.eventKit.simulateExternalChange(to: .denied)

        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertTrue(fixture.eventKit.writeLog.isEmpty)
        XCTAssertEqual(fixture.store.pendingMutations.first?.status, .pending)
        XCTAssertEqual(fixture.store.pendingMutations.first?.attemptCount, 0)
    }

    // MARK: - Concurrency (spec 3.22/3D.7)

    /// A mismatch is a signal, not a verdict: two writes in the same second that touched
    /// different fields are a merge.
    func testAConcurrentEditToADifferentFieldMergesRatherThanConflicting() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        Self.rename(mirrored, to: "Renamed here", in: fixture.store)

        // Someone changed the *location* on the device since we last mirrored.
        fixture.eventKit.deviceEvents[0].location = "Room 12"
        fixture.eventKit.deviceEvents[0].lastModified = Self.now

        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.store.pendingMutations.first?.status, .applied)
        XCTAssertEqual(fixture.eventKit.deviceEvents.first?.title, "Renamed here")
        XCTAssertEqual(fixture.eventKit.deviceEvents.first?.location, "Room 12", "the device's own change survives the patch")
    }

    func testAConcurrentEditToTheSameFieldConflictsAndWritesNothing() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        Self.rename(mirrored, to: "Renamed here", in: fixture.store)

        fixture.eventKit.deviceEvents[0].title = "Renamed there"
        fixture.eventKit.deviceEvents[0].lastModified = Self.now

        await fixture.store.drainDeviceWrites(now: Self.now)

        let row = try XCTUnwrap(fixture.store.pendingMutations.first)
        XCTAssertEqual(row.status, .conflicted)
        XCTAssertEqual(row.failureClass, .conflict)
        XCTAssertTrue(fixture.eventKit.writeLog.isEmpty, "a conflict must write nothing to the device")
        XCTAssertEqual(fixture.eventKit.deviceEvents.first?.title, "Renamed there", "the device is untouched")
        // Spec 3.25: the local edit is not lost — it is still on the row and still in the outbox.
        XCTAssertEqual(fixture.store.events.first?.title, "Renamed here")
        XCTAssertNotNil(row.payload)
    }

    // MARK: - The drain as a whole

    func testASecondDrainWithNothingQueuedWritesNothing() async throws {
        let fixture = try await mirroredEventStore()
        let mirrored = try XCTUnwrap(fixture.store.events.first)
        Self.rename(mirrored, to: "Renamed", in: fixture.store)
        await fixture.store.drainDeviceWrites(now: Self.now)
        let writesAfterFirstDrain = fixture.eventKit.writeLog.count

        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertEqual(fixture.eventKit.writeLog.count, writesAfterFirstDrain)
    }

    /// A local calendar's mutations are not this path's business, and must not be swept into it.
    func testALocalCalendarsMutationsAreNeverSentToTheDevice() async throws {
        let fixture = try await Self.connectedStore(includeLocalCalendar: true)
        let localCalendarID = try XCTUnwrap(fixture.store.localCalendars.first?.id)

        _ = fixture.store.saveEvent(from: Self.draft(calendarID: localCalendarID, title: "Local only"))
        await fixture.store.drainDeviceWrites(now: Self.now)

        XCTAssertTrue(fixture.eventKit.writeLog.isEmpty)
    }

    // MARK: - Fixtures

    private static let now = TestData.date("2026-09-04T09:00:00Z")
    private static let eventStart = TestData.date("2026-09-15T13:00:00Z")

    private struct Fixture {
        var store: BetterCalendarStore
        var eventKit: FakeEventKitStore
        var deviceCalendarID: UUID
    }

    private static func draft(calendarID: UUID, title: String = "Dentist") -> EventDraft {
        var draft = EventDraft(calendarID: calendarID, startDate: eventStart)
        draft.title = title
        draft.endDate = eventStart.addingTimeInterval(3_600)
        return draft
    }

    /// A store with the device's calendars mirrored and nothing on them yet.
    private static func connectedStore(includeLocalCalendar: Bool = false) async throws -> Fixture {
        let eventKit = FakeEventKitStore(status: .fullAccess, snapshot: DeviceTestData.snapshot(), deviceEvents: [])
        let store = BetterCalendarStore(
            repository: StubCalendarRepository(loadResult: .success(TestData.database(calendars: includeLocalCalendar ? [TestData.calendar()] : [], events: []))),
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        await store.refreshDeviceCalendars(now: now)

        let deviceCalendarID = try XCTUnwrap(store.deviceCalendars.first { $0.providerCalendarID == "cal-personal" }?.id)
        return Fixture(store: store, eventKit: eventKit, deviceCalendarID: deviceCalendarID)
    }

    /// A store holding one mirrored event that carries a field Better Calendar does not model —
    /// which is the only way to prove the patch left it alone.
    private func mirroredEventStore() async throws -> Fixture {
        let eventKit = FakeEventKitStore(
            status: .fullAccess,
            snapshot: DeviceTestData.snapshot(),
            deviceEvents: [
                DeviceTestData.event(
                    identifier: "ek-1",
                    calendarIdentifier: "cal-personal",
                    title: "Design review",
                    notes: "Bring the mocks",
                    location: "Room 4",
                    startDate: Self.eventStart,
                    endDate: Self.eventStart.addingTimeInterval(3_600),
                    rawFields: ["conferenceURL": "https://meet.example.com/abc"]
                )
            ]
        )
        // A real SQLite repository, because the patch set comes from the **change journal** and
        // the stub repository has none — against the stub every edit would fall back to writing
        // every field, which is exactly the behaviour these tests exist to rule out.
        let repository = try makeRepository()
        // One local calendar and no events. A database with *no* calendars loads as `.seed`
        // (`SQLiteCalendarRepository.load`), and the sample data that comes with it would make
        // "the store holds exactly the mirrored event" false for reasons unrelated to write-back.
        try repository.save(TestData.database(calendars: [TestData.calendar()], events: []))
        let store = BetterCalendarStore(
            repository: repository,
            notificationScheduler: NoopNotificationScheduler(),
            eventKitStore: eventKit
        )
        await store.refreshDeviceCalendars(now: Self.now)
        XCTAssertEqual(store.events.count, 1, "the fixture should have mirrored exactly one event")

        let deviceCalendarID = try XCTUnwrap(store.deviceCalendars.first { $0.providerCalendarID == "cal-personal" }?.id)
        return Fixture(store: store, eventKit: eventKit, deviceCalendarID: deviceCalendarID)
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }

    /// An outbox row left `.inFlight` by a create that reached the device and then crashed
    /// before its receipt could be persisted — the local row still carries no provider
    /// identifier, and the device already holds the event.
    private static func crashedCreateFixture(deviceTitle: String = "Dentist") -> CrashFixture {
        let calendar = DeviceTestData.mirroredRow(for: DeviceTestData.personalCalendar, id: DeviceTestData.personalRowID)
        let event = TestData.event(
            id: UUID(),
            calendarID: calendar.id,
            title: "Dentist",
            startDate: eventStart,
            endDate: eventStart.addingTimeInterval(3_600)
        )
        let mutation = PendingMutation(
            id: UUID(),
            objectID: event.id,
            objectType: .event,
            operation: .create,
            createdAt: now.addingTimeInterval(-60),
            payload: event.encodedSnapshotJSON(),
            status: .inFlight
        )

        let eventKit = FakeEventKitStore(
            status: .fullAccess,
            snapshot: DeviceTestData.snapshot(),
            deviceEvents: [
                DeviceTestData.event(
                    identifier: "already-there",
                    calendarIdentifier: "cal-personal",
                    title: deviceTitle,
                    startDate: eventStart,
                    endDate: eventStart.addingTimeInterval(3_600)
                )
            ]
        )

        return CrashFixture(
            database: TestData.database(calendars: [calendar], events: [event], pendingMutations: [mutation]),
            eventKit: eventKit
        )
    }

    private struct CrashFixture {
        var database: LocalCalendarDatabase
        var eventKit: FakeEventKitStore
    }

    /// The edit path the editor uses — a draft over the existing event — so the change journal
    /// records exactly the field that changed, which is what the patch set is built from.
    private static func rename(_ event: CalendarEvent, to title: String, in store: BetterCalendarStore) {
        var draft = EventDraft(event: event)
        draft.title = title
        _ = store.saveEvent(from: draft)
    }
}
