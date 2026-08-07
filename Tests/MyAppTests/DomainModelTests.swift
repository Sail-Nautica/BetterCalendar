import XCTest
@testable import MyApp

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
