import Foundation

/// Spec 3.18–3.19 (3D.2, phase 2): the only part of the write-back path that talks to a provider.
///
/// Everything on either side of it is pure — `DeviceWritePlanner` decided what to write,
/// `DeviceWriteCommitter` decides what each result means for the outbox — so this file holds the
/// I/O and nothing else. It performs no local writes at all: a crash in the middle of a drain
/// leaves the outbox exactly as the previous transaction left it.
struct DeviceMutationAdapter {
    /// What the device said about one planned write.
    enum Outcome: Equatable {
        case applied(DeviceWriteReceipt)
        /// Spec 3.19: this create had already reached the device on an earlier attempt that
        /// crashed before recording its receipt. Adopted rather than issued again.
        case adopted(DeviceWriteReceipt)
        /// Spec 3.25: the two sides changed the same low-risk field and the device's change is
        /// the newer one. The local edit loses — and is written to `EventVersion` by the
        /// committer before it is dropped, because "never discard" has no exception for a
        /// decision the engine made on the user's behalf.
        case supersededByDevice
        case failed(DeviceWriteFailure)
    }

    let store: EventKitStore
    /// How wide a window the adoption search looks in around the event's own start. Narrow on
    /// purpose: the event this is looking for is the one *we* just tried to create, at the time
    /// we asked for. A wide window only makes a false match more likely.
    var adoptionSearchMargin: TimeInterval = 60 * 60

    /// Spec 2.15's threshold, applied to a decision that creates data. A match below this issues
    /// the create — a duplicate is recoverable and visible; adopting the wrong event silently
    /// binds the user's local row to somebody else's meeting.
    var adoptionConfidenceThreshold: Double = 0.9

    func perform(_ writes: [DeviceWritePlanner.PlannedWrite]) async -> [UUID: Outcome] {
        var outcomes: [UUID: Outcome] = [:]

        // Serial rather than concurrent. These are writes to one event store, some of them to
        // the same series, and spec 3.20's spans mean order can matter — a `futureEvents` split
        // followed by an edit to the resulting master is not the same as the reverse. Throughput
        // here is bounded by a handful of queued user edits, not by a sync.
        for write in writes {
            outcomes[write.mutationID] = await perform(write)
        }
        return outcomes
    }

    private func perform(_ planned: DeviceWritePlanner.PlannedWrite) async -> Outcome {
        do {
            switch planned.operation {
            case .create(let write, let mightAlreadyExist):
                if mightAlreadyExist, let adopted = try await adoptedReceipt(for: planned, write: write) {
                    return .adopted(adopted)
                }
                return .applied(try await store.save(write))

            case .update(let write):
                switch try await concurrencyOutcome(for: planned, write: write) {
                case .proceed:
                    return .applied(try await store.save(write))
                case .superseded:
                    return .supersededByDevice
                case .failed(let failure):
                    return .failed(failure)
                }

            case .delete(let identifier, let span):
                try await store.remove(identifier: identifier, span: span)
                // A delete has no receipt to record: there is no longer an event to name.
                return .applied(DeviceWriteReceipt(identifier: identifier, externalIdentifier: nil, lastModified: nil))
            }
        } catch {
            return .failed(DeviceWriteFailure(unclassified: error))
        }
    }

    // MARK: - Spec 3.19: idempotency across a crash

    /// A create that succeeded in EventKit but crashed before its receipt was persisted must not
    /// create a second device event on retry.
    ///
    /// The search is narrow by construction — one calendar, a window around the event's own
    /// start — and it defers to `DuplicateDetector`, which is Phase 2's existing heuristic rather
    /// than a second one written for this case. Spec 2.15's "never merge silently" still holds:
    /// this adopts only a high-confidence match, and a weaker one falls through to creating,
    /// because a visible duplicate is a better failure than a silent mis-binding.
    private func adoptedReceipt(for planned: DeviceWritePlanner.PlannedWrite, write: DeviceEventWrite) async throws -> DeviceWriteReceipt? {
        guard let candidate = planned.adoptionCandidate else { return nil }

        let window = DateInterval(
            start: candidate.startDate.addingTimeInterval(-adoptionSearchMargin),
            end: max(candidate.endDate, candidate.startDate).addingTimeInterval(adoptionSearchMargin)
        )
        let existing = try await store.events(in: window, calendarIdentifiers: [write.calendarIdentifier])
        guard !existing.isEmpty else { return nil }

        // Mapped into local terms so `DuplicateDetector` compares like with like — it is written
        // against `CalendarEvent`, and re-implementing its heuristics for `DeviceEvent` is
        // exactly the second detector spec 3.30 says not to write.
        let mapped = existing.map { device in
            DeviceEventMapper.map(
                device,
                in: DeviceEventMapper.Context(
                    calendarID: candidate.calendarID,
                    provider: candidate.providerMetadata.provider,
                    deviceTimeZoneIdentifier: candidate.timeZoneIdentifier,
                    localID: DeviceEventIdentity.eventID(for: device.key),
                    createdAt: candidate.createdAt
                ),
                now: candidate.updatedAt
            )
        }

        let matches = DuplicateDetector.candidates(for: candidate, among: mapped)
        guard let best = matches.max(by: { $0.confidence < $1.confidence }),
              best.confidence >= adoptionConfidenceThreshold,
              let device = existing.first(where: { DeviceEventIdentity.eventID(for: $0.key) == best.matchedEventID }) else {
            return nil
        }

        PrivacyLog.debug("Adopted an existing device event instead of creating a duplicate")
        return DeviceWriteReceipt(
            identifier: device.identifier,
            externalIdentifier: device.externalIdentifier,
            lastModified: device.lastModified
        )
    }

