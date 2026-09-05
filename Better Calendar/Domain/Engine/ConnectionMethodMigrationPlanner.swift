import Foundation

/// Spec 3.29 (3F.5): moving a calendar's events from one connection to another.
///
/// **Nothing in Phase 3 calls this.** There is no second transport to migrate to until Phase 5
/// adds one. It ships tested because spec 3.29 asks for the path to be designed now rather than
/// improvised later: "changing it is a **migration**, not a toggle: re-key mirrored events to the
/// new transport's identifiers rather than deleting and re-importing."
///
/// The distinction is not pedantic. Delete-and-re-import loses every local id, and with it every
/// undo action holding one, every `ConflictIndex` entry keyed by one, and the identity every
/// `EventVersion` row points at. A re-key keeps them.
enum ConnectionMethodMigrationPlanner {

    struct Summary: Equatable {
        /// Events that exist on both sides: the winner's row is kept, the loser's retired.
        var merged = 0
        /// Events only the losing connection had: moved across, id and all.
        var moved = 0
    }

    struct Plan: Equatable {
        var transaction: EngineTransaction = .empty
        var summary = Summary()

        var isEmpty: Bool { transaction.isEmpty }
    }

    /// - Parameters:
    ///   - losing: the calendar whose connection the user has switched away from.
    ///   - winning: the calendar whose connection they chose.
    ///   - events: every event in the database; both calendars' rows are picked out here.
    static func plan(
        losing: BetterCalendar,
        winning: BetterCalendar,
        events: [CalendarEvent],
        now: Date
    ) -> Plan {
        var plan = Plan()
        guard losing.id != winning.id else { return plan }

        let losingEvents = events.filter { $0.calendarID == losing.id }
        let winningEvents = events.filter { $0.calendarID == winning.id }
        guard !losingEvents.isEmpty else { return plan }

        var changes: [EntityChange] = []
        var tombstones: [DeletedObjectTombstone] = []
        var journalEntries: [ChangeJournalEntry] = []

        for event in losingEvents {
            // The same identifier match `DuplicateDetector` uses for a transport change — the
            // account-level id survives the move even though the local one does not (spec 3.30).
            let match = DuplicateDetector.candidates(for: event, among: winningEvents)
                .max { $0.confidence < $1.confidence }

            if match != nil {
                // Both sides have it. The winner's row stays — it is the one already carrying the
                // chosen connection's identifiers — and the loser's is retired.
                changes.append(.deleteEvent(event.id))
                tombstones.append(
                    DeletedObjectTombstone(
                        id: UUID(),
                        entityType: .event,
                        entityID: event.id,
                        title: event.title,
                        deletedAt: now,
                        // Not a user edit and not a provider deletion: the event is still on the
                        // user's calendar, reached a different way.
                        deletedBy: .reset,
                        eventSnapshotJSON: event.encodedSnapshotJSON(),
                        deletionSyncedAt: nil
                    )
                )
                journalEntries.append(entry(for: event.id, operation: .delete, now: now))
                plan.summary.merged += 1
                continue
            }

            // Only the losing connection had it, so it moves rather than being recreated. The
            // local id survives, which is the whole point: everything referencing it still works.
            var moved = event
            moved.calendarID = winning.id
            // Its provider identity belonged to the old transport and means nothing to the new
            // one. Cleared rather than carried, so the next mirror pass treats it as an event to
            // push rather than as one it already has under a foreign identifier.
            moved.providerMetadata.providerObjectID = nil
            moved.providerMetadata.providerExternalID = nil
            moved.providerMetadata.providerVersion = nil
            moved.providerMetadata.syncStatus = .pendingCreate
            moved.updatedAt = now
            moved.versionNumber = event.versionNumber + 1

            changes.append(.upsertEvent(moved))
            journalEntries.append(entry(for: event.id, operation: .update, now: now))
            plan.summary.moved += 1
        }

        plan.transaction = EngineTransaction(
            entityChanges: changes,
            journalEntries: journalEntries,
            tombstones: tombstones
        )
        return plan
    }

    private static func entry(for eventID: UUID, operation: JournalOperation, now: Date) -> ChangeJournalEntry {
        ChangeJournalEntry(
            id: UUID(),
            entityType: .event,
            entityID: eventID,
            operation: operation,
            fieldDiff: nil,
            // The user chose a connection; the engine moved the data. Not a `userEdit`, which
            // would make Undo offer to reverse one event of a whole-calendar migration.
            source: .migration,
            occurredAt: now,
            appliedMutationID: nil
        )
    }
}
