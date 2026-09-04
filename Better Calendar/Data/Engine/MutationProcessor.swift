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

        // MARK: - Phase 3D

        /// **No provider has answered yet.** The row is left exactly as it is — not retired, not
        /// retried, not failed — and waits for a pass that can actually reach the device.
        ///
        /// This is the case spec 3D.1 exists for. See `defaultValidation`.
        case deferred
        /// Spec 3.21: refused for a reason retrying cannot fix. Parked without spending an
        /// attempt (spec 3D.6).
        case permissionFailure
        /// Spec 3.21: the calendar is gone, the event is gone, or the provider rejected the
        /// data. Fails now rather than retrying against a wall — but is never dropped.
        case permanentFailure
        /// Spec 3.21/3.25: the device event changed underneath this mutation. Routed to Phase
        /// 3E, never to retry.
        case conflictDetected
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
        /// Spec 3D.1: this row needs a provider round trip and this pass cannot make one, so it
        /// is left alone. Distinct from `.notDue`, which means "not yet"; this means "not by
        /// me". Both write nothing, and the distinction exists so a diagnostics summary can tell
        /// a queue that is waiting for its moment from one that is waiting for a writer.
        case deferred
        /// Spec 3D.6: parked on a permission failure, with its retry budget intact.
        case parked(PendingMutation)
        /// Spec 3.25: a concurrent external change. Phase 3E resolves it; nothing was written.
        case conflicted(PendingMutation)

        var updatedMutation: PendingMutation? {
            switch self {
            case .retired(let mutation), .retry(let mutation), .failed(let mutation),
                 .parked(let mutation), .conflicted(let mutation):
                mutation
            case .notDue, .deferred:
                nil
            }
        }
    }

    struct Summary: Equatable {
        var retired = 0
        var retried = 0
        var failed = 0
        var deferred = 0
        var parked = 0
        var conflicted = 0
    }

    /// Decides what should happen to one outbox row right now. Pure: takes the database
    /// snapshot it needs to decide against rather than reading anything itself.
    static func decide(
        _ mutation: PendingMutation,
        in database: LocalCalendarDatabase,
        now: Date,
        jitter: () -> Double = { Double.random(in: 0..<1) },
        validate: (PendingMutation, LocalCalendarDatabase) -> ValidationResult = defaultValidation
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

        case .deferred:
            return .deferred

        case .retryableFailure:
            var attempted = mutation
            attempted.attemptCount += 1
            attempted.lastAttemptAt = now
            attempted.failureClass = .transient
            attempted.lastFailureAt = now

            if let nextRetryAt = RetryPolicy.nextRetryDate(attemptCount: attempted.attemptCount, firstAttemptAt: mutation.createdAt, now: now, jitter: jitter) {
                attempted.status = .inFlight
                attempted.nextRetryAt = nextRetryAt
                return .retry(attempted)
            } else {
                attempted.status = .failed
                attempted.nextRetryAt = nil
                return .failed(attempted)
            }

        case .permissionFailure:
            // Spec 3D.6: `attemptCount` is deliberately *not* incremented. The mutation was
            // never really attempted — the provider refused to be asked — and spending the
            // 24-hour retry window on a permission the user has not granted is how a week of
            // denied access silently destroys a queue of edits.
            var parked = mutation
            parked.status = .parked
            parked.nextRetryAt = nil
            parked.failureClass = .permission
            parked.lastFailureAt = now
            return .parked(parked)

        case .permanentFailure:
            // Retrying against a deleted calendar or a rejected payload only burns the window.
            // The row still stops at `.failed` rather than being deleted: spec 2.12's rule that
            // silent data loss is the one failure this pipeline exists to eliminate does not
            // soften because the provider was definite.
            var failed = mutation
            failed.status = .failed
            failed.attemptCount += 1
            failed.lastAttemptAt = now
            failed.nextRetryAt = nil
            failed.failureClass = .permanent
            failed.lastFailureAt = now
            return .failed(failed)

        case .conflictDetected:
            var conflicted = mutation
            conflicted.status = .conflicted
            conflicted.lastAttemptAt = now
            conflicted.nextRetryAt = nil
            conflicted.failureClass = .conflict
            conflicted.lastFailureAt = now
            return .conflicted(conflicted)
        }
    }

    // MARK: - Spec 3D.1: the rule that keeps this pass honest

    /// The validator used when a caller supplies none — which is every Phase 1/2 call site, and
    /// `LaunchRecovery`.
    ///
    /// Through Phase 3C this was `{ _, _ in .valid }`: with no provider attached, "processing" an
    /// outbox row meant marking it applied, because the local tables had already been updated
    /// synchronously by the use case that enqueued it. That was correct while every calendar was
    /// local. It stopped being correct the moment Phase 3B let the user pick a **writable device
    /// calendar** as a destination: a create on their iCloud calendar would be marked `applied`
    /// on the next launch, having never reached EventKit — the event present here, absent there,
    /// and the outbox claiming it synced.
    ///
    /// So the default now defers anything bound for a device calendar. The row stays `pending`
    /// and waits for a pass that can actually write. A pass that cannot reach the provider says
    /// nothing about the row rather than lying about it, which is the property that has to hold
    /// before an adapter is worth attaching.
    static func defaultValidation(_ mutation: PendingMutation, in database: LocalCalendarDatabase) -> ValidationResult {
        targetsDeviceCalendar(mutation, in: database) ? .deferred : .valid
    }

    /// Which calendar this mutation ultimately writes to, and whether that calendar is reached
    /// through the device.
    ///
    /// A delete is the awkward case: by the time its row is processed the event is gone from
    /// `events`, so the calendar has to come from the payload the outbox captured, and failing
    /// that from the tombstone's snapshot. Both are written in the same transaction as the
    /// delete itself (spec 2.13), so one of them is always there for a row this app enqueued.
    static func targetsDeviceCalendar(_ mutation: PendingMutation, in database: LocalCalendarDatabase) -> Bool {
        guard let calendarID = targetCalendarID(of: mutation, in: database) else {
            // Spec 3B/3C: a calendar mutation on a mirrored row enqueues no outbox entry, and an
            // event whose calendar cannot be determined at all is not one this app can write to
            // a provider. Treating the unknown case as local preserves every Phase 1/2 path
            // exactly; the device case is the one that has to be positively identified.
            return false
        }
        return database.calendars.first { $0.id == calendarID }?.connectionMethod == .device
    }

    private static func targetCalendarID(of mutation: PendingMutation, in database: LocalCalendarDatabase) -> UUID? {
        guard mutation.objectType == .event else { return nil }

        if let event = database.events.first(where: { $0.id == mutation.objectID }) {
            return event.calendarID
        }
        if let payload = mutation.payload, let decoded = CalendarEvent(snapshotJSON: payload) {
            return decoded.calendarID
        }
        return database.deletedEventTombstones
            .first { $0.entityID == mutation.objectID }
            .flatMap { $0.eventSnapshotJSON }
            .flatMap(CalendarEvent.init(snapshotJSON:))?
            .calendarID
    }

    /// Runs `decide` over every eligible outbox row and persists every change in one
    /// transaction. Synchronous by design — `LaunchRecovery` calls this directly.
    @discardableResult
    static func reconcile(
        repository: LocalCalendarRepository,
        now: Date = .now,
        jitter: @escaping () -> Double = { Double.random(in: 0..<1) },
        validate: (PendingMutation, LocalCalendarDatabase) -> ValidationResult = defaultValidation
    ) throws -> Summary {
        let database = try repository.load()
        var updates: [PendingMutation] = []
        var summary = Summary()

        for mutation in database.pendingMutations {
            let decision = decide(mutation, in: database, now: now, jitter: jitter, validate: validate)

            switch decision {
            case .retired: summary.retired += 1
            case .retry: summary.retried += 1
            case .failed: summary.failed += 1
            case .parked: summary.parked += 1
            case .conflicted: summary.conflicted += 1
            case .deferred: summary.deferred += 1
            case .notDue: break
            }

            guard let updated = decision.updatedMutation else { continue }
            updates.append(updated)
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
