import Foundation

/// Spec 2.2: the unit of change that flows through the Phase 2 mutation pipeline.
///
/// One `EngineTransaction` is produced by a pure planner and then consumed *twice* — once
/// against the in-memory `LocalCalendarDatabase` via ``LocalCalendarDatabase/applying(_:)``,
/// and once against SQLite inside a single write transaction via
/// ``LocalCalendarRepository/apply(_:)``. Because both consumers read the same value, spec
/// 2.13's "a tombstone is written in the same transaction as the delete, never afterward"
/// is structurally true rather than a convention two call sites have to remember
/// independently.
///
/// This replaces the Phase 1 shape, where every mutation re-serialised the entire database
/// (`SQLiteCalendarRepository.replaceDatabase`). Whole-database replacement cannot host an
/// append-only change journal — the journal would be erased by the next save — and it
/// rewrites every row in the calendar to move one event, which spec 2.19's targets do not
/// allow.
///
/// M1 lands the type and both consumers. The planners that mint non-trivial transactions
/// (journal entries, event version rows, idempotency keys, retry status) arrive in M2, so
/// `journalEntries`/`eventVersions` are deliberately absent here: their row types do not
/// exist yet, and modelling them as empty placeholders would be worse than adding the stored
/// properties when M2 adds the types. The *tables* they write to are created by M1's
/// migrations, because schema is M1's job.
struct EngineTransaction: Equatable {
    /// Entity-level inserts, updates and deletes. Order within the array is not significant;
    /// both consumers impose their own dependency ordering (see ``orderedChanges``).
    var entityChanges: [EntityChange] = []

    /// Outbox rows enqueued by this transaction (spec 2.10).
    var outboxRows: [PendingMutation] = []

    /// Tombstones written by this transaction (spec 2.13). Always accompanies the
    /// corresponding `.deleteEvent` in `entityChanges` — that pairing is the whole reason
    /// both travel in one value.
    var tombstones: [DeletedEventTombstone] = []

    /// Tombstones retired by this transaction, either because retention expired (spec 2.13)
    /// or because the user restored the deleted event.
    var removedTombstoneIDs: [UUID] = []

    /// A settings write, when this transaction carries one. `nil` means "settings unchanged",
    /// which is distinct from "settings reset to defaults".
    var settings: AppSettings?

    static let empty = EngineTransaction()

    var isEmpty: Bool {
        entityChanges.isEmpty
            && outboxRows.isEmpty
            && tombstones.isEmpty
            && removedTombstoneIDs.isEmpty
            && settings == nil
    }

    /// `entityChanges` sorted into an order that satisfies the schema's foreign keys, so both
    /// consumers agree on the outcome of a transaction that touches related rows.
    ///
    /// Upserts run parent-first (a calendar before the events in it, an event before the
    /// recurrence exceptions pointing at it) and deletes run child-first, which is the
    /// reverse. Two orderings matter beyond foreign keys:
    ///
    /// * Calendar upserts that *clear* `isDefault` are applied before ones that *set* it.
    ///   `calendars_one_default_idx` is a partial unique index over `is_default = 1`, and
    ///   SQLite has no deferred unique constraints, so writing the new default before
    ///   clearing the old one would trip the index halfway through an otherwise valid
    ///   transaction.
    /// * Deletes run after upserts. A transaction that moves an event out of a calendar and
    ///   then deletes that calendar must land the move first, or the event goes down with
    ///   the cascade.
    var orderedChanges: [EntityChange] {
        var calendarUpserts: [EntityChange] = []
        var eventUpserts: [EntityChange] = []
        var exceptionUpserts: [EntityChange] = []
        var exceptionDeletes: [EntityChange] = []
        var eventDeletes: [EntityChange] = []
        var calendarDeletes: [EntityChange] = []

        for change in entityChanges {
            switch change {
            case .upsertCalendar:
                calendarUpserts.append(change)
            case .upsertEvent:
                eventUpserts.append(change)
            case .upsertRecurrenceException:
                exceptionUpserts.append(change)
            case .deleteRecurrenceException:
                exceptionDeletes.append(change)
            case .deleteEvent:
                eventDeletes.append(change)
            case .deleteCalendar:
                calendarDeletes.append(change)
            }
        }

        // Stable partition: non-default calendars first, so a default swap never leaves two
        // rows claiming `is_default = 1` at any point inside the transaction.
        var ordered: [EntityChange] = []
        for change in calendarUpserts {
            guard case .upsertCalendar(let calendar) = change, !calendar.isDefault else { continue }
            ordered.append(change)
        }
        for change in calendarUpserts {
            guard case .upsertCalendar(let calendar) = change, calendar.isDefault else { continue }
            ordered.append(change)
        }

        ordered.append(contentsOf: eventUpserts)
        ordered.append(contentsOf: exceptionUpserts)
        ordered.append(contentsOf: exceptionDeletes)
        ordered.append(contentsOf: eventDeletes)
        ordered.append(contentsOf: calendarDeletes)
        return ordered
    }
}

/// A single entity-level change. Reminders and recurrence *rules* have no cases of their own:
/// both are stored inline on `CalendarEvent` in the domain model, so `.upsertEvent` already
/// carries them and replacing an event replaces its reminder and rule rows wholesale. The
/// change journal still records them under their own ``EngineEntityType`` when a user action
/// touches only those fields — journal granularity and storage granularity are separate
/// concerns.
enum EntityChange: Equatable {
    case upsertCalendar(BetterCalendar)
    case deleteCalendar(UUID)
    case upsertEvent(CalendarEvent)
    case deleteEvent(UUID)
    case upsertRecurrenceException(RecurrenceException)
    case deleteRecurrenceException(UUID)
}

