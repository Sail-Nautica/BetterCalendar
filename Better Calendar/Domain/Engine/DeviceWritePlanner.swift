import Foundation

/// Spec 3D.2, phase 1: which due outbox rows need a device round trip, and what each one asks
/// the device to do.
///
/// Pure, so the decision about *what to write* is a deterministic unit test with no device — the
/// same discipline `DeviceCalendarMirror` and `DeviceEventMirror` follow. The I/O is
/// `DeviceMutationAdapter`'s, and the status changes are `DeviceWriteCommitter`'s; neither of
/// those has to re-derive anything this decided.
enum DeviceWritePlanner {

    /// One outbox row, resolved into a device operation.
    struct PlannedWrite: Equatable {
        var mutationID: UUID
        /// The local event row this mutation is about. `nil` is impossible for a planned write —
        /// a row whose event cannot be resolved is not planned at all.
        var eventID: UUID
        var operation: Operation
        /// Spec 3.22: the device version the local edit was based on, carried so the adapter can
        /// notice a change that arrived underneath it.
        var baseProviderVersion: String?
        /// Spec 3.19: the payload the crash-idempotency search matches against, present only
        /// when this create might already have happened. See `Operation.create`.
        var adoptionCandidate: CalendarEvent?
        /// Spec 3.22: the event **as it was when this edit was made**, in the device's shape.
        ///
        /// Not the same as the local row, and that difference is the whole point: the local row
        /// already contains the edit, so comparing the device against it would find every field
        /// this mutation is about to change and call all of them conflicts. This is the state the
        /// edit was based on, taken from the `EventVersion` snapshot Phase 2 wrote when the edit
        /// superseded it. `nil` when there is no snapshot — an update whose base is unknown is
        /// treated conservatively; see `DeviceMutationAdapter`.
        var baseEvent: DeviceEvent?

        enum Operation: Equatable {
            /// `mightAlreadyExist` is true when the row was left `.inFlight` by an earlier pass —
            /// that is, when this app issued a write and did not live to record the receipt.
            /// Spec 3.19's adoption search runs only then, because a fetch per create would cost
            /// every user for a case that happens to almost none of them.
            case create(DeviceEventWrite, mightAlreadyExist: Bool)
            case update(DeviceEventWrite)
            case delete(identifier: String, span: DeviceEventSpan)
        }
    }