    // MARK: - Spec 3.22: optimistic concurrency

    /// Compares the device's last-modified value against the one this edit was based on, and
    /// treats a mismatch as a **signal rather than a verdict**.
    ///
    /// Last-modified granularity is coarse — whole seconds on some sources — so a bare mismatch
    /// would report a conflict every time two edits landed in the same second, including when
    /// they touched entirely different fields. So a mismatch is confirmed with a field-level
    /// comparison: if what the device changed and what this mutation changes are disjoint, it is
    /// a merge and the patch proceeds. Only an overlap is a conflict.
    enum ConcurrencyOutcome {
        case proceed
        case superseded
        case failed(DeviceWriteFailure)
    }

    private func concurrencyOutcome(for planned: DeviceWritePlanner.PlannedWrite, write: DeviceEventWrite) async throws -> ConcurrencyOutcome {
        guard let baseVersion = planned.baseProviderVersion, let identifier = write.identifier else { return .proceed }
        guard let current = try await store.event(withIdentifier: identifier) else {
            // Gone from the device. Not a conflict — there is nothing left to conflict with, and
            // retrying will not bring it back.
            return .failed(.permanent)
        }

        let currentVersion = current.lastModified.map(DeviceEventMapper.providerVersionString)
        guard currentVersion != baseVersion else { return .proceed }

        // Compared against the state this edit was **based on**, never against the state it
        // intends to produce. Comparing against the intent would find every field the mutation is
        // about to change and call all of them conflicts, which makes the merge rule unreachable
        // and turns every concurrent edit into a stall.
        guard let base = planned.baseEvent else {
            // No recorded base — a mutation enqueued before `EventVersion` history existed, or by
            // a path that writes none. The device has changed and we cannot say how, so this
            // stops rather than guessing. A conflict costs the user a decision; a wrong merge
            // costs them a field.
            return .failed(.conflict(currentProviderVersion: currentVersion))
        }

        let changedOnDevice = changedFields(between: base, and: current)
        guard !changedOnDevice.isDisjoint(with: write.fields) else {
            // Two writes within the same second that touched different fields are a merge, not a
            // conflict (spec 3.22). The patch writes only `write.fields`, so the device's own
            // change survives it.
            return .proceed
        }

        // Spec 3.25 (3E.4): the overlap is real, so classify it rather than always stopping.
        // Low-risk fields resolve on their own; time, recurrence and deletion wait for the user.
        switch ConflictResolver.resolve(
            operation: planned.mutationOperation,
            localFields: planned.localFields,
            deviceFields: changedOnDevice,
            localEditedAt: planned.localEditedAt,
            deviceModifiedAt: current.lastModified
        ) {
        case .keepLocal:
            // The local edit is the newer one. It writes, and the version it supersedes is the
            // device's own — already in the device's history, not ours to preserve.
            return .proceed
        case .keepDevice:
            return .superseded
        case .askTheUser:
            return .failed(.conflict(currentProviderVersion: currentVersion))
        }
    }

    /// Which writable fields the device changed, measured from the state this edit was based on.
    /// Only ever asked about the fields Better Calendar models — an unmodelled field cannot
    /// conflict with an edit that could not have touched it.
    private func changedFields(between intended: DeviceEvent, and current: DeviceEvent) -> Set<DeviceEventField> {
        var changed: Set<DeviceEventField> = []
        if intended.title != current.title { changed.insert(.title) }
        if intended.notes != current.notes { changed.insert(.notes) }
        if intended.location != current.location { changed.insert(.location) }
        if intended.urlString != current.urlString { changed.insert(.url) }
        if intended.startDate != current.startDate { changed.insert(.startDate) }
        if intended.endDate != current.endDate { changed.insert(.endDate) }
        if intended.isAllDay != current.isAllDay { changed.insert(.isAllDay) }
        if intended.timeZoneIdentifier != current.timeZoneIdentifier { changed.insert(.timeZone) }
        if intended.availability != current.availability { changed.insert(.availability) }
        if intended.alarms != current.alarms { changed.insert(.alarms) }
        if intended.recurrenceRules != current.recurrenceRules { changed.insert(.recurrence) }
        return changed
    }
}

extension DeviceWriteFailure {
    /// Anything the adapter did not already classify. A `DeviceWriteFailure` thrown by the store
    /// passes through with its class intact; anything else is transient, which is the safe
    /// default — a wrong `transient` costs a retry, where a wrong `permanent` throws the user's
    /// edit away.
    init(unclassified error: Error) {
        self = (error as? DeviceWriteFailure) ?? .transient
    }
}
