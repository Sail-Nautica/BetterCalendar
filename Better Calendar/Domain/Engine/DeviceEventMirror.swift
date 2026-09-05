import Foundation

/// Spec 3C.8: the event-mirroring pass, as a pure function — the shape `DeviceCalendarMirror`
/// established in Phase 3B, applied to events.
///
/// Takes what the device reported for a bounded window and what is already mirrored, and returns
/// the `EntityChange`s, journal entries and tombstones that reconcile them. The store applies the
/// result through the same atomic `EngineTransaction` path as a user edit, so an inbound change
/// gets the same journalling, rollback and consistency guarantees a local one does.
///
/// No I/O, no clock, no `UUID()` it does not own: `now` and every identifier are derived or
/// passed in, so all of it is a deterministic unit test with no device (BC-EK-024).
///
/// ### What this pass deliberately does not do
///
/// It does not observe `EKEventStoreChanged`, coalesce bursts, or persist a per-calendar
/// reconciliation window — that is Phase 3E, and shipping the trigger before the conflict
/// handling that makes reacting to it safe would be the wrong order. It also resolves no
/// conflicts, because until Phase 3D there is no local edit to a mirrored event that could
/// conflict with anything: the device is the only writer, so the device simply wins.
enum DeviceEventMirror {

    /// Counts, never content — the shape spec 3.24 requires of a pass's diagnostics.
    struct Summary: Equatable {
        var inserted = 0
        var updated = 0
        var deleted = 0
        var unchanged = 0
        /// Reported on a calendar this database does not mirror, so there is nowhere to put it.
        var skippedUnmirroredCalendar = 0
        /// Suppressed by a live tombstone — the resurrection guard (spec 2.13/BC-ENG-006).
        var skippedTombstoned = 0

        var isNoOp: Bool {
            inserted == 0 && updated == 0 && deleted == 0
        }
    }

    struct Plan: Equatable {
        var changes: [EntityChange] = []
        var journalEntries: [ChangeJournalEntry] = []
        var tombstones: [DeletedObjectTombstone] = []
        var summary = Summary()

        var isEmpty: Bool {
            changes.isEmpty && tombstones.isEmpty
        }

        /// The transaction the store applies. Carries **no outbox rows** — the same rule Phase
        /// 3B's discovery follows, and for the same reason: this is a change arriving *from* the
        /// device, not one to send to it. Enqueueing one here would mean Phase 3D started writing
        /// to EventKit by accident.
        var transaction: EngineTransaction {
            EngineTransaction(
                entityChanges: changes,
                journalEntries: journalEntries,
                tombstones: tombstones
            )
        }
    }

    /// Everything one pass reads. Assembled by the caller so the planner has no ambient state.
    struct Input {
        /// What the device reported, for `window` and `fetchedCalendarIDs` and nothing else.
        var devices: [DeviceEvent]
        /// The range that was actually queried. The bounded-window rule is stated against this
        /// value, so passing a window wider than the one fetched is the way to make this pass
        /// destroy data — see `deletions`.
        var window: DateInterval
        /// The **local** ids of the calendars the fetch actually covered.
        var fetchedCalendarIDs: Set<UUID>
        var calendars: [BetterCalendar]
        var existingEvents: [CalendarEvent]
        var existingExceptions: [RecurrenceException]
        var tombstones: [DeletedEventTombstone]
        /// See `DeviceEventMapper.Context.deviceTimeZoneIdentifier`.
        var deviceTimeZoneIdentifier: String

        init(
            devices: [DeviceEvent],
            window: DateInterval,
            fetchedCalendarIDs: Set<UUID>,
            calendars: [BetterCalendar],
            existingEvents: [CalendarEvent],
            existingExceptions: [RecurrenceException] = [],
            tombstones: [DeletedEventTombstone] = [],
            deviceTimeZoneIdentifier: String = TimeZone.current.identifier
        ) {
            self.devices = devices
            self.window = window
            self.fetchedCalendarIDs = fetchedCalendarIDs
            self.calendars = calendars
            self.existingEvents = existingEvents
            self.existingExceptions = existingExceptions
            self.tombstones = tombstones
            self.deviceTimeZoneIdentifier = deviceTimeZoneIdentifier
        }
    }

