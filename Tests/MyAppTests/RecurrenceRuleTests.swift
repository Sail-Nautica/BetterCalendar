import XCTest
@testable import MyApp

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
