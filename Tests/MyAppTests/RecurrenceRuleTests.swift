import XCTest
@testable import Better_Calendar

final class RecurrenceRuleTests: XCTestCase {
    func testNeverSummaryIsStable() {
        XCTAssertEqual(RecurrenceRule.never.summary, "Never")
    }

    func testWeeklySummarySortsWeekdaysAndIncludesOccurrenceEnd() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            interval: 2,
            weekdays: [.friday, .monday, .wednesday],
            end: .afterOccurrences(5)
        )

        XCTAssertEqual(rule.summary, "Every 2 weeks on Mon, Wed, Fri, ends after 5 occurrences")
    }

    // BC-REC-011
    func testSummaryDescribesLastFridayPositionalRule() {
        let rule = RecurrenceRule(
            frequency: .monthly,
            interval: 1,
            weekdays: [.friday],
            setPositions: [-1],
            end: .never
        )

        XCTAssertEqual(rule.summary, "Monthly on the last Fri")
    }

    // BC-REC-011
    func testSummaryDescribesExplicitDayOfMonth() {
        let rule = RecurrenceRule(
            frequency: .monthly,
            interval: 1,
            weekdays: [],
            daysOfMonth: [15],
            end: .never
        )

        XCTAssertEqual(rule.summary, "Monthly on the 15th")
    }

    // BC-REC-011
    func testRecurrenceRuleWithDaysOfMonthAndSetPositionsCodableRoundTrips() throws {
        let rule = RecurrenceRule(
            frequency: .monthly,
            interval: 1,
            weekdays: [.tuesday],
            daysOfMonth: [],
            setPositions: [2],
            end: .never
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)

        XCTAssertEqual(decoded, rule)
    }

    // BC-REC-011
    func testLegacyRecurrenceRuleJSONWithoutDaysOfMonthOrSetPositionsDecodesToEmptyArrays() throws {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        let encoded = try JSONEncoder().encode(rule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "daysOfMonth")
        object.removeValue(forKey: "setPositions")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: legacyData)

        XCTAssertEqual(decoded.daysOfMonth, [])
        XCTAssertEqual(decoded.setPositions, [])
        XCTAssertEqual(decoded.weekdays, [.monday])
    }

    func testRecurrenceRuleCodableRoundTrips() throws {
        let rule = RecurrenceRule(
            frequency: .monthly,
            interval: 3,
            weekdays: [.tuesday],
            end: .onDate(TestData.date("2026-12-01T00:00:00Z"))
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)

        XCTAssertEqual(decoded, rule)
    }
}
