import XCTest
@testable import Better_Calendar

final class CalendarEngineTests: XCTestCase {
    // BC-EVT-011
    func testFloatingEventKeepsItsWallClockTimeWhenViewedFromAnotherTimeZone() throws {
        // 8:00 PM on 2026-09-03 in Detroit (EDT, UTC-4) is 2026-09-04T00:00:00Z.
        let event = TestData.event(
            startDate: TestData.date("2026-09-04T00:00:00Z"),
            endDate: TestData.date("2026-09-04T01:00:00Z"),
            timeType: .floating,
            timeZoneIdentifier: "America/Detroit"
        )

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let displayed = losAngeles.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: event.displayStartDate(in: losAngeles)
        )

        XCTAssertEqual(displayed.hour, 20, "A floating event must still read 8:00 PM after the device changes zone.")
        XCTAssertEqual(displayed.minute, 0)
        XCTAssertEqual(displayed.day, 3)
        XCTAssertEqual(displayed.month, 9)
    }

    // BC-EVT-011
    func testTimedAndAllDayEventsReturnStoredDatesUnchangedWhenDisplayed() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let timed = TestData.event()
        XCTAssertEqual(timed.displayStartDate(in: losAngeles), timed.startDate)
        XCTAssertEqual(timed.displayEndDate(in: losAngeles), timed.endDate)

        let allDay = TestData.event(isAllDay: true)
        XCTAssertEqual(allDay.displayStartDate(in: losAngeles), allDay.startDate)
        XCTAssertEqual(allDay.displayEndDate(in: losAngeles), allDay.endDate)
    }

    func testWeeklyRecurrenceExpandsSelectedWeekdaysWithinRange() {
        let start = date(year: 2026, month: 9, day: 7, hour: 9, timeZoneIdentifier: "America/Detroit")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            timeZoneIdentifier: "America/Detroit",
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday], end: .afterOccurrences(4))
        )
        let range = DateInterval(start: date(year: 2026, month: 9, day: 1, timeZoneIdentifier: "America/Detroit"), end: date(year: 2026, month: 9, day: 21, timeZoneIdentifier: "America/Detroit"))

        let occurrences = RecurrenceExpander().occurrences(of: event, in: range)
        let weekdays = occurrences.map { weekday(for: $0.occurrenceStartDate, timeZoneIdentifier: "America/Detroit") }

        XCTAssertEqual(weekdays, [.monday, .wednesday, .monday, .wednesday])
    }

    func testWeeklyRecurrencePreservesOriginalLocalTimeAcrossDST() {
        let start = date(year: 2026, month: 3, day: 1, hour: 9, timeZoneIdentifier: "America/Detroit")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            timeZoneIdentifier: "America/Detroit",
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [], end: .afterOccurrences(3))
        )
        let range = DateInterval(start: date(year: 2026, month: 3, day: 1, timeZoneIdentifier: "America/Detroit"), end: date(year: 2026, month: 3, day: 22, timeZoneIdentifier: "America/Detroit"))

        let occurrences = RecurrenceExpander().occurrences(of: event, in: range)
        let localHours = occurrences.map { hour(for: $0.occurrenceStartDate, timeZoneIdentifier: "America/Detroit") }
        let utcHours = occurrences.map { hour(for: $0.occurrenceStartDate, timeZoneIdentifier: "UTC") }

        XCTAssertEqual(localHours, [9, 9, 9])
        XCTAssertEqual(utcHours, [14, 13, 13])
    }

    func testMonthlyRecurrenceFromThirtyFirstClampsWithoutDrifting() {
        let start = date(year: 2026, month: 1, day: 31, hour: 10, timeZoneIdentifier: "UTC")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .monthly, interval: 1, weekdays: [], end: .afterOccurrences(3))
        )
        let range = DateInterval(start: TestData.date("2026-01-01T00:00:00Z"), end: TestData.date("2026-04-01T00:00:00Z"))

        let days = RecurrenceExpander().occurrences(of: event, in: range).map { day(for: $0.occurrenceStartDate, timeZoneIdentifier: "UTC") }

        XCTAssertEqual(days, [31, 28, 31])
    }

    func testLeapDayYearlyRecurrenceClampsInNonLeapYears() {
        let start = date(year: 2028, month: 2, day: 29, hour: 12, timeZoneIdentifier: "UTC")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .yearly, interval: 1, weekdays: [], end: .afterOccurrences(3))
        )
        let range = DateInterval(start: TestData.date("2028-01-01T00:00:00Z"), end: TestData.date("2031-01-01T00:00:00Z"))

        let monthDays = RecurrenceExpander().occurrences(of: event, in: range).map {
            monthDay(for: $0.occurrenceStartDate, timeZoneIdentifier: "UTC")
        }

        XCTAssertEqual(monthDays, ["02-29", "02-28", "02-28"])
    }

    // BC-REC-011
    func testMonthlyRecurrenceOnLastFridayOfMonth() {
        // Last Fridays of Sept/Oct/Nov 2026: 25th, 30th, 27th.
        let start = date(year: 2026, month: 9, day: 4, hour: 9, timeZoneIdentifier: "UTC")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .monthly, interval: 1, weekdays: [.friday], setPositions: [-1], end: .afterOccurrences(3))
        )
        let range = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-12-31T00:00:00Z"))

        let monthDays = RecurrenceExpander().occurrences(of: event, in: range).map { monthDay(for: $0.occurrenceStartDate, timeZoneIdentifier: "UTC") }

        XCTAssertEqual(monthDays, ["09-25", "10-30", "11-27"])
    }

    // BC-REC-011
    func testMonthlyRecurrenceWithMultipleDaysOfMonth() {
        let start = date(year: 2026, month: 9, day: 1, hour: 9, timeZoneIdentifier: "UTC")
        let event = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .monthly, interval: 1, weekdays: [], daysOfMonth: [1, 15], end: .afterOccurrences(4))
        )
        let range = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-11-01T00:00:00Z"))

        let monthDays = RecurrenceExpander().occurrences(of: event, in: range).map { monthDay(for: $0.occurrenceStartDate, timeZoneIdentifier: "UTC") }

        XCTAssertEqual(monthDays, ["09-01", "09-15", "10-01", "10-15"])
    }

    // BC-REC-010
    func testExpanderSkipsCancelledExceptionOccurrence() {
        let start = TestData.date("2026-09-07T14:00:00Z") // a Monday
        let master = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(3))
        )
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )
        let range = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z"))

        let occurrences = RecurrenceExpander().occurrences(of: master, in: range, exceptions: [exception])

        XCTAssertEqual(occurrences.map(\.occurrenceStartDate), [start, TestData.date("2026-09-21T14:00:00Z")])
    }

    // BC-REC-010
    func testExpanderOmitsSlotForModifiedException() {
        let start = TestData.date("2026-09-07T14:00:00Z")
        let master = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(3))
        )
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .modified,
            replacementEventID: UUID()
        )
        let range = DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z"))

        let occurrences = RecurrenceExpander().occurrences(of: master, in: range, exceptions: [exception])

        XCTAssertEqual(occurrences.map(\.occurrenceStartDate), [start, TestData.date("2026-09-21T14:00:00Z")])
    }

    // BC-REC-010
    func testNotificationPlannerSuppressesNotificationsForCancelledOccurrence() {
        let reminder = EventReminder(id: UUID(), offset: .minutesBefore(10))
        let start = TestData.date("2026-09-07T14:00:00Z")
        var master = event(
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(2))
        )
        master.reminders = [reminder]
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )

        let plan = LocalNotificationPlanner().plan(
            events: [master],
            calendars: [TestData.calendar()],
            pendingIdentifiers: [],
            now: TestData.date("2026-09-01T00:00:00Z"),
            horizonEnd: TestData.date("2026-09-30T00:00:00Z"),
            recurrenceExceptions: [exception]
        )

        XCTAssertEqual(plan.requestsToSchedule.count, 1)
        XCTAssertEqual(plan.requestsToSchedule.first?.fireDate, start.addingTimeInterval(-600))
    }

    // BC-VIEW-012
    func testMovedPreservingTimeOfDayKeepsClockTimeButChangesCalendarDate() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let thisEvent = event(startDate: TestData.date("2026-09-07T14:30:00Z"), endDate: TestData.date("2026-09-07T15:00:00Z"))
        let targetDay = TestData.date("2026-09-10T00:00:00Z")

        let moved = thisEvent.movedPreservingTimeOfDay(to: targetDay, calendar: utcCalendar)

        XCTAssertEqual(moved, TestData.date("2026-09-10T14:30:00Z"), "The time-of-day (14:30) must carry over; only the calendar date changes.")
    }

    func testStartTimeDisplayedInSecondaryZoneConvertsTimedEventToTargetZoneClockTime() {
        let start = TestData.date("2026-09-07T14:30:00Z")
        let thisEvent = event(startDate: start, endDate: TestData.date("2026-09-07T15:00:00Z"), timeZoneIdentifier: "UTC")

        let displayed = thisEvent.startTime(displayedIn: "America/New_York")

        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = .autoupdatingCurrent
        expectedFormatter.timeZone = TimeZone(identifier: "America/New_York")
        expectedFormatter.dateStyle = .none
        expectedFormatter.timeStyle = .short

        XCTAssertEqual(displayed, expectedFormatter.string(from: start))
    }

    func testStartTimeDisplayedInSecondaryZoneReturnsNilForAllDayEvents() {
        let thisEvent = event(startDate: TestData.date("2026-09-07T00:00:00Z"), endDate: TestData.date("2026-09-08T00:00:00Z"), isAllDay: true)

        XCTAssertNil(thisEvent.startTime(displayedIn: "America/New_York"))
    }

    func testStartTimeDisplayedInSecondaryZoneReturnsNilForUnknownZoneIdentifier() {
        let thisEvent = event(startDate: TestData.date("2026-09-07T14:30:00Z"), endDate: TestData.date("2026-09-07T15:00:00Z"))

        XCTAssertNil(thisEvent.startTime(displayedIn: "Not/AZone"))
    }

    func testAllDayOccurrenceUsesDisplayDateInsteadOfAbsoluteMidnight() throws {
        let start = date(year: 2026, month: 10, day: 12, timeZoneIdentifier: "America/Detroit")
        let end = date(year: 2026, month: 10, day: 14, timeZoneIdentifier: "America/Detroit")
        let event = event(startDate: start, endDate: end, isAllDay: true, timeZoneIdentifier: "America/Detroit")
        let range = DateInterval(start: TestData.date("2026-10-01T00:00:00Z"), end: TestData.date("2026-10-31T00:00:00Z"))
        let occurrence = try XCTUnwrap(RecurrenceExpander().occurrences(of: event, in: range).first)
        var losAngelesCalendar = Calendar(identifier: .gregorian)
        losAngelesCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        XCTAssertFalse(occurrence.occurs(on: date(year: 2026, month: 10, day: 11, hour: 12, timeZoneIdentifier: "America/Los_Angeles"), displayCalendar: losAngelesCalendar))
        XCTAssertTrue(occurrence.occurs(on: date(year: 2026, month: 10, day: 12, hour: 12, timeZoneIdentifier: "America/Los_Angeles"), displayCalendar: losAngelesCalendar))
        XCTAssertTrue(occurrence.occurs(on: date(year: 2026, month: 10, day: 13, hour: 12, timeZoneIdentifier: "America/Los_Angeles"), displayCalendar: losAngelesCalendar))
        XCTAssertFalse(occurrence.occurs(on: date(year: 2026, month: 10, day: 14, hour: 12, timeZoneIdentifier: "America/Los_Angeles"), displayCalendar: losAngelesCalendar))
    }

    func testNotificationPlannerSchedulesRollingRecurringRemindersAndCancelsStaleRequests() {
        let reminder = EventReminder(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, offset: .minutesBefore(10))
        let start = TestData.date("2026-09-02T14:00:00Z")
        var timedEvent = event(
            startDate: start,
            endDate: TestData.date("2026-09-02T15:00:00Z"),
            recurrence: RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], end: .afterOccurrences(2))
        )
        timedEvent.reminders = [reminder]

        let staleIdentifier = "better-calendar.event.\(timedEvent.id.uuidString).reminder.stale.occurrence.1"
        let plan = LocalNotificationPlanner().plan(
            events: [timedEvent],
            calendars: [TestData.calendar()],
            pendingIdentifiers: [staleIdentifier, "external.notification"],
            now: TestData.date("2026-09-02T12:00:00Z"),
            horizonEnd: TestData.date("2026-09-05T00:00:00Z")
        )

        XCTAssertEqual(plan.requestsToSchedule.count, 2)
        XCTAssertEqual(plan.requestsToSchedule.map(\.fireDate), [
            TestData.date("2026-09-02T13:50:00Z"),
            TestData.date("2026-09-03T13:50:00Z")
        ])
        XCTAssertEqual(plan.identifiersToCancel, [staleIdentifier])
    }

    func testNotificationPlannerUsesNineAMLocalDefaultForAllDayEvents() throws {
        let reminder = EventReminder(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, offset: .atStart)
        var allDayEvent = event(
            startDate: date(year: 2026, month: 10, day: 12, timeZoneIdentifier: "America/Detroit"),
            endDate: date(year: 2026, month: 10, day: 13, timeZoneIdentifier: "America/Detroit"),
            isAllDay: true,
            timeZoneIdentifier: "America/Detroit"
        )
        allDayEvent.reminders = [reminder]

        let plan = LocalNotificationPlanner().plan(
            events: [allDayEvent],
            calendars: [TestData.calendar()],
            pendingIdentifiers: [],
            now: TestData.date("2026-10-01T00:00:00Z"),
            horizonEnd: TestData.date("2026-10-31T00:00:00Z")
        )

        let fireDate = try XCTUnwrap(plan.requestsToSchedule.first?.fireDate)
        XCTAssertEqual(hour(for: fireDate, timeZoneIdentifier: "America/Detroit"), 9)
        XCTAssertEqual(day(for: fireDate, timeZoneIdentifier: "America/Detroit"), 12)
    }

    // BC-NOT-001
    func testNotificationPlannerProducesDistinctIdentifiersForEventWithThreeReminders() {
        let reminders = [
            EventReminder(id: UUID(), offset: .atStart),
            EventReminder(id: UUID(), offset: .minutesBefore(10)),
            EventReminder(id: UUID(), offset: .daysBefore(1))
        ]
        let start = TestData.date("2026-09-02T14:00:00Z")
        var timedEvent = event(startDate: start, endDate: TestData.date("2026-09-02T15:00:00Z"))
        timedEvent.reminders = reminders

        let plan = LocalNotificationPlanner().plan(
            events: [timedEvent],
            calendars: [TestData.calendar()],
            pendingIdentifiers: [],
            now: TestData.date("2026-09-01T00:00:00Z"),
            horizonEnd: TestData.date("2026-09-10T00:00:00Z")
        )

        XCTAssertEqual(plan.requestsToSchedule.count, 3)
        XCTAssertEqual(Set(plan.requestsToSchedule.map(\.identifier)).count, 3)
    }

    // BC-NOT-001
    func testNotificationPlannerSchedulesNoNotificationsForEventWithZeroReminders() {
        let start = TestData.date("2026-09-02T14:00:00Z")
        let timedEvent = event(startDate: start, endDate: TestData.date("2026-09-02T15:00:00Z"))

        let plan = LocalNotificationPlanner().plan(
            events: [timedEvent],
            calendars: [TestData.calendar()],
            pendingIdentifiers: [],
            now: TestData.date("2026-09-01T00:00:00Z"),
            horizonEnd: TestData.date("2026-09-10T00:00:00Z")
        )

        XCTAssertTrue(plan.requestsToSchedule.isEmpty)
    }

    private func event(
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = "UTC",
        recurrence: RecurrenceRule? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: TestData.eventID,
            calendarID: TestData.calendarID,
            title: "Test Event",
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            location: nil,
            urlString: nil,
            notes: nil,
            reminders: [],
            recurrence: recurrence,
            providerMetadata: .local,
            createdAt: TestData.date("2026-01-01T00:00:00Z"),
            updatedAt: TestData.date("2026-01-01T00:00:00Z")
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, timeZoneIdentifier: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func weekday(for date: Date, timeZoneIdentifier: String) -> Weekday {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return Weekday(rawValue: calendar.component(.weekday, from: date))!
    }

    private func hour(for date: Date, timeZoneIdentifier: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.component(.hour, from: date)
    }

    private func day(for date: Date, timeZoneIdentifier: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.component(.day, from: date)
    }

    private func monthDay(for date: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let components = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
    }
}
