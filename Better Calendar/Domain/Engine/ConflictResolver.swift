import Foundation

/// Spec 3.25 (3E.4): what to do when the same event changed here and on the device at once.
///
/// Phase 3D leaves a conflicted mutation carrying everything a decision needs — the local edit in
/// the outbox payload, the fields it touched in the change journal's `FieldDiff`, and the state it
/// was based on in `EventVersion`. This is the policy that reads them, and it is pure: no I/O, no
/// clock it does not own, so every rule is a deterministic test.
///
/// A row only reaches `.conflicted` when the two sides **overlap** — Phase 3D merges disjoint
/// edits without asking (ADR 0009, Decision 4). So everything here is about what to do when both
/// sides changed the same thing.
enum ConflictResolver {

    /// Spec 3.25's split between what can be decided and what must be asked.
    ///
    /// The line is drawn at reversibility, not at importance. A title resolved the wrong way is
    /// retyped in seconds and the losing version is in history either way; a time resolved the
    /// wrong way sends someone to a meeting that moved, and no amount of preserved history gets
    /// them back that hour.
    static let lowRiskFields: Set<DeviceEventField> = [.title, .notes, .location, .url]

    enum Resolution: Equatable {
        /// Every overlapping field is low-risk and the local edit is the newer one: re-base it on
        /// what the device holds now and let it be written.
        case keepLocal
        /// Every overlapping field is low-risk and the device's change is newer: the local edit
        /// loses — but is written to `EventVersion` first, because spec 3.25's "never discard"
        /// has no exception for a decision the engine made on the user's behalf.
        case keepDevice
        /// Spec 3.25: time, recurrence, availability, or a deletion. Both versions are preserved
        /// and the mutation waits in `SRC-STAT-01` until the user answers.
        case askTheUser(reason: Reason)

        enum Reason: String, Equatable {
            case time
            case recurrence
            case availability
            case deletion
            /// The engine cannot tell what the local edit changed — no journal entry, or no
            /// recorded base to compare against. Asking is the conservative answer: a resolution
            /// made from an unknown starting point is a guess wearing a decision's clothes.
            case unknown
        }
    }

    /// What the local edit and the device changed, and therefore what to do.
    ///
    /// - Parameters:
    ///   - localFields: the fields the user's edit touched, from the change journal.
    ///   - deviceFields: the fields the device changed since the edit's base, from the adapter's
    ///     own comparison.
    ///   - localEditedAt: when the local edit was made (its journal entry's timestamp).
    ///   - deviceModifiedAt: the device event's last-modified value.
    static func resolve(
        operation: MutationOperation,
        localFields: Set<DeviceEventField>,
        deviceFields: Set<DeviceEventField>,
        localEditedAt: Date?,
        deviceModifiedAt: Date?
    ) -> Resolution {
        // Spec 3.25: deleting something somebody else just changed is the case where guessing
        // wrong is least recoverable, whatever fields they changed.
        guard operation != .delete else { return .askTheUser(reason: .deletion) }

        let overlap = localFields.intersection(deviceFields)
        guard !overlap.isEmpty else {
            // Phase 3D would have merged this. Reaching here means the classification inputs
            // disagree with what produced the conflict, and a resolution built on inputs that do
            // not add up is not one to make automatically.
            return .askTheUser(reason: .unknown)
        }

        if let reason = highRiskReason(in: overlap) {
            return .askTheUser(reason: reason)
        }

        // Every overlapping field is low-risk: newest write wins (spec 3.25). "Newest" compares
        // two recorded timestamps; neither is inferred, and if either is missing there is no
        // ordering to appeal to.
        guard let localEditedAt, let deviceModifiedAt else {
            return .askTheUser(reason: .unknown)
        }
        return localEditedAt > deviceModifiedAt ? .keepLocal : .keepDevice
    }

    private static func highRiskReason(in overlap: Set<DeviceEventField>) -> Resolution.Reason? {
        if !overlap.isDisjoint(with: [.startDate, .endDate, .isAllDay, .timeZone]) { return .time }
        if overlap.contains(.recurrence) { return .recurrence }
        if overlap.contains(.availability) { return .availability }
        // Anything not named low-risk is treated as high-risk. A field added later is asked about
        // rather than silently decided, which is the direction to be wrong in.
        return overlap.isSubset(of: lowRiskFields) ? nil : .unknown
    }
}