    /// Rows that are due, target a device calendar, and can be resolved into an operation.
    ///
    /// A row this returns is one the adapter will attempt. A row it *skips* is left exactly as it
    /// is — `MutationProcessor`'s default validator will defer it again on the next pass, which
    /// is the conservative outcome and never a claim that anything was written.
    static func plan(
        database: LocalCalendarDatabase,
        fieldDiffs: [UUID: String] = [:],
        baseSnapshots: [UUID: String] = [:],
        now: Date
    ) -> [PlannedWrite] {
        let calendarsByID = Dictionary(database.calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return database.pendingMutations.compactMap { mutation -> PlannedWrite? in
            guard mutation.status == .pending || mutation.status == .inFlight else { return nil }
            if let nextRetryAt = mutation.nextRetryAt, nextRetryAt > now { return nil }
            guard mutation.objectType == .event else { return nil }

            // The resurrection guard, ahead of any I/O: a create or update for an entity that
            // now has a live tombstone must not be sent to the device at all. `MutationProcessor`
            // retires it locally; issuing the write first would put back what the user deleted.
            if mutation.operation != .delete,
               database.deletedEventTombstones.contains(where: { $0.entityID == mutation.objectID }) {
                return nil
            }

            switch mutation.operation {
            case .create, .update:
                guard let event = database.events.first(where: { $0.id == mutation.objectID }),
                      let calendar = calendarsByID[event.calendarID],
                      calendar.connectionMethod == .device,
                      let calendarIdentifier = calendar.providerCalendarID else {
                    return nil
                }
                return plannedWrite(for: mutation, event: event, calendarIdentifier: calendarIdentifier, fieldDiffs: fieldDiffs, baseSnapshots: baseSnapshots)

            case .delete:
                // The event row is gone by now, so both the identifier and the calendar come
                // from what the delete captured — the payload, then the tombstone snapshot.
                guard let snapshot = deletedEventSnapshot(for: mutation, in: database),
                      let calendar = calendarsByID[snapshot.calendarID],
                      calendar.connectionMethod == .device,
                      let identifier = snapshot.providerMetadata.providerObjectID else {
                    return nil
                }
                return PlannedWrite(
                    mutationID: mutation.id,
                    eventID: mutation.objectID,
                    // Spec 3.20: deleting a whole series addresses the master with the
                    // this-event span, which is how EventKit expresses a series-wide change.
                    operation: .delete(identifier: identifier, span: .thisEvent),
                    baseProviderVersion: mutation.baseProviderVersion
                )
            }
        }
    }

    private static func plannedWrite(
        for mutation: PendingMutation,
        event: CalendarEvent,
        calendarIdentifier: String,
        fieldDiffs: [UUID: String],
        baseSnapshots: [UUID: String]
    ) -> PlannedWrite? {
        let deviceEvent = DeviceEventMapper.deviceEvent(for: event, calendarIdentifier: calendarIdentifier)

        // A row is a create until the device has named the event, whatever the outbox says. An
        // update whose event carries no provider identifier has never landed — treating it as an
        // update would address `nil` and fail permanently, losing the edit.
        guard let identifier = event.providerMetadata.providerObjectID, !identifier.isEmpty else {
            return PlannedWrite(
                mutationID: mutation.id,
                eventID: event.id,
                operation: .create(
                    DeviceEventWrite(
                        identifier: nil,
                        calendarIdentifier: calendarIdentifier,
                        span: .thisEvent,
                        event: deviceEvent,
                        // A create has no prior state to patch against: everything is new.
                        fields: DeviceEventField.all
                    ),
                    mightAlreadyExist: mutation.status == .inFlight
                ),
                baseProviderVersion: nil,
                adoptionCandidate: event
            )
        }

        let fields = patchFields(for: mutation, fieldDiffs: fieldDiffs)
        guard !fields.isEmpty else {
            // The edit touched nothing the device models — a local-only field, or a journal entry
            // with no diff. There is nothing to write, and issuing an empty save would bump the
            // device's last-modified for no reason and make the next mirror pass think something
            // changed.
            return nil
        }

        return PlannedWrite(
            mutationID: mutation.id,
            eventID: event.id,
            operation: .update(
                DeviceEventWrite(
                    identifier: identifier,
                    calendarIdentifier: calendarIdentifier,
                    span: .thisEvent,
                    event: deviceEvent,
                    fields: fields
                )
            ),
            baseProviderVersion: mutation.baseProviderVersion ?? event.providerMetadata.providerVersion,
            baseEvent: baseEvent(for: mutation, calendarIdentifier: calendarIdentifier, baseSnapshots: baseSnapshots)
        )
    }

    private static func baseEvent(for mutation: PendingMutation, calendarIdentifier: String, baseSnapshots: [UUID: String]) -> DeviceEvent? {
        guard let entryID = mutation.changeJournalEntryID,
              let snapshot = baseSnapshots[entryID],
              let previous = CalendarEvent(snapshotJSON: snapshot) else {
            return nil
        }
        return DeviceEventMapper.deviceEvent(for: previous, calendarIdentifier: calendarIdentifier)
    }

    /// Spec 3D.4: the patch set comes from the **change journal**, not from a diff computed here.
    ///
    /// The journal recorded what the user's edit actually touched, at the moment they made it.
    /// Diffing at write time would compare against whatever the local row holds now — which, by
    /// the time a queued mutation is drained, may already include a later edit or a mirror pass's
    /// own update. The journal is the only record of the *intent*.
    ///
    /// A mutation with no journal entry, or one whose entry recorded no diff, falls back to
    /// writing every modelled field. That is the pre-journal shape and it is still correct, just
    /// less surgical — and it is what an `.allEvents` scope edit produces, where the whole event
    /// genuinely is the change.
    static func patchFields(for mutation: PendingMutation, fieldDiffs: [UUID: String]) -> Set<DeviceEventField> {
        guard let entryID = mutation.changeJournalEntryID, let diff = fieldDiffs[entryID] else { return DeviceEventField.all }
        guard let data = diff.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DeviceEventField.all
        }
        return object.keys.reduce(into: Set<DeviceEventField>()) { fields, key in
            fields.formUnion(DeviceEventField.fields(forJournalKey: key))
        }
    }

    /// The journal entries `plan` will want diffs for. Read by the caller before planning, so
    /// the planner itself performs no I/O.
    static func journalEntryIDs(in database: LocalCalendarDatabase, now: Date) -> Set<UUID> {
        Set(
            database.pendingMutations
                .filter { $0.status == .pending || $0.status == .inFlight }
                .filter { $0.nextRetryAt.map { retry in retry <= now } ?? true }
                .compactMap(\.changeJournalEntryID)
        )
    }

    private static func deletedEventSnapshot(for mutation: PendingMutation, in database: LocalCalendarDatabase) -> CalendarEvent? {
        if let payload = mutation.payload, let decoded = CalendarEvent(snapshotJSON: payload) {
            return decoded
        }
        return database.deletedEventTombstones
            .first { $0.entityID == mutation.objectID }
            .flatMap { $0.eventSnapshotJSON }
            .flatMap(CalendarEvent.init(snapshotJSON:))
    }
}