    /// Spec 3C.8 step 2: the calendars a pass may fetch — mirrored, shown, and still on the
    /// device.
    ///
    /// A hidden calendar is excluded from the fetch, which is also what keeps BC-EK-005 true:
    /// its events cannot be deleted by a pass that did not ask about them, so toggling a calendar
    /// off removes its events from every view without deleting them.
    static func fetchableCalendars(from calendars: [BetterCalendar]) -> [BetterCalendar] {
        calendars.filter { $0.connectionMethod == .device && $0.isVisible && !$0.isUnavailable }
    }

    /// Spec 3C.8 step 1: the window a pass covers when the caller does not name one.
    ///
    /// Phase 3C's triggers are the ones Phase 3B established — a foreground, a fresh grant, a
    /// device-calendar surface appearing — none of which knows what date range is on screen. So
    /// this is a fixed span around now rather than "the visible range plus a prefetch margin":
    /// wide enough that scrolling a month or two in either direction lands on already-mirrored
    /// events, narrow enough to meet spec 3J's cost budget on every foreground.
    ///
    /// Driving the window from the visible range — and widening it as the user scrolls past its
    /// edge — is Phase 3E's, which is also where the per-calendar reconciliation state that makes
    /// a moving window safe gets persisted.
    static let defaultWindowPast: TimeInterval = 60 * 24 * 60 * 60
    static let defaultWindowFuture: TimeInterval = 180 * 24 * 60 * 60

    static func defaultWindow(around date: Date) -> DateInterval {
        DateInterval(
            start: date.addingTimeInterval(-defaultWindowPast),
            end: date.addingTimeInterval(defaultWindowFuture)
        )
    }

