import Foundation

/// Spec 2.2's "mutation processor" pipeline stage: "With no provider it validates, applies the
/// idempotency check, marks `applied`, and prunes." There is nothing to synchronize remotely in
/// Phase 2, so processing a `pending` outbox row never re-touches `events`/`calendars` — those
/// tables were already updated synchronously by the `EventMutationUseCases` call that enqueued
/// the row. This only ever mutates the outbox row's own status.
///
/// The per-row decision (`decide`) is a pure, synchronous function so it can run inline inside
/// `LaunchRecovery`, which must stay synchronous — see that file's doc comment for why. The
/// `reconcile(repository:...)` entry point drives it over a whole outbox in one repository
/// round trip; `MutationProcessorActor` below wraps the same call for a caller that wants it
/// run off the main thread independently of launch.
enum MutationProcessor {
    enum ValidationResult {
        case valid
        /// A transient failure worth retrying — nothing in Phase 2 actually produces one (no
        /// provider to fail against), so this only ever comes from an injected `validate`
        /// closure, which is how `MutationProcessorTests` drives the backoff schedule
        /// deterministically without a real failure source.
        case retryableFailure
    }

    enum Decision {
        /// The row is done — either genuinely applied, or retired by the resurrection guard.
        case retired(PendingMutation)
        case retry(PendingMutation)
        /// Spec 2.12: the retry ceiling passed. A `.failed` mutation must never be dropped
        /// without user-visible or diagnostic-visible notice, which is exactly why this stays
        /// a status on the row rather than deleting it — `Summary.failed`/the row itself is
        /// what a future diagnostics surface (M7) reads.
        case failed(PendingMutation)
        /// Not `.pending`/`.inFlight`, or `.inFlight` with a `nextRetryAt` still in the future
        /// — left untouched.
        case notDue

        var updatedMutation: PendingMutation? {
            switch self {
            case .retired(let mutation), .retry(let mutation), .failed(let mutation): mutation
            case .notDue: nil
            }
        }
    }

    struct Summary: Equatable {
        var retired = 0
        var retried = 0
        var failed = 0
    }

    /// Decides what should happen to one outbox row right now. Pure: takes the database
    /// snapshot it needs to decide against rather than reading anything itself.
    static func decide(
        _ mutation: PendingMutation,
        in database: LocalCalendarDatabase,
        now: Date,
        jitter: () -> Double = { Double.random(in: 0..<1) },
        validate: (PendingMutation, LocalCalendarDatabase) -> ValidationResult = { _, _ in .valid }
    ) -> Decision {
        guard mutation.status == .pending || mutation.status == .inFlight else { return .notDue }
        if let nextRetryAt = mutation.nextRetryAt, nextRetryAt > now { return .notDue }

        // Spec 2.13/BC-ENG-006: belt-and-suspenders alongside the guard in
        // `EventMutationUseCases` — a create/update outbox row for an entity that now carries
        // a live tombstone is retired rather than ever being considered "applied to a
        // provider" (once one exists). The delete that produced the tombstone always wins.
        if mutation.operation != .delete, database.deletedEventTombstones.contains(where: { $0.entityID == mutation.objectID }) {
            var retired = mutation
            retired.status = .applied
            retired.lastAttemptAt = now
            return .retired(retired)
        }

        switch validate(mutation, database) {
        case .valid:
            var applied = mutation
            applied.status = .applied
            applied.lastAttemptAt = now
            applied.nextRetryAt = nil
            return .retired(applied)

        case .retryableFailure:
            var attempted = mutation
            attempted.attemptCount += 1
            attempted.lastAttemptAt = now

            if let nextRetryAt = RetryPolicy.nextRetryDate(attemptCount: attempted.attemptCount, firstAttemptAt: mutation.createdAt, now: now, jitter: jitter) {
                attempted.status = .inFlight
                attempted.nextRetryAt = nextRetryAt
                return .retry(attempted)
            } else {
                attempted.status = .failed
                attempted.nextRetryAt = nil
                return .failed(attempted)
            }
        }
    }

    /// Runs `decide` over every eligible outbox row and persists every change in one
    /// transaction. Synchronous by design — `LaunchRecovery` calls this directly.
    @discardableResult
    static func reconcile(
        repository: LocalCalendarRepository,
        now: Date = .now,
        jitter: @escaping () -> Double = { Double.random(in: 0..<1) },
        validate: (PendingMutation, LocalCalendarDatabase) -> ValidationResult = { _, _ in .valid }
    ) throws -> Summary {
        let database = try repository.load()
        var updates: [PendingMutation] = []
        var summary = Summary()

        for mutation in database.pendingMutations {
            let decision = decide(mutation, in: database, now: now, jitter: jitter, validate: validate)
            guard let updated = decision.updatedMutation else { continue }
            updates.append(updated)

            switch decision {
            case .retired: summary.retired += 1
            case .retry: summary.retried += 1
            case .failed: summary.failed += 1
            case .notDue: break
            }
        }

        guard !updates.isEmpty else { return summary }
        try repository.apply(EngineTransaction(outboxRows: updates))
        return summary
    }
}

/// Off-main-thread entry point for `MutationProcessor.reconcile`, for a caller that wants the
/// outbox drained as an independent background task rather than inline during launch recovery.
/// `LaunchRecovery` does not use this — see its doc comment for why launch stays synchronous.
actor MutationProcessorActor {
    private let repository: LocalCalendarRepository

    init(repository: LocalCalendarRepository) {
        self.repository = repository
    }

    @discardableResult
    func reconcile(now: Date = .now) throws -> MutationProcessor.Summary {
        try MutationProcessor.reconcile(repository: repository, now: now)
    }
}
