import XCTest
@testable import Better_Calendar

/// Spec 2.12: exponential backoff with jitter, bounded by a 24-hour ceiling. `jitter` is fixed
/// at `0.5` throughout (jitter factor `0.8 + 0.5 * 0.4 == 1.0`) so the schedule is exact rather
/// than a range assertion.
final class RetryPolicyTests: XCTestCase {
    private let midpointJitter: () -> Double = { 0.5 }

    func testFirstRetryUsesTheThirtySecondBaseDelay() {
        let now = TestData.date("2026-09-01T00:00:00Z")
        let result = RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: now, now: now, jitter: midpointJitter)
        XCTAssertEqual(result, now.addingTimeInterval(30))
    }

    func testDelayDoublesWithEachAttempt() {
        let now = TestData.date("2026-09-01T00:00:00Z")
        let firstRetry = RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: now, now: now, jitter: midpointJitter)
        let secondRetry = RetryPolicy.nextRetryDate(attemptCount: 2, firstAttemptAt: now, now: now, jitter: midpointJitter)
        let thirdRetry = RetryPolicy.nextRetryDate(attemptCount: 3, firstAttemptAt: now, now: now, jitter: midpointJitter)

        XCTAssertEqual(firstRetry, now.addingTimeInterval(30))
        XCTAssertEqual(secondRetry, now.addingTimeInterval(60))
        XCTAssertEqual(thirdRetry, now.addingTimeInterval(120))
    }

    func testDelayIsCappedAtOneHourNoMatterHowManyAttempts() {
        let now = TestData.date("2026-09-01T00:00:00Z")
        let manyAttempts = RetryPolicy.nextRetryDate(attemptCount: 12, firstAttemptAt: now, now: now, jitter: midpointJitter)
        XCTAssertEqual(manyAttempts, now.addingTimeInterval(60 * 60))
    }

    func testJitterScalesTheDelayWithinPlusOrMinusTwentyPercent() {
        let now = TestData.date("2026-09-01T00:00:00Z")
        let minJitter = RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: now, now: now, jitter: { 0 })
        let maxJitter = RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: now, now: now, jitter: { 0.999999 })

        XCTAssertEqual(minJitter?.timeIntervalSince(now) ?? -1, 24, accuracy: 0.01) // 30 * 0.8
        XCTAssertEqual(maxJitter?.timeIntervalSince(now) ?? -1, 36, accuracy: 0.01) // 30 * 1.2
    }

    func testReturnsNilOncePastTheTwentyFourHourCeiling() {
        let firstAttemptAt = TestData.date("2026-09-01T00:00:00Z")
        let now = firstAttemptAt.addingTimeInterval(24 * 60 * 60) // exactly at the deadline

        XCTAssertNil(RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: firstAttemptAt, now: now, jitter: midpointJitter))
    }

    func testStillRetriesOneSecondBeforeTheCeiling() {
        let firstAttemptAt = TestData.date("2026-09-01T00:00:00Z")
        let now = firstAttemptAt.addingTimeInterval(24 * 60 * 60 - 1)

        XCTAssertNotNil(RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: firstAttemptAt, now: now, jitter: midpointJitter))
    }

    /// A computed delay that would land past the ceiling is clamped to the ceiling itself
    /// rather than overshooting it — the caller only cares whether the result is still
    /// "before the deadline," and a retry scheduled a few seconds early is harmless.
    func testAComputedDelayPastTheDeadlineIsClampedToTheDeadline() {
        let firstAttemptAt = TestData.date("2026-09-01T00:00:00Z")
        let deadline = firstAttemptAt.addingTimeInterval(24 * 60 * 60)
        let now = deadline.addingTimeInterval(-10) // 10s before the deadline; a 30s delay would overshoot it

        let result = RetryPolicy.nextRetryDate(attemptCount: 1, firstAttemptAt: firstAttemptAt, now: now, jitter: midpointJitter)
        XCTAssertEqual(result, deadline)
    }
}