    static func plan(_ input: Input, now: Date) -> Plan {
        var plan = Plan()

        let calendarsByProviderID = Dictionary(
            input.calendars
                .filter { $0.connectionMethod == .device }
                .compactMap { calendar in calendar.providerCalendarID.map { ($0, calendar) } },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByID = Dictionary(input.existingEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Spec 3D.9: identifier first, derived id second.
        //
        // Phase 3C could assume every mirrored row was named by this pass, because its local id
        // was a pure function of the provider identifier. Phase 3D breaks that assumption: an
        // event Better Calendar created and then pushed has a local id of its own — one that
        // views, undo actions and the conflict index all reference — *and* a provider identifier.
        // Matching only on the derived id would not recognise it, and the pass would insert a
        // second row for an event it already had.
        let existingByProviderID = Dictionary(
            input.existingEvents.compactMap { event in event.providerMetadata.providerObjectID.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByExternalID = Dictionary(
            input.existingEvents.compactMap { event in event.providerMetadata.providerExternalID.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )
        let exceptionsByID = Dictionary(input.existingExceptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveTombstoneEntityIDs = Set(input.tombstones.map(\.entityID))

        // Spec 3C.3: a series' master must be mirrored before its detachments, or a detachment
        // has no master to point at. Sorted rather than assumed, so the pass does not depend on
        // the order the adapter happened to return.
        let ordered = input.devices.sorted { lhs, rhs in
            lhs.isDetached == rhs.isDetached ? lhs.startDate < rhs.startDate : !lhs.isDetached
        }

        var mappedByKey: [DeviceEventKey: CalendarEvent] = [:]
        var seenIDs: Set<UUID> = []

        for device in ordered {
            guard let calendar = calendarsByProviderID[device.calendarIdentifier] else {
                // Spec 3C.2: an event whose calendar is not mirrored is skipped, not orphaned.
                plan.summary.skippedUnmirroredCalendar += 1
                continue
            }

            // A row already bound to this device event keeps its own id, whatever that id is;
            // only an event this app has never seen gets a derived one. Detachments are excluded
            // from identifier matching because a series' detachments all share the identifier —
            // the pair is their identity (spec 3C.1), and the derived id already encodes it.
            let matched: CalendarEvent?
            if device.isDetached {
                // A detachment shares its series' identifier, so it cannot be matched by one.
                // What it *can* be matched by is its slot — and a "this event only" edit made
                // here has already created a local replacement event sitting in exactly that
                // slot, waiting to be recognised as the thing the device just detached. Without
                // this the pass would add a second row beside it (spec 3D.5/3D.9).
                let masterID = DeviceEventIdentity.eventID(for: DeviceEventKey(identifier: device.identifier, occurrenceDate: nil))
                let masterLocalID = existingByProviderID[device.identifier]?.id ?? masterID
                let slot = device.occurrenceDate
                matched = input.existingEvents.first { candidate in
                    candidate.recurrenceMasterID == masterLocalID
                        && zip([candidate.recurrenceOriginalStart], [slot]).allSatisfy { local, remote in
                            guard let local, let remote else { return false }
                            return abs(local.timeIntervalSince(remote)) < 1
                        }
                }
            } else {
                matched = existingByProviderID[device.identifier]
                    ?? device.externalIdentifier.flatMap { existingByExternalID[$0] }
            }
            let localID = matched?.id ?? DeviceEventIdentity.eventID(for: device.key)

            guard !liveTombstoneEntityIDs.contains(localID) else {
                // Spec 3C.8: the resurrection guard applies to inbound changes too. The delete
                // that produced the tombstone always wins until it is purged.
                plan.summary.skippedTombstoned += 1
                continue
            }

            let existing = matched ?? existingByID[localID]
            let context = DeviceEventMapper.Context(
                calendarID: calendar.id,
                provider: calendar.provider,
                deviceTimeZoneIdentifier: input.deviceTimeZoneIdentifier,
                localID: localID,
                // Preserved, so a mirrored event's "created" date is when *we* first saw it and
                // does not jump every time the device edits it.
                createdAt: existing?.createdAt ?? now
            )

            let master = device.isDetached
                ? mappedByKey[DeviceEventKey(identifier: device.identifier, occurrenceDate: nil)]
                    ?? existingByID[DeviceEventIdentity.eventID(for: DeviceEventKey(identifier: device.identifier, occurrenceDate: nil))]
                : nil

            let mapped: CalendarEvent
            if device.isDetached, let master {
                mapped = DeviceEventMapper.mapDetachment(device, master: master, in: context, now: now)
            } else {
                // A detachment whose master this pass cannot see is mirrored as a plain event
                // rather than pointed at a master that is not there. It shows up in the right
                // place; it simply is not linked to a series until a window that includes the
                // master runs.
                mapped = DeviceEventMapper.map(device, in: context, now: now)
            }

            seenIDs.insert(localID)
            mappedByKey[device.key] = mapped
            append(mapped, existing: existing, to: &plan, now: now)

            if device.isDetached, let master {
                let exception = DeviceEventMapper.makeException(master: master, detachment: mapped)
                if exceptionsByID[exception.id] != exception {
                    plan.changes.append(.upsertRecurrenceException(exception))
                }
            }
        }

        appendDeletions(input, seenIDs: seenIDs, to: &plan, now: now)
        return plan
    }

    // MARK: - Upserts

    /// The device is authoritative for every field of a mirrored event, so the comparison is
    /// "does the mapped row differ from the stored one" rather than "is the device's
    /// last-modified newer".
    ///
    /// That choice does two things at once. It makes spec 3C.8's idempotence structural — a pass
    /// over an unchanged device maps to the identical row and writes nothing — and it makes
    /// spec 3C.1's "nothing this app does can disagree with the device" true rather than hoped
    /// for, because anything that did diverge locally is mapped back on the next pass.
    private static func append(_ mapped: CalendarEvent, existing: CalendarEvent?, to plan: inout Plan, now: Date) {
        guard let existing else {
            var inserted = mapped
            inserted.versionNumber = 1
            plan.changes.append(.upsertEvent(inserted))
            plan.journalEntries.append(
                journalEntry(entityID: inserted.id, operation: .create, fieldDiff: FieldDiff.compute(from: Optional<CalendarEvent>.none, to: inserted), now: now)
            )
            plan.summary.inserted += 1
            return
        }

        // `updatedAt` and `versionNumber` are bookkeeping this pass itself writes; comparing them
        // would make every pass look like a change and the mirror would never settle.
        var comparable = mapped
        comparable.updatedAt = existing.updatedAt
        comparable.versionNumber = existing.versionNumber
        guard comparable != existing else {
            plan.summary.unchanged += 1
            return
        }

        var committed = mapped
        committed.updatedAt = now
        committed.versionNumber = existing.versionNumber + 1
        plan.changes.append(.upsertEvent(committed))
        plan.journalEntries.append(
            journalEntry(entityID: committed.id, operation: .update, fieldDiff: FieldDiff.compute(from: existing, to: committed), now: now)
        )
        plan.summary.updated += 1
    }

    // MARK: - Deletions, and the bounded-window rule

    /// Spec 3C.8 / spec 3.24: **never infer a deletion from an event's absence outside the
    /// queried range.** This is the single most dangerous function in the phase — a window
    /// computed slightly wrong here is silent deletion of events the user still has — so it
    /// requires three independent things to be true before removing a row:
    ///
    /// 1. The row is **mirrored**: it lives on a device calendar and carries provider identity.
    ///    A Better Calendar-owned event is never this pass's business, whatever calendar it is
    ///    on.
    /// 2. Its calendar was **included in the fetch**. A deselected or unavailable calendar was
    ///    never asked about, so its absence says nothing (BC-EK-005).
    /// 3. Its own start lies **inside the fetched window**.
    ///
    /// Point 3 is deliberately the strict reading. A series that began before the window and
    /// recurs into it is reported by the fetch while it exists, so it is matched normally — but
    /// if it were deleted externally, this pass would *not* remove it, and a later pass whose
    /// window covers its start would. Erring toward a stale row that a wider window cleans up is
    /// the right direction to be wrong in; erring the other way deletes calendars.
    private static func appendDeletions(_ input: Input, seenIDs: Set<UUID>, to plan: inout Plan, now: Date) {
        let mirroredCalendarIDs = Set(
            input.calendars.filter { $0.connectionMethod == .device }.map(\.id)
        )

        for event in input.existingEvents {
            guard !seenIDs.contains(event.id) else { continue }
            guard mirroredCalendarIDs.contains(event.calendarID) else { continue }
            guard event.providerMetadata.providerObjectID != nil else { continue }
            guard input.fetchedCalendarIDs.contains(event.calendarID) else { continue }
            guard input.window.contains(event.startDate) else { continue }

            plan.changes.append(.deleteEvent(event.id))
            plan.tombstones.append(
                DeletedObjectTombstone(
                    id: DeviceEventIdentity.uuid(name: "tombstone:\(event.id.uuidString)"),
                    entityType: .event,
                    entityID: event.id,
                    title: event.title,
                    deletedAt: now,
                    // Spec 3C.8: the journal has to tell "the user deleted this here" from
                    // "it went away out there".
                    deletedBy: .providerDeletion,
                    eventSnapshotJSON: event.encodedSnapshotJSON(),
                    deletionSyncedAt: nil
                )
            )
            plan.journalEntries.append(
                journalEntry(entityID: event.id, operation: .delete, fieldDiff: FieldDiff.compute(from: event, to: Optional<CalendarEvent>.none), now: now)
            )
            plan.summary.deleted += 1
        }
    }

    // MARK: - Journal

    /// Every entry is `source: .reconciliation`, so the journal can tell what the user did from
    /// what the device told us — the same rule Phase 3B's discovery follows.
    ///
    /// The id is derived rather than random for the same reason event ids are: a pass that
    /// produced no change must produce no journal entry, and a pass that did must be replayable
    /// without minting a second entry for the same fact.
    private static func journalEntry(entityID: UUID, operation: JournalOperation, fieldDiff: String?, now: Date) -> ChangeJournalEntry {
        ChangeJournalEntry(
            id: DeviceEventIdentity.uuid(name: "journal:\(entityID.uuidString):\(operation.rawValue):\(DeviceEventMapper.providerVersionString(now))"),
            entityType: .event,
            entityID: entityID,
            operation: operation,
            fieldDiff: fieldDiff,
            source: .reconciliation,
            occurredAt: now,
            appliedMutationID: nil
        )
    }
}
