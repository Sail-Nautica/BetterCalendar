import XCTest
@testable import Better_Calendar

/// Spec 2.6 (BC-ENG-003): `ConflictIndex`, plus its wiring into `BetterCalendarStore`.
final class ConflictDetectionTests: XCTestCase {

    // MARK: - Pure ConflictIndex behavior

    func testOverlappingBusyEventsFlagged() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [a, b])

        XCTAssertEqual(index.conflicts(for: a.id), [b.id])
        XCTAssertEqual(index.conflicts(for: b.id), [a.id])
    }

    func testDisjointEventsAreNotFlagged() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))
        let index = ConflictIndex(events: [a, b])

        XCTAssertTrue(index.conflicts(for: a.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty)
    }

    /// `[start, end)` is half-open, matching how every other interval comparison in this codebase
    /// (recurrence expansion, free/busy merging's own *inclusion* of adjacency being the
    /// deliberate exception — see `FreeBusyTests`) treats a touching boundary.
    func testAdjacentEventsDoNotConflict() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T10:00:00Z"), endDate: TestData.date("2026-09-02T11:00:00Z"))
        let index = ConflictIndex(events: [a, b])

        XCTAssertTrue(index.conflicts(for: a.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty)
    }

    func testFreeEventsNeverConflictEvenWhenTheirTimesOverlap() {
        var a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        a.availability = .free
        let index = ConflictIndex(events: [a, b])

        XCTAssertTrue(index.conflicts(for: a.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty, "a's own free status means b has nothing busy left to conflict with")
    }

    func testAllDayEventsDoNotConflictWithOverlappingTimedEvents() {
        let allDay = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T00:00:00Z"), endDate: TestData.date("2026-09-03T00:00:00Z"), isAllDay: true)
        let timed = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let index = ConflictIndex(events: [allDay, timed])

        XCTAssertTrue(index.conflicts(for: allDay.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: timed.id).isEmpty)
    }

    func testOverlappingAllDayEventsConflict() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T00:00:00Z"), endDate: TestData.date("2026-09-04T00:00:00Z"), isAllDay: true) // Sep 2-3
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-03T00:00:00Z"), endDate: TestData.date("2026-09-05T00:00:00Z"), isAllDay: true) // Sep 3-4
        let index = ConflictIndex(events: [a, b])

        XCTAssertEqual(index.conflicts(for: a.id), [b.id], "both cover Sep 3")
    }

    /// CLAUDE.md: all-day events compare on local calendar-date components, never UTC instants.
    /// These two events' raw UTC storage windows overlap (`[Sep2 00:00Z, Sep3 00:00Z)` vs
    /// `[Sep2 10:00Z, Sep3 10:00Z)`), but they represent different local all-day dates — Sep 2 in
    /// UTC, Sep 3 in `Pacific/Kiritimati` (UTC+14) — so a correct implementation must *not* flag
    /// them, even though comparing the raw instants alone would.
    func testAllDayConflictComparesLocalCalendarDateNotRawUTCInstants() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T00:00:00Z"), endDate: TestData.date("2026-09-03T00:00:00Z"), isAllDay: true, timeZoneIdentifier: "UTC")
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T10:00:00Z"), endDate: TestData.date("2026-09-03T10:00:00Z"), isAllDay: true, timeZoneIdentifier: "Pacific/Kiritimati")
        let index = ConflictIndex(events: [a, b])

        XCTAssertTrue(index.conflicts(for: a.id).isEmpty, "Sep 2 (UTC) and Sep 3 (Kiritimati) are different all-day dates despite overlapping raw UTC storage windows")
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty)
    }

    // MARK: - Incremental reindex

    func testMovingAnEventOutOfConflictClearsItForBothSides() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [a, b])
        XCTAssertEqual(index.conflicts(for: a.id), [b.id])

        var movedA = a
        movedA.startDate = TestData.date("2026-09-05T14:00:00Z")
        movedA.endDate = TestData.date("2026-09-05T15:00:00Z")

        let affected = index.reindex(movedFrom: a, to: movedA)
        XCTAssertEqual(affected, [b.id], "b is the only other event whose conflict status changed")
        XCTAssertTrue(index.conflicts(for: movedA.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty)
    }

    func testMovingAnEventIntoConflictFlagsBothSides() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-05T14:00:00Z"), endDate: TestData.date("2026-09-05T15:00:00Z"))
        let index = ConflictIndex(events: [a, b])
        XCTAssertTrue(index.conflicts(for: a.id).isEmpty)

        var movedA = a
        movedA.startDate = TestData.date("2026-09-05T14:30:00Z")
        movedA.endDate = TestData.date("2026-09-05T15:30:00Z")

        let affected = index.reindex(movedFrom: a, to: movedA)
        XCTAssertEqual(affected, [b.id])
        XCTAssertEqual(index.conflicts(for: movedA.id), [b.id])
        XCTAssertEqual(index.conflicts(for: b.id), [movedA.id])
    }

    func testReindexToNilRemovesTheEventEntirely() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [a, b])

        let affected = index.reindex(movedFrom: a, to: nil)
        XCTAssertEqual(affected, [b.id])
        XCTAssertTrue(index.conflicts(for: b.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: a.id).isEmpty, "a is no longer indexed at all, not just conflict-free")
    }

    func testReindexFromNilInsertsANewlyCreatedEvent() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let index = ConflictIndex(events: [a])

        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let affected = index.reindex(movedFrom: nil, to: b)

        XCTAssertEqual(affected, [a.id])
        XCTAssertEqual(index.conflicts(for: b.id), [a.id])
    }

    // MARK: - Store wiring

    /// Proves `BetterCalendarStore.conflictingEventIDs(for:)` stays correct through the actual
    /// mutation pipeline (`withPersistedMutation`/`reindexConflicts`), not just against a
    /// hand-built `ConflictIndex`.
    @MainActor
    func testStoreConflictingEventIDsTracksCreateMoveAndDelete() throws {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [a])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        XCTAssertTrue(store.conflictingEventIDs(for: a).isEmpty)

        var bDraft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:30:00Z"), duration: 60 * 60)
        bDraft.title = "Overlaps A"
        XCTAssertTrue(store.saveEvent(from: bDraft))
        let b = try XCTUnwrap(store.events.first { $0.id != a.id })

        XCTAssertEqual(store.conflictingEventIDs(for: a), [b.id])
        XCTAssertEqual(store.conflictingEventIDs(for: b), [a.id])

        store.moveEvent(b, to: TestData.date("2026-09-05T14:30:00Z"))
        let movedB = try XCTUnwrap(store.events.first { $0.id == b.id })
        XCTAssertTrue(store.conflictingEventIDs(for: a).isEmpty)
        XCTAssertTrue(store.conflictingEventIDs(for: movedB).isEmpty)

        store.deleteEvent(a)
        XCTAssertTrue(store.conflictingEventIDs(for: movedB).isEmpty)
    }

    /// The transaction for deleting a calendar carries only `.deleteCalendar`, not one
    /// `.deleteEvent` per cascaded row (see `LocalCalendarDatabase.applying(_:)`) — this proves
    /// `reindexConflicts` finds those cascaded events anyway, rather than leaving stale entries
    /// that would misreport conflicts against events that no longer exist.
    @MainActor
    func testDeletingACalendarClearsConflictIndexEntriesForItsCascadedEvents() throws {
        let doomed = TestData.calendar(id: TestData.secondCalendarID, name: "Doomed", isDefault: false, sortOrder: 1)
        let a = TestData.event(id: UUID(), calendarID: TestData.secondCalendarID, startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(calendars: [TestData.calendar(), doomed], events: [a, b])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        XCTAssertEqual(store.conflictingEventIDs(for: b), [a.id])

        store.deleteCalendar(doomed, moveEventsTo: nil)

        XCTAssertTrue(store.conflictingEventIDs(for: b).isEmpty, "a was cascaded away with its calendar and must not still be reported as a conflict")
    }

    // MARK: - Cancelled and declined (spec 3C.5)

    /// A cancelled meeting still occupies the calendar visually, but it cannot conflict with
    /// anything — it is information, not a commitment.
    func testACancelledEventRaisesNoConflictButIsStillReturnedForDisplay() {
        var cancelled = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        cancelled.providerMetadata.status = .cancelled
        let live = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [cancelled, live])

        XCTAssertTrue(index.conflicts(for: live.id).isEmpty)
        XCTAssertTrue(index.conflicts(for: cancelled.id).isEmpty)
        // Still a row, still displayable — the exclusion is from conflict detection, not from
        // the calendar.
        XCTAssertEqual(cancelled.title, "Calculus Lecture")
        XCTAssertFalse(cancelled.occupiesTime())
    }

    func testAnEventTheCurrentUserDeclinedRaisesNoConflict() {
        var declined = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        declined.attendees = [EventAttendee(name: "Me", participationStatus: .declined, isCurrentUser: true)]
        let live = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [declined, live])

        XCTAssertTrue(index.conflicts(for: live.id).isEmpty)
    }

    /// Tentative is deliberately *not* excluded here. A "maybe" on the calendar is still worth
    /// warning about; only an explicit free/busy query gets to drop it.
    func testATentativeEventStillRaisesAConflict() {
        var tentative = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        tentative.providerMetadata.status = .tentative
        let live = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T14:30:00Z"), endDate: TestData.date("2026-09-02T15:30:00Z"))
        let index = ConflictIndex(events: [tentative, live])

        XCTAssertEqual(index.conflicts(for: live.id), [tentative.id])
    }
}
