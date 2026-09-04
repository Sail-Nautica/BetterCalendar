import XCTest
@testable import Better_Calendar

/// Spec 2.7 (BC-ENG-004): `FreeBusy.query`, plus its wiring into `BetterCalendarStore.freeBusy(_:)`.
final class FreeBusyTests: XCTestCase {
    private func query(_ start: String, _ end: String, calendarIDs: Set<UUID>? = nil) -> FreeBusy.Query {
        FreeBusy.Query(rangeStart: TestData.date(start), rangeEnd: TestData.date(end), calendarIDs: calendarIDs)
    }

    func testMergesOverlappingAndAdjacentBusyIntervals() {
        let overlapping1 = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let overlapping2 = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:30:00Z"), endDate: TestData.date("2026-09-02T11:00:00Z"))
        // Touches overlapping2's end exactly — spec 2.7 says adjacent runs collapse too, unlike
        // ConflictIndex's half-open "touching does not conflict" rule for two live events.
        let adjacent = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [overlapping1, overlapping2, adjacent], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-02T09:00:00Z"), end: TestData.date("2026-09-02T12:00:00Z"))])
    }

    func testDisjointIntervalsStaySeparate() {
        let a = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let b = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [a, b], exceptions: [])

        XCTAssertEqual(result, [
            DateInterval(start: TestData.date("2026-09-02T09:00:00Z"), end: TestData.date("2026-09-02T10:00:00Z")),
            DateInterval(start: TestData.date("2026-09-02T11:00:00Z"), end: TestData.date("2026-09-02T12:00:00Z"))
        ])
    }

    func testFreeEventsContributeNoBusyInterval() {
        var event = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        event.availability = .free

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [event], exceptions: [])

        XCTAssertTrue(result.isEmpty)
    }

    /// BC-ENG-004's own name. Phase 2 has no attendee model (spec 2.0 explicitly excludes
    /// attendees/invitations), so "declined" has nothing to map to yet — only occurrence-level
    /// cancellation is meaningfully testable here; `includeTentative` is documented on
    /// `FreeBusy.Query` as a reserved no-op until Phase 3/4 add attendees.
    func testCancelledAndDeclinedExcluded() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2026-09-07T09:00:00Z"),
            endDate: TestData.date("2026-09-07T10:00:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(3))
        )
        let cancelledSecondOccurrence = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T09:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )

        let result = FreeBusy.query(
            query("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
            events: [master],
            exceptions: [cancelledSecondOccurrence]
        )

        XCTAssertEqual(result, [
            DateInterval(start: TestData.date("2026-09-07T09:00:00Z"), end: TestData.date("2026-09-07T10:00:00Z")),
            DateInterval(start: TestData.date("2026-09-21T09:00:00Z"), end: TestData.date("2026-09-21T10:00:00Z"))
        ], "the Sep 14 occurrence is cancelled and must not appear as a busy interval")
    }

    func testRecurringEventExpandsIntoMultipleBusyIntervalsWithinRange() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2026-09-07T09:00:00Z"),
            endDate: TestData.date("2026-09-07T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(4))
        )

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"), events: [master], exceptions: [])

        XCTAssertEqual(result.count, 4)
    }

    // MARK: - Pre-filter correctness (spec 2.19's cheap "could this series possibly land in
    // range" check ahead of the real `RecurrenceExpander` call)

    /// A bounded series (`.afterOccurrences`) that provably finishes before the query range
    /// starts must still correctly contribute nothing — the whole point of the pre-filter is to
    /// skip the expensive expansion for exactly this case without getting the *answer* wrong.
    func testBoundedSeriesEntirelyBeforeTheRangeContributesNothing() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2026-01-05T09:00:00Z"),
            endDate: TestData.date("2026-01-05T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(3))
        )

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-08T00:00:00Z"), events: [master], exceptions: [])

        XCTAssertTrue(result.isEmpty)
    }

    /// Same idea for an `.onDate`-bounded series.
    func testOnDateBoundedSeriesEntirelyBeforeTheRangeContributesNothing() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2026-01-05T09:00:00Z"),
            endDate: TestData.date("2026-01-05T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .onDate(TestData.date("2026-02-01T00:00:00Z")))
        )

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-08T00:00:00Z"), events: [master], exceptions: [])

        XCTAssertTrue(result.isEmpty)
    }

    /// A never-ending series can't be ruled out by the pre-filter no matter how long ago it
    /// started — it must still be expanded and still correctly contribute an occurrence.
    func testNeverEndingSeriesStartingLongBeforeTheRangeStillContributes() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2020-01-06T09:00:00Z"),
            endDate: TestData.date("2020-01-06T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        )

        let result = FreeBusy.query(query("2026-09-07T00:00:00Z", "2026-09-08T00:00:00Z"), events: [master], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-07T09:00:00Z"), end: TestData.date("2026-09-07T09:30:00Z"))])
    }

    /// The pre-filter's bound must be conservative enough not to clip a series whose last
    /// occurrence genuinely does land inside the range, even close to its edge.
    func testBoundedSeriesEndingRightAtTheStartOfTheRangeStillContributesItsLastOccurrence() {
        let master = TestData.event(
            id: UUID(),
            startDate: TestData.date("2026-08-17T09:00:00Z"), // a Monday
            endDate: TestData.date("2026-08-17T09:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(3)) // last: Aug 31
        )

        let result = FreeBusy.query(query("2026-08-31T00:00:00Z", "2026-09-08T00:00:00Z"), events: [master], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-08-31T09:00:00Z"), end: TestData.date("2026-08-31T09:30:00Z"))])
    }

    func testCalendarIDsFilterRestrictsToRequestedCalendars() {
        let included = TestData.event(id: UUID(), calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let excluded = TestData.event(id: UUID(), calendarID: TestData.secondCalendarID, startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z", calendarIDs: [TestData.calendarID]), events: [included, excluded], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-02T09:00:00Z"), end: TestData.date("2026-09-02T10:00:00Z"))])
    }

    func testIntervalsAreClampedToTheQueryRange() {
        let spanning = TestData.event(id: UUID(), startDate: TestData.date("2026-09-01T22:00:00Z"), endDate: TestData.date("2026-09-02T02:00:00Z"))

        let result = FreeBusy.query(query("2026-09-02T00:00:00Z", "2026-09-03T00:00:00Z"), events: [spanning], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-02T00:00:00Z"), end: TestData.date("2026-09-02T02:00:00Z"))])
    }

    // MARK: - Cancelled, declined and tentative (spec 3C.5, ADR 0002)

    /// ADR 0002 recorded that "declined" could not be implemented because Phase 2 had no attendee
    /// model, and named this phase as its revisit trigger. The user is not busy at a meeting they
    /// said no to.
    func testAnEventTheCurrentUserDeclinedContributesNoBusyTime() {
        var event = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        event.attendees = [
            EventAttendee(name: "Dana", email: "dana@example.com", participationStatus: .accepted, isOrganizer: true),
            EventAttendee(name: "Me", email: "me@example.com", participationStatus: .declined, isCurrentUser: true)
        ]

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [event], exceptions: [])

        XCTAssertTrue(result.isEmpty)
    }

    /// Someone *else* declining says nothing about whether the user is busy.
    func testAnotherAttendeeDecliningDoesNotFreeTheUsersTime() {
        var event = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        event.attendees = [
            EventAttendee(name: "Sam", email: "sam@example.com", participationStatus: .declined),
            EventAttendee(name: "Me", email: "me@example.com", participationStatus: .accepted, isCurrentUser: true)
        ]

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [event], exceptions: [])

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-02T09:00:00Z"), end: TestData.date("2026-09-02T10:00:00Z"))])
    }

    /// A cancelled event is still *displayed*, with its status shown — it is information, not a
    /// commitment — but it occupies no time.
    func testACancelledEventContributesNoBusyTime() {
        var event = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        event.providerMetadata.status = .cancelled

        let result = FreeBusy.query(query("2026-09-01T00:00:00Z", "2026-09-03T00:00:00Z"), events: [event], exceptions: [])

        XCTAssertTrue(result.isEmpty)
    }

    /// `includeTentative` stops being the documented no-op ADR 0002 left it as.
    func testIncludeTentativeGovernsWhetherATentativeEventIsBusy() {
        var byStatus = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        byStatus.providerMetadata.status = .tentative

        var byParticipation = TestData.event(id: UUID(), startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))
        byParticipation.attendees = [EventAttendee(name: "Me", participationStatus: .tentative, isCurrentUser: true)]

        let events = [byStatus, byParticipation]
        let range = (start: "2026-09-01T00:00:00Z", end: "2026-09-03T00:00:00Z")

        let included = FreeBusy.query(
            FreeBusy.Query(rangeStart: TestData.date(range.start), rangeEnd: TestData.date(range.end), includeTentative: true),
            events: events,
            exceptions: []
        )
        XCTAssertEqual(included.count, 2, "a maybe still occupies the slot unless the caller says otherwise")

        let excluded = FreeBusy.query(
            FreeBusy.Query(rangeStart: TestData.date(range.start), rangeEnd: TestData.date(range.end), includeTentative: false),
            events: events,
            exceptions: []
        )
        XCTAssertTrue(excluded.isEmpty, "both forms of tentative — the event's status and the user's answer — must be excluded")
    }

    // MARK: - Store wiring

    @MainActor
    func testStoreFreeBusyDefaultsToVisibleCalendarsOnlyWhenCalendarIDsIsNil() throws {
        let hidden = TestData.calendar(id: TestData.secondCalendarID, name: "Hidden", isDefault: false, sortOrder: 1)
        var hiddenCalendar = hidden
        hiddenCalendar.isVisible = false
        let visibleEvent = TestData.event(id: UUID(), calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T09:00:00Z"), endDate: TestData.date("2026-09-02T10:00:00Z"))
        let hiddenEvent = TestData.event(id: UUID(), calendarID: TestData.secondCalendarID, startDate: TestData.date("2026-09-02T11:00:00Z"), endDate: TestData.date("2026-09-02T12:00:00Z"))

        let repository = StubCalendarRepository(loadResult: .success(TestData.database(calendars: [TestData.calendar(), hiddenCalendar], events: [visibleEvent, hiddenEvent])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())

        let result = store.freeBusy(FreeBusy.Query(rangeStart: TestData.date("2026-09-01T00:00:00Z"), rangeEnd: TestData.date("2026-09-03T00:00:00Z")))

        XCTAssertEqual(result, [DateInterval(start: TestData.date("2026-09-02T09:00:00Z"), end: TestData.date("2026-09-02T10:00:00Z"))], "the hidden calendar's event must not contribute when calendarIDs is left nil")
    }
}
