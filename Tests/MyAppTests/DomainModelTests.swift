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

    // BC-EVT-010
    func testTitleAcceptsExactlyMaximumLengthAndRejectsOneCharacterMore() {
        var draft = validDraft()

        draft.title = String(repeating: "a", count: EventFieldLimits.titleCharacters)
        XCTAssertNil(draft.validationError)

        draft.title = String(repeating: "a", count: EventFieldLimits.titleCharacters + 1)
        XCTAssertEqual(draft.validationError, "Title must be 500 characters or fewer.")
    }

    // BC-EVT-010
    func testLocationAcceptsExactlyMaximumLengthAndRejectsOneCharacterMore() {
        var draft = validDraft()

        draft.location = String(repeating: "b", count: EventFieldLimits.locationCharacters)
        XCTAssertNil(draft.validationError)

        draft.location = String(repeating: "b", count: EventFieldLimits.locationCharacters + 1)
        XCTAssertEqual(draft.validationError, "Location must be 1000 characters or fewer.")
    }

    // BC-EVT-010
    func testNotesAcceptExactlyMaximumLengthAndRejectOneCharacterMore() {
        var draft = validDraft()

        draft.notes = String(repeating: "c", count: EventFieldLimits.notesCharacters)
        XCTAssertNil(draft.validationError)

        draft.notes = String(repeating: "c", count: EventFieldLimits.notesCharacters + 1)
        XCTAssertEqual(draft.validationError, "Notes must be 50000 characters or fewer.")
    }

    // BC-EVT-010
    func testOverLongFieldIsRejectedWithoutTruncatingTheUsersText() {
        var draft = validDraft()
        let overLongNotes = String(repeating: "c", count: EventFieldLimits.notesCharacters + 25)

        draft.notes = overLongNotes

        XCTAssertNotNil(draft.validationError)
        XCTAssertEqual(draft.notes.count, EventFieldLimits.notesCharacters + 25, "Validation must never silently truncate what the user typed.")
        XCTAssertEqual(draft.notes, overLongNotes)
    }

    // BC-EVT-010
    func testEmptyTitleIsReportedBeforeTitleLengthSoTheClearestErrorWins() {
        var draft = validDraft()
        draft.title = "   "

        XCTAssertEqual(draft.validationError, "Enter a title before saving.")
    }

    // BC-EVT-011
    func testAssigningIsAllDayFalseDoesNotSilentlyDestroyFloatingTimeType() {
        var event = TestData.event(timeType: .floating)

        event.isAllDay = false

        XCTAssertEqual(event.timeType, .floating, "Assigning false must not convert a floating event into a timed one.")
        XCTAssertFalse(event.isAllDay)
    }

    // BC-EVT-011
    func testIsAllDayShimStillTogglesBetweenTimedAndAllDay() {
        var event = TestData.event()
        XCTAssertEqual(event.timeType, .timed)

        event.isAllDay = true
        XCTAssertEqual(event.timeType, .allDay)

        event.isAllDay = false
        XCTAssertEqual(event.timeType, .timed)
    }

    // BC-EVT-011
    func testLegacyEventJSONCarryingIsAllDayAndNoTimeTypeStillDecodes() throws {
        let allDayEvent = TestData.event(isAllDay: true)
        let encoded = try JSONEncoder().encode(allDayEvent)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // Reshape into the pre-timeType payload written by earlier builds.
        object.removeValue(forKey: "timeType")
        object["isAllDay"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: legacyData)

        XCTAssertEqual(decoded.timeType, .allDay, "A legacy all-day event must survive the move to timeType.")
        XCTAssertEqual(decoded.id, allDayEvent.id)
        XCTAssertEqual(decoded.title, allDayEvent.title)
    }

    // BC-EVT-011
    func testLegacyEventJSONWithNeitherTimeTypeNorIsAllDayDefaultsToTimed() throws {
        let event = TestData.event()
        let encoded = try JSONEncoder().encode(event)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "timeType")
        object.removeValue(forKey: "isAllDay")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: legacyData)

        XCTAssertEqual(decoded.timeType, .timed)
    }

    private func validDraft() -> EventDraft {
        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:15:00Z"))
        draft.title = "Office Hours"
        return draft
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
