import XCTest
@testable import Better_Calendar

final class CalendarEngineTests: XCTestCase {
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
