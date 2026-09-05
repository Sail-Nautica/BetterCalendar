import Foundation

/// Spec 3D.2, phase 3: what each device answer means for the outbox and for the local row.
///
/// Pure, and it produces **one** `EngineTransaction`. That single-transaction property is the
/// whole point of the type: spec 3.18 requires the receipt be written "in the same transaction
/// that marks the mutation applied", because a crash between those two writes is precisely the
/// state that produces a duplicate device event on the next attempt.
enum DeviceWriteCommitter {

    struct Summary: Equatable {
        var applied = 0
        var adopted = 0
        var retried = 0
        var parked = 0
        var failed = 0
        var conflicted = 0

        var isNoOp: Bool {
            applied == 0 && adopted == 0 && retried == 0 && parked == 0 && failed == 0 && conflicted == 0
        }
    }

    struct Result {
        var transaction: EngineTransaction
        var summary = Summary()
    }

    /// Spec 3D.3: the local row is marked `.inFlight` *before* any device write is issued.
    ///
    /// That marker is the only way a later pass can tell "this create has never been attempted"
    /// from "this create may already have landed and we crashed before recording it" — the two
    /// look identical on a `pending` row, and treating the second as the first is how a duplicate
    /// device event gets made. One cheap local write buys the distinction; the alternative is a
    /// device fetch before every create.
    static func markInFlight(_ writes: [DeviceWritePlanner.PlannedWrite], in database: LocalCalendarDatabase, now: Date) -> EngineTransaction {
        let plannedIDs = Set(writes.map(\.mutationID))
        let rows = database.pendingMutations
            .filter { plannedIDs.contains($0.id) && $0.status != .inFlight }
            .map { mutation -> PendingMutation in
                var updated = mutation
                updated.status = .inFlight
                updated.lastAttemptAt = now
                return updated
            }

        return rows.isEmpty ? .empty : EngineTransaction(outboxRows: rows)
    }

    /// One transaction carrying every status change and every receipt.
    static func commit(
        _ writes: [DeviceWritePlanner.PlannedWrite],
        outcomes: [UUID: DeviceMutationAdapter.Outcome],
        in database: LocalCalendarDatabase,
        now: Date,
        jitter: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) -> Result {
        var result = Result(transaction: .empty)
        var outboxRows: [PendingMutation] = []
        var entityChanges: [EntityChange] = []
        var tombstones: [DeletedObjectTombstone] = []

        for planned in writes {
            guard let outcome = outcomes[planned.mutationID],
                  let mutation = database.pendingMutations.first(where: { $0.id == planned.mutationID }) else {
                continue
            }

            // The status transition is `MutationProcessor`'s to make, not this type's. Feeding
            // the provider's answer through the same `decide` that handles every local mutation
            // is what keeps one retry policy, one resurrection guard and one set of rules —
            // rather than a second state machine that has to be kept in agreement with the first.
            let decision = MutationProcessor.decide(
                mutation,
                in: database,
                now: now,
                jitter: jitter,
                validate: { _, _ in validationResult(for: outcome) }
            )
            if let updated = decision.updatedMutation {
                outboxRows.append(updated)
            }

            switch decision {
            case .retired: outcome.isAdoption ? (result.summary.adopted += 1) : (result.summary.applied += 1)
            case .retry: result.summary.retried += 1
            case .parked: result.summary.parked += 1
            case .failed: result.summary.failed += 1
            case .conflicted: result.summary.conflicted += 1
            case .notDue, .deferred: break
            }

            // A receipt is only written for a successful create or update. A failure leaves the
            // local row untouched: the edit is still there, still queued, still the user's.
            guard let receipt = outcome.receipt, !planned.isDelete else {
                if planned.isDelete, outcome.receipt != nil {
                    // Spec 3.26: the tombstone records that the deletion actually reached the
                    // provider, so a later pass can tell "deleted here and pushed" from "deleted
                    // here and still queued".
                    if let tombstone = database.deletedEventTombstones.first(where: { $0.entityID == planned.eventID }) {
                        var synced = tombstone
                        synced.deletionSyncedAt = now
                        tombstones.append(synced)
                    }
                }
                continue
            }

            guard let event = database.events.first(where: { $0.id == planned.eventID }) else { continue }
            entityChanges.append(.upsertEvent(applying(receipt, to: event, now: now)))
        }

        result.transaction = EngineTransaction(
            entityChanges: entityChanges,
            outboxRows: outboxRows,
            tombstones: tombstones
        )
        return result
    }

    /// Spec 3.19: the device's identity, written onto the local row.
    ///
    /// The local id is deliberately **not** changed. A Better Calendar-created event already has
    /// one that views, undo actions and the conflict index all reference, and re-keying it on
    /// receipt would invalidate every one of them — so the row keeps its id and gains the
    /// provider's, which is what spec 3D.9 then teaches the mirror to match on.
    ///
    /// `versionNumber` is not bumped either: this is not a user edit, and bumping it would make
    /// an in-flight optimistic-concurrency check on the user's *next* edit fail against a change
    /// they did not make.
    static func applying(_ receipt: DeviceWriteReceipt, to event: CalendarEvent, now: Date) -> CalendarEvent {
        var updated = event
        updated.providerMetadata.providerObjectID = receipt.identifier
        if let externalIdentifier = receipt.externalIdentifier {
            updated.providerMetadata.providerExternalID = externalIdentifier
        }
        if let lastModified = receipt.lastModified {
            updated.providerMetadata.providerVersion = DeviceEventMapper.providerVersionString(lastModified)
        }
        updated.providerMetadata.syncStatus = .synced
        updated.updatedAt = now
        return updated
    }

    private static func validationResult(for outcome: DeviceMutationAdapter.Outcome) -> MutationProcessor.ValidationResult {
        switch outcome {
        case .applied, .adopted:
            return .valid
        case .failed(let failure):
            switch failure {
            case .transient: return .retryableFailure
            case .permission: return .permissionFailure
            case .permanent: return .permanentFailure
            case .conflict: return .conflictDetected
            }
        }
    }
}

private extension DeviceMutationAdapter.Outcome {
    var receipt: DeviceWriteReceipt? {
        switch self {
        case .applied(let receipt), .adopted(let receipt): receipt
        case .failed: nil
        }
    }

    var isAdoption: Bool {
        if case .adopted = self { return true }
        return false
    }
}

private extension DeviceWritePlanner.PlannedWrite {
    var isDelete: Bool {
        if case .delete = operation { return true }
        return false
    }
}
