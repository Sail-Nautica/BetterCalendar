import XCTest
@testable import MyApp

final class ICSCalendarCodecTests: XCTestCase {
    func testExportEscapesTextAndIncludesWeeklyRecurrenceRule() {
        let calendar = TestData.calendar(name: "School, Main")
        let event = TestData.event(
            title: "Study, Plan; Phase\\One",
            startDate: TestData.date("2026-09-02T14:00:00Z"),
            endDate: TestData.date("2026-09-02T15:00:00Z"),
            location: "Mason; Hall",
            notes: "Line 1\nLine 2",
            recurrence: RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.wednesday, .monday], end: .never)
        )

        let ics = ICSCalendarCodec.export(events: [event], calendars: [calendar])

        XCTAssertTrue(ics.contains("SUMMARY:Study\\, Plan\\; Phase\\\\One"))
        XCTAssertTrue(ics.contains("CATEGORIES:School\\, Main"))
        XCTAssertTrue(ics.contains("LOCATION:Mason\\; Hall"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Line 1\\nLine 2"))
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"))
    }

    func testExportFormatsAllDayDatesWithoutTimes() {
        let event = TestData.event(
            startDate: allDayDate(year: 2026, month: 9, day: 3),
            endDate: allDayDate(year: 2026, month: 9, day: 4),
            isAllDay: true
        )

        let ics = ICSCalendarCodec.export(events: [event], calendars: [TestData.calendar()])

        XCTAssertTrue(ics.contains("DTSTART:20260903"))
        XCTAssertTrue(ics.contains("DTEND:20260904"))
    }

    func testImportParsesUTCAndAllDayEventsAndCountsFailures() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Office\\, Hours
        DTSTART:20260902T150000Z
        DTEND:20260902T160000Z
        LOCATION:Mason\\; Hall
        DESCRIPTION:Bring notes\\nQuestions
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Break
        DTSTART:20260903
        DTEND:20260904
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Missing Start
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)

        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.failedCount, 1)

        let timedEvent = try XCTUnwrap(summary.events.first { $0.title == "Office, Hours" })
        XCTAssertEqual(timedEvent.startDate, TestData.date("2026-09-02T15:00:00Z"))
        XCTAssertEqual(timedEvent.endDate, TestData.date("2026-09-02T16:00:00Z"))
        XCTAssertFalse(timedEvent.isAllDay)
        XCTAssertEqual(timedEvent.location, "Mason; Hall")
        XCTAssertEqual(timedEvent.notes, "Bring notes\nQuestions")

        let allDayEvent = try XCTUnwrap(summary.events.first { $0.title == "Break" })
        XCTAssertEqual(localDateString(allDayEvent.startDate), "2026-09-03")
        XCTAssertEqual(localDateString(allDayEvent.endDate), "2026-09-04")
        XCTAssertTrue(allDayEvent.isAllDay)
    }

    @MainActor
    func testStoreImportCountsDuplicateEventsAsSkippedWithoutSaving() {
        let existingEvent = TestData.event(title: "Office Hours", startDate: TestData.date("2026-09-02T15:00:00Z"))
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [existingEvent])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Office Hours
        DTSTART:20260902T150000Z
        DTEND:20260902T160000Z
        END:VEVENT
        END:VCALENDAR
        """

        let summary = store.importICS(text)

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(repository.savedDatabases.isEmpty)
    }

    private func allDayDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func localDateString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }
}
