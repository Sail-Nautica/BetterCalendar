import Foundation

/// Spec 2.12: exponential backoff with jitter for retryable outbox mutations, bounded by a
/// ceiling after which a mutation stops retrying and surfaces as `.failed` rather than retrying
/// forever silently. Pure and deterministic given an injected `jitter` source, so
/// `MutationProcessor` (which owns the actual retry/fail state transition) can be tested without
/// real delays or real randomness.
enum RetryPolicy {
    /// The 24-hour ceiling spec 2.12 names as an example bound. Measured from the mutation's
    /// *first* attempt, not its most recent one — a mutation retried every few minutes for a
    /// day should fail, not retry indefinitely because each individual gap was small.
    static let maximumRetryWindow: TimeInterval = 24 * 60 * 60

    /// The starting delay before the first retry.
    private static let baseDelay: TimeInterval = 30

    /// The delay never grows past this, no matter how many attempts have failed — otherwise a
    /// mutation enqueued early in the window could compute a single delay longer than the
    /// window itself.
    private static let maximumSingleDelay: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - attemptCount: the attempt number this delay is *for* (1 = the delay before the first
    ///     retry, after the initial attempt failed once).
    ///   - firstAttemptAt: when the mutation was first attempted — the anchor the 24-hour
    ///     ceiling is measured from.
    ///   - now: the current time, so the computed date is relative to when this is called
    ///     rather than to `firstAttemptAt`.
    ///   - jitter: a source of randomness in `[0, 1)`. Production uses `Double.random(in:)`;
    ///     tests pass a fixed value for a deterministic schedule.
    /// - Returns: the next retry date, or `nil` once `firstAttemptAt + maximumRetryWindow` has
    ///   passed — the caller's signal to mark the mutation `.failed`.
    static func nextRetryDate(
        attemptCount: Int,
        firstAttemptAt: Date,
        now: Date,
        jitter: () -> Double = { Double.random(in: 0..<1) }
    ) -> Date? {
        let deadline = firstAttemptAt.addingTimeInterval(maximumRetryWindow)
        guard now < deadline else { return nil }

        // 30s, 60s, 120s, 240s, ... capped at an hour. `attemptCount` is clamped before the
        // exponent so a very large count can't overflow `pow`.
        let exponent = min(max(attemptCount - 1, 0), 20)
        let uncappedDelay = baseDelay * pow(2, Double(exponent))
        let exponentialDelay = min(uncappedDelay, maximumSingleDelay)

        // ±20% jitter so a burst of mutations that fail at the same instant don't all retry in
        // the same instant too.
        let jitterFactor = 0.8 + (jitter() * 0.4)
        let delay = exponentialDelay * jitterFactor

        return min(now.addingTimeInterval(delay), deadline)
    }
}
