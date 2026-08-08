import XCTest
@testable import Better_Calendar

final class DomainModelTests: XCTestCase {
    func testEventDraftValidationRequiresTitleAndChronologicalTimes() {
        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:15:00Z"))

        draft.title = "   "
        XCTAssertEqual(draft.validationError, "Enter a title before saving.")

        draft.title = "Office Hours"
        draft.endDate = draft.startDate
        XCTAssertEqual(draft.validationError, "End time must be after start time.")

        draft.endDate = draft.startDate.addingTimeInterval(30 * 60)
        XCTAssertNil(draft.validationError)
    }

    func testEventDraftRoundsInitialStartToNextHour() {
        let originalStart = TestData.date("2026-09-02T14:15:00Z")
        let draft = EventDraft(calendarID: TestData.calendarID, startDate: originalStart)

        XCTAssertGreaterThan(draft.startDate, originalStart)
        XCTAssertEqual(Calendar.current.component(.minute, from: draft.startDate), 0)
    }

    // BC-NOT-001
    func testNewEventDraftDefaultsToNoReminderOffsets() {
        let draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:15:00Z"))

        XCTAssertTrue(draft.reminderOffsets.isEmpty)
    }

    // BC-NOT-001
    func testEventDraftInitializedFromEventMapsAllReminderOffsetsInOrder() {
        var event = TestData.event()
        event.reminders = [
            EventReminder(id: UUID(), offset: .atStart),
            EventReminder(id: UUID(), offset: .minutesBefore(10)),
            EventReminder(id: UUID(), offset: .daysBefore(1))
        ]

        let draft = EventDraft(event: event)

        XCTAssertEqual(draft.reminderOffsets, [.atStart, .minutesBefore(10), .daysBefore(1)])
    }

    // BC-NOT-001
    func testReminderOffsetPresetsIncludeHourAndTwoHourOptionsWithHumanReadableLabels() {
        XCTAssertTrue(ReminderOffset.allCases.contains(.minutesBefore(60)))
        XCTAssertTrue(ReminderOffset.allCases.contains(.minutesBefore(120)))
        XCTAssertEqual(ReminderOffset.minutesBefore(60).label, "1 hour before")
        XCTAssertEqual(ReminderOffset.minutesBefore(120).label, "2 hours before")
        XCTAssertEqual(ReminderOffset.daysBefore(7).label, "1 week before")
    }

    func testCalendarDatabaseCodableRoundTrips() throws {
        let database = TestData.database(
            events: [
                TestData.event(
                    recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday], end: .never)
                )
            ]
        )

        let data = try JSONEncoder().encode(database)
        let decoded = try JSONDecoder().decode(LocalCalendarDatabase.self, from: data)

        XCTAssertEqual(decoded, database)
    }
}
