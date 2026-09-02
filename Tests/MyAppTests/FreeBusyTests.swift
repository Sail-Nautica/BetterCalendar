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
