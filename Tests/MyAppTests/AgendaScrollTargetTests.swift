import XCTest
@testable import Better_Calendar

/// BC-VIEW-011 (spec 1.9): the agenda omits days that have no occurrences, so "jump to today"
/// cannot assume a section keyed to the start of today exists.
final class AgendaScrollTargetTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = TestData.date("2026-08-17T09:30:00Z")

    func testAnchorsOnTodaysSectionWhenTodayHasEvents() {
        let sections = [
            TestData.date("2026-08-15T00:00:00Z"),
            TestData.date("2026-08-17T00:00:00Z"),
            TestData.date("2026-08-19T00:00:00Z")
        ]

        XCTAssertEqual(
            AgendaScrollTarget.todayAnchor(in: sections, now: now, calendar: calendar),
            TestData.date("2026-08-17T00:00:00Z"),
            "A section starting earlier today still counts as today."
        )
    }

    func testAnchorsOnNextUpcomingSectionWhenTodayIsEmpty() {
        let sections = [
            TestData.date("2026-08-15T00:00:00Z"),
            TestData.date("2026-08-19T00:00:00Z"),
            TestData.date("2026-08-21T00:00:00Z")
        ]

        XCTAssertEqual(
            AgendaScrollTarget.todayAnchor(in: sections, now: now, calendar: calendar),
            TestData.date("2026-08-19T00:00:00Z"),
            "With no events today the closest honest landing spot is the next day that has some."
        )
    }

    func testAnchorsOnLastSectionWhenEverythingIsInThePast() {
        let sections = [
            TestData.date("2026-08-10T00:00:00Z"),
            TestData.date("2026-08-12T00:00:00Z"),
            TestData.date("2026-08-15T00:00:00Z")
        ]

        XCTAssertEqual(
            AgendaScrollTarget.todayAnchor(in: sections, now: now, calendar: calendar),
            TestData.date("2026-08-15T00:00:00Z"),
            "An all-past agenda should scroll to its end rather than refuse to move."
        )
    }

    func testReturnsNilWhenThereAreNoSections() {
        XCTAssertNil(AgendaScrollTarget.todayAnchor(in: [], now: now, calendar: calendar))
    }
}
