import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 3C M1: the schema and model half of Phase 3C — migration `v020`, the `event_attendees`
/// table, the provider columns on `events`, and the model-layer refusal that the
/// `has_unrepresentable_recurrence` flag exists to make possible.
///
/// `MigrationTests` proves `v020` applies to fixture databases from every released version. This
/// proves the columns it adds actually carry their values through a save/load round trip, which
/// is a separate claim: a migration can succeed and the repository still drop the field.
final class DeviceEventPersistenceTests: XCTestCase {

    // MARK: - Round trip (spec 3C.11 "Persistence")

    func testAMirroredEventRoundTripsWithProviderIdentityRawPayloadStatusAndAttendees() throws {
        let repository = try makeRepository()
        let calendar = Self.deviceCalendar()
        let event = Self.mirroredEvent(calendarID: calendar.id)

        try repository.save(TestData.database(calendars: [calendar], events: [event]))
        let stored = try XCTUnwrap(try repository.load().events.first)

        XCTAssertEqual(stored.providerMetadata.providerObjectID, "ek-event-1")
        XCTAssertEqual(stored.providerMetadata.providerExternalID, "ext-1")
        XCTAssertEqual(stored.providerMetadata.providerVersion, "801000000.000")
        XCTAssertEqual(stored.providerMetadata.providerRawFields, #"{"conferenceURL":"https://meet.example.com/abc"}"#)
        XCTAssertEqual(stored.providerMetadata.status, .tentative)
        XCTAssertTrue(stored.providerMetadata.hasUnrepresentableRecurrence)
        XCTAssertEqual(stored.attendees.count, 2)
        XCTAssertEqual(stored.organizer?.name, "Dana")
        XCTAssertEqual(stored.currentUserAttendee?.participationStatus, .declined)
        XCTAssertEqual(stored.attendees.map(\.sortOrder), [0, 1])
    }

    /// `events.status` has been written as the literal `'confirmed'` on every row since `v001`.
    /// Phase 3C is where it stops being hardcoded — and a local event still reads `.confirmed`,
    /// so nothing that existed before this change moves.
    func testStatusIsNoLongerHardcodedAndALocalEventStillReadsConfirmed() throws {
        let repository = try makeRepository()
        var cancelled = Self.mirroredEvent(calendarID: TestData.calendarID)
        cancelled.providerMetadata.status = .cancelled

        try repository.save(TestData.database(events: [TestData.event(), cancelled]))
        let loaded = try repository.load()

        XCTAssertEqual(loaded.events.first { $0.id == TestData.eventID }?.status, .confirmed)
        XCTAssertEqual(loaded.events.first { $0.id == cancelled.id }?.status, .cancelled)
    }

    /// Attendees are wholly owned by their event: re-saving replaces them rather than
    /// accumulating a second copy, the same rule reminders follow.
    func testResavingAnEventReplacesRatherThanDuplicatesItsAttendees() throws {
        let repository = try makeRepository()
        var event = Self.mirroredEvent(calendarID: TestData.calendarID)

        try repository.save(TestData.database(events: [event]))
        event.attendees = [EventAttendee(name: "Only one left", participationStatus: .accepted, sortOrder: 0)]
        try repository.save(TestData.database(events: [event]))

        let stored = try XCTUnwrap(try repository.load().events.first)
        XCTAssertEqual(stored.attendees.count, 1)
        XCTAssertEqual(stored.attendees.first?.name, "Only one left")
    }

    /// Spec 3C.5's privacy rule: attendee names and addresses are third-party personal data and
    /// never enter the search index, where a query for a colleague's surname would surface them.
    func testAttendeeNamesAndAddressesAreNotSearchable() throws {
        let repository = try makeRepository()
        let event = Self.mirroredEvent(calendarID: TestData.calendarID)

        try repository.save(TestData.database(events: [event]))

        XCTAssertTrue(try repository.searchEventIDs(matching: "Dana").isEmpty)
        XCTAssertTrue(try repository.searchEventIDs(matching: "dana@example.com").isEmpty)
        XCTAssertEqual(try repository.searchEventIDs(matching: "Mirrored"), [event.id], "the title itself is still searchable")
    }

    /// Spec 0.12: a tombstone's snapshot must be enough to reconstruct the event. An encoder that
    /// silently omitted attendees would lose the guest list on every delete.
    func testATombstoneSnapshotCarriesTheGuestList() throws {
        let event = Self.mirroredEvent(calendarID: TestData.calendarID)
        let snapshotJSON = try XCTUnwrap(event.encodedSnapshotJSON())

        let restored = try XCTUnwrap(CalendarEvent(snapshotJSON: snapshotJSON))
        XCTAssertEqual(restored.attendees.count, 2)
        XCTAssertEqual(restored.organizer?.email, "dana@example.com")
        XCTAssertEqual(restored.providerMetadata.providerExternalID, "ext-1")
        XCTAssertTrue(restored.providerMetadata.hasUnrepresentableRecurrence)
    }

    /// The hand-written decoders exist because Swift's synthesized one ignores defaults: a
    /// payload written before these fields existed must decode as what it was, not throw.
    func testASnapshotWrittenBeforePhase3CStillDecodes() throws {
        let legacyJSON = """
        {
          "id": "\(TestData.eventID.uuidString)",
          "calendarID": "\(TestData.calendarID.uuidString)",
          "title": "Written by an older build",
          "startDate": "2026-09-02T14:00:00Z",
          "endDate": "2026-09-02T15:00:00Z",
          "timeType": "timed",
          "timeZoneIdentifier": "UTC",
          "reminders": [],
          "providerMetadata": { "provider": "Better Calendar", "syncStatus": "Synced" },
          "createdAt": "2026-09-01T12:00:00Z",
          "updatedAt": "2026-09-01T12:00:00Z"
        }
        """

        let decoded = try XCTUnwrap(CalendarEvent(snapshotJSON: legacyJSON))
        XCTAssertTrue(decoded.attendees.isEmpty)
        XCTAssertEqual(decoded.status, .confirmed)
        XCTAssertFalse(decoded.hasUnrepresentableRecurrence)
        XCTAssertNil(decoded.providerMetadata.providerExternalID)
    }

    // MARK: - The model-layer refusal (spec 3.13 / 3C.3)

    /// Spec 3C.3: a series the engine cannot express is read-only *at the model layer*, so a
    /// partial rule written back is unreachable rather than merely unlikely.
    ///
    /// The calendar here is fully writable, so nothing but the recurrence gate can be doing the
    /// refusing.
    func testEditingAnEventWithAnUnrepresentableSeriesIsRejectedWithItsOwnReason() throws {
        let fixture = try makeUnrepresentableFixture()

        let outcome = EventMutationUseCases.updateEvent(
            eventID: Self.unrepresentableEventID,
            expectedVersionNumber: 1,
            in: fixture.context
        ) { $0.title = "Renamed" }

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .unrepresentableRecurrence)
        XCTAssertEqual(violation.calendarID, fixture.writableCalendarID)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.first { $0.id == Self.unrepresentableEventID }?.title, "Payday")
        XCTAssertTrue(reloaded.pendingMutations.isEmpty, "a rejected mutation must not reach the outbox")
    }

    /// Moving and resizing are `updateEvent` closures, so they inherit the gate — which is the
    /// point of putting it there rather than at each call site.
    func testMovingAnEventWithAnUnrepresentableSeriesIsRejected() throws {
        let fixture = try makeUnrepresentableFixture()

        let outcome = EventMutationUseCases.moveEvent(
            eventID: Self.unrepresentableEventID,
            to: TestData.date("2026-09-26T14:00:00Z"),
            expectedVersionNumber: 1,
            in: fixture.context
        )

        guard case .rejected(let violation) = outcome else {
            return XCTFail("expected a capability rejection, got \(outcome)")
        }
        XCTAssertEqual(violation.reason, .unrepresentableRecurrence)
    }

    /// The gate is about *writing an approximation back over a series*. Creating a new event on
    /// the same calendar cannot do that, so it is not refused — a mistake here would make a whole
    /// calendar unusable because one event on it has an odd repeat rule.
    func testCreatingAnEventOnTheSameCalendarIsUnaffected() throws {
        let fixture = try makeUnrepresentableFixture()
        let newEvent = TestData.event(id: UUID(), calendarID: fixture.writableCalendarID, title: "Ordinary event")

        guard case .applied = EventMutationUseCases.createEvent(newEvent, in: fixture.context) else {
            return XCTFail("creating alongside an unrepresentable series must still work")
        }
    }

    /// Duplicating produces a Better Calendar-owned copy with no recurrence at all, so there is
    /// no series to approximate and nothing to refuse.
    func testDuplicatingAnEventWithAnUnrepresentableSeriesProducesAPlainLocalCopy() throws {
        let fixture = try makeUnrepresentableFixture()
        let source = try XCTUnwrap(fixture.context.database.events.first { $0.id == Self.unrepresentableEventID })

        guard case .applied(let transaction) = EventMutationUseCases.duplicateEvent(source, in: fixture.context) else {
            return XCTFail("expected the duplicate to be applied")
        }

        let copy = try XCTUnwrap(transaction.entityChanges.compactMap { change -> CalendarEvent? in
            guard case .upsertEvent(let event) = change else { return nil }
            return event
        }.first)
        XCTAssertNil(copy.recurrence)
        XCTAssertFalse(copy.hasUnrepresentableRecurrence)
        XCTAssertEqual(copy.providerMetadata.provider, .betterCalendar)
    }

    func testAnOrdinaryEventIsUnaffectedByTheRecurrenceGate() throws {
        let fixture = try makeUnrepresentableFixture()

        let outcome = EventMutationUseCases.updateEvent(
            eventID: TestData.eventID,
            expectedVersionNumber: 1,
            in: fixture.context
        ) { $0.title = "Renamed" }

        guard case .applied = outcome else {
            return XCTFail("an ordinary event must still be editable, got \(outcome)")
        }
    }

    // MARK: - Fixtures

    private static let unrepresentableEventID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

    private static func deviceCalendar(id: UUID = TestData.secondCalendarID) -> BetterCalendar {
        BetterCalendar(
            id: id,
            name: "Work",
            colorName: .betterBlue,
            isVisible: true,
            isDefault: false,
            sortOrder: 1,
            createdAt: TestData.date("2026-09-01T12:00:00Z"),
            updatedAt: TestData.date("2026-09-01T12:00:00Z"),
            provider: .apple,
            connectionMethod: .device,
            providerAccountID: "ek-source-icloud",
            providerCalendarID: "ek-calendar-work",
            accountName: "iCloud"
        )
    }

    private static func mirroredEvent(calendarID: UUID) -> CalendarEvent {
        var event = TestData.event(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            calendarID: calendarID,
            title: "Mirrored review"
        )
        event.providerMetadata = ProviderMetadata(
            provider: .apple,
            providerObjectID: "ek-event-1",
            providerVersion: "801000000.000",
            syncStatus: .synced,
            providerExternalID: "ext-1",
            providerRawFields: #"{"conferenceURL":"https://meet.example.com/abc"}"#,
            status: .tentative,
            hasUnrepresentableRecurrence: true
        )
        event.attendees = [
            EventAttendee(name: "Dana", email: "dana@example.com", participationStatus: .accepted, role: .chair, isOrganizer: true, sortOrder: 0),
            EventAttendee(name: "Me", email: "me@example.com", participationStatus: .declined, role: .required, isCurrentUser: true, sortOrder: 1)
        ]
        return event
    }

    private struct Fixture {
        var repository: SQLiteCalendarRepository
        var context: EventMutationUseCases.Context
        var writableCalendarID: UUID
    }

    /// A **writable** device calendar carrying one event whose repeat pattern the engine cannot
    /// express, plus an ordinary local event — so a rejection here can only be the recurrence
    /// gate, and the control case is in the same database.
    private func makeUnrepresentableFixture() throws -> Fixture {
        let repository = try makeRepository()
        let calendar = Self.deviceCalendar()

        var event = TestData.event(
            id: Self.unrepresentableEventID,
            calendarID: calendar.id,
            title: "Payday",
            startDate: TestData.date("2026-09-25T14:00:00Z"),
            endDate: TestData.date("2026-09-25T15:00:00Z")
        )
        event.providerMetadata = ProviderMetadata(
            provider: .apple,
            providerObjectID: "ek-payday",
            syncStatus: .synced,
            hasUnrepresentableRecurrence: true
        )

        try repository.save(TestData.database(calendars: [TestData.calendar(), calendar], events: [TestData.event(), event]))

        return Fixture(
            repository: repository,
            context: EventMutationUseCases.Context(database: try repository.load(), now: TestData.date("2026-09-02T12:00:00Z")),
            writableCalendarID: calendar.id
        )
    }

    private func makeRepository() throws -> SQLiteCalendarRepository {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SQLiteCalendarRepository(fileURL: directory.appending(path: "BetterCalendar.sqlite"))
    }
}