/// The entity vocabulary shared by the change journal (spec 2.8), the outbox (spec 2.10) and
/// tombstones (spec 2.13). A superset of the four types those sections name: recurrence
/// exceptions are a distinct table in this schema and need to be addressable.
enum EngineEntityType: String, Codable, Hashable, CaseIterable {
    case event
    case calendar
    case reminder
    case recurrenceRule
    case recurrenceException
}

/// Spec 2.13's `deletedBy`: why an object was deleted, which is what lets a later replay
/// distinguish a mutation that *should* be suppressed from one that is merely late.
enum TombstoneCause: String, Codable, Hashable, CaseIterable {
    case userEdit
    case recurrenceSplit
    case calendarDeletion
    case reset
}

/// Retention windows shared by the store and the repository, so the 30-day figure is stated
/// once rather than duplicated between the in-memory purge and the persisted `purge_after`
/// column that has to agree with it.
enum EngineRetentionPolicy {
    /// Spec 0.12 requires soft-deleted data to survive "a cleanup period", and spec 2.13
    /// requires it to outlast the retry window spec 2.12 caps at 24 hours. 30 days clears
    /// that bound with room to spare and matches the Phase 1 behaviour it replaces.
    static let tombstoneRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    static func purgeDate(forTombstoneDeletedAt deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(tombstoneRetentionInterval)
    }
}

extension LocalCalendarDatabase {
    /// The in-memory half of applying a transaction — pure, total, and the exact counterpart
    /// of what `SQLiteCalendarRepository.apply(_:)` does to SQLite.
    ///
    /// The flat-file and stub repositories implement `apply(_:)` as
    /// `save(database.applying(transaction))`, which is what lets every Phase 1 test keep
    /// passing unmodified against the new protocol method.
    func applying(_ transaction: EngineTransaction) -> LocalCalendarDatabase {
        var result = self

        for change in transaction.orderedChanges {
            switch change {
            case .upsertCalendar(let calendar):
                if let index = result.calendars.firstIndex(where: { $0.id == calendar.id }) {
                    result.calendars[index] = calendar
                } else {
                    result.calendars.append(calendar)
                }

            case .deleteCalendar(let id):
                result.calendars.removeAll { $0.id == id }
                // Mirrors `ON DELETE CASCADE` on `events.calendar_id`, and that cascade's own
                // knock-on cascade into `event_recurrence_exceptions.master_event_id`.
                let orphanedEventIDs = Set(result.events.filter { $0.calendarID == id }.map(\.id))
                result.events.removeAll { orphanedEventIDs.contains($0.id) }
                result.recurrenceExceptions.removeAll { orphanedEventIDs.contains($0.masterEventID) }
                for index in result.recurrenceExceptions.indices
                where result.recurrenceExceptions[index].replacementEventID.map(orphanedEventIDs.contains) == true {
                    result.recurrenceExceptions[index].replacementEventID = nil
                }

            case .upsertEvent(let event):
                if let index = result.events.firstIndex(where: { $0.id == event.id }) {
                    result.events[index] = event
                } else {
                    result.events.append(event)
                }

            case .deleteEvent(let id):
                result.events.removeAll { $0.id == id }
                result.recurrenceExceptions.removeAll { $0.masterEventID == id }
                // Mirrors `ON DELETE SET NULL` on `event_recurrence_exceptions.replacement_event_id`:
                // deleting the replacement leaves the occurrence excepted, not restored.
                for index in result.recurrenceExceptions.indices
                where result.recurrenceExceptions[index].replacementEventID == id {
                    result.recurrenceExceptions[index].replacementEventID = nil
                }

            case .upsertRecurrenceException(let exception):
                if let index = result.recurrenceExceptions.firstIndex(where: { $0.id == exception.id }) {
                    result.recurrenceExceptions[index] = exception
                } else {
                    result.recurrenceExceptions.append(exception)
                }

            case .deleteRecurrenceException(let id):
                result.recurrenceExceptions.removeAll { $0.id == id }
            }
        }

        for mutation in transaction.outboxRows {
            if let index = result.pendingMutations.firstIndex(where: { $0.id == mutation.id }) {
                result.pendingMutations[index] = mutation
            } else {
                result.pendingMutations.append(mutation)
            }
        }

        for tombstone in transaction.tombstones {
            if let index = result.deletedEventTombstones.firstIndex(where: { $0.id == tombstone.id }) {
                result.deletedEventTombstones[index] = tombstone
            } else {
                result.deletedEventTombstones.append(tombstone)
            }
        }

        if !transaction.removedTombstoneIDs.isEmpty {
            let removed = Set(transaction.removedTombstoneIDs)
            result.deletedEventTombstones.removeAll { removed.contains($0.id) }
        }

        if let settings = transaction.settings {
            result.settings = settings
        }

        // The store keeps `events` in start-date order and every screen reads it that way.
        // Sorting here means an event whose time changed lands in the same position whether
        // the caller re-read from SQLite or applied the transaction in memory.
        result.events.sort { $0.startDate < $1.startDate }

        return result
    }
}
