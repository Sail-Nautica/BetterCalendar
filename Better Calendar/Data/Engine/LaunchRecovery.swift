import Foundation

/// Spec 2.18's ten-step launch sequence, replacing the body of `BetterCalendarStore.load()`.
///
/// Steps 1 (open) and 3 (migrate) already happen as a side effect of
/// `SQLiteCalendarRepository.openDatabase()`, which every repository call in this file goes
/// through — there is nothing left to trigger for those two here. Step 5 (recover incomplete
/// imports) is a documented no-op: `commitImport` has been one atomic `EngineTransaction` since
/// M2, so a crash mid-import either leaves nothing committed (the GRDB write transaction rolls
/// back) or everything committed — there is no partial-import state this schema can represent.
/// Steps 8-10 (reconcile notifications, refresh the environment, load only the visible range)
/// stay `BetterCalendarStore`'s own job: the store already does the first two on every `load()`
/// call, and the third is true by construction — this architecture never eagerly expands
/// recurrence, so there is no "more than the visible range" to accidentally load.
///
/// `run(repository:now:)` is deliberately synchronous, not `async`. `BetterCalendarStore.load()`
/// runs from `init`, which nothing in this codebase awaits — making launch asynchronous would
/// mean the app's first frame renders with no data while a background task catches up, which
/// spec 2.0's "Phase 2 must be invisible to end users except through improved reliability"
/// rules out. `MutationProcessor`'s decision logic is written as a pure, synchronous function
/// for exactly this reason; `MutationProcessorActor` wraps it for an independent background-
/// drain caller, not for this path.
enum LaunchRecovery {
    struct Outcome {
        /// The database to load into the store.
        var database: LocalCalendarDatabase
        /// `repository.load()` itself failed and `database` is `.seed` — the pre-existing
        /// Phase 0/1 fallback behavior, now surfaced through this type instead of a `do/catch`
        /// in the store.
        var usedFallbackSeed: Bool
        /// Spec 2.18 step 2. `nil` for a repository with no schema-metadata concept — the JSON
        /// and stub repositories used in tests.
        var schemaStatus: SQLiteCalendarRepository.SchemaMetadataStatus?
        /// Spec 2.18 step 4. `nil` for the same reason as `schemaStatus`.
        var integrityCheckPassed: Bool?
        var outboxSummary: MutationProcessor.Summary
        var purgedTombstoneCount: Int
        var wroteRecoveryJournalEntry: Bool

        /// Spec 2.18: "If integrity check fails, the app must offer export-then-reset rather
        /// than silently discarding data." This flags that condition; the export-then-reset
        /// affordance itself is a Settings/diagnostics UI concern out of scope for the engine
        /// milestones ("Phase 2 adds no screens") — `BetterCalendarStore.lastError` surfaces it
        /// today, matching how every other load failure already surfaces to the user.
        var needsRecoveryPrompt: Bool {
            switch schemaStatus {
            case .checksumMismatch, .ahead:
                return true
            default:
                return integrityCheckPassed == false
            }
        }
    }

    /// A stand-in entity id for journal entries that describe the whole database rather than
    /// one row — recovery events, specifically. `ChangeJournalEntry.entityID` has no "none"
    /// case, and adding a nullable variant for the sake of one caller would be a bigger change
    /// than a documented sentinel.
    static let databaseWideEntityID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func run(repository: LocalCalendarRepository, now: Date = .now) -> Outcome {
        let sqliteRepository = repository as? SQLiteCalendarRepository

        // Step 2: verify schema metadata before anything else touches the file, so a tampered-
        // with or partially-migrated database is detected rather than silently trusted. Step 3
        // (the migration itself) already ran as a side effect of every repository call above
        // reaching `openDatabase()` — there is nothing to trigger separately here.
        let schemaStatus = try? sqliteRepository?.schemaMetadataStatus()

        // Step 4.
        let integrityCheckPassed = try? sqliteRepository?.integrityCheckPassed()

        // Step 6.
        let outboxSummary = (try? MutationProcessor.reconcile(repository: repository, now: now)) ?? MutationProcessor.Summary()

        // Step 7.
        let purgedTombstoneCount = (try? pruneExpiredTombstones(repository: repository, now: now)) ?? 0

        let loadedDatabase = try? repository.load()
        let database = loadedDatabase ?? .seed

        let schemaIsNotable: Bool
        switch schemaStatus {
        case .checksumMismatch, .ahead: schemaIsNotable = true
        default: schemaIsNotable = false
        }
        let wroteRecoveryEntry = schemaIsNotable
            || integrityCheckPassed == false
            || outboxSummary.retried > 0
            || outboxSummary.failed > 0
            || purgedTombstoneCount > 0

        if wroteRecoveryEntry {
            writeRecoveryJournalEntry(
                repository: repository,
                now: now,
                schemaStatus: schemaStatus,
                integrityCheckPassed: integrityCheckPassed,
                outboxSummary: outboxSummary,
                purgedTombstoneCount: purgedTombstoneCount
            )
        }

        return Outcome(
            database: database,
            usedFallbackSeed: loadedDatabase == nil,
            schemaStatus: schemaStatus,
            integrityCheckPassed: integrityCheckPassed,
            outboxSummary: outboxSummary,
            purgedTombstoneCount: purgedTombstoneCount,
            wroteRecoveryJournalEntry: wroteRecoveryEntry
        )
    }

    private static func pruneExpiredTombstones(repository: LocalCalendarRepository, now: Date) throws -> Int {
        let database = try repository.load()
        let expiredIDs = database.deletedEventTombstones.filter { $0.purgeAfter <= now }.map(\.id)
        guard !expiredIDs.isEmpty else { return 0 }
        try repository.apply(EngineTransaction(removedTombstoneIDs: expiredIDs))
        return expiredIDs.count
    }

    private static func writeRecoveryJournalEntry(
        repository: LocalCalendarRepository,
        now: Date,
        schemaStatus: SQLiteCalendarRepository.SchemaMetadataStatus?,
        integrityCheckPassed: Bool?,
        outboxSummary: MutationProcessor.Summary,
        purgedTombstoneCount: Int
    ) {
        var summary: [String: Any] = [
            "outboxRetried": outboxSummary.retried,
            "outboxFailed": outboxSummary.failed,
            "purgedTombstones": purgedTombstoneCount
        ]
        if let schemaStatus { summary["schemaStatus"] = String(describing: schemaStatus) }
        if let integrityCheckPassed { summary["integrityCheckPassed"] = integrityCheckPassed }
        let fieldDiff = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }

        let entry = ChangeJournalEntry(
            id: UUID(),
            entityType: .event,
            entityID: databaseWideEntityID,
            operation: .update,
            fieldDiff: fieldDiff,
            source: .recovery,
            occurredAt: now,
            appliedMutationID: nil
        )
        try? repository.apply(EngineTransaction(journalEntries: [entry]))
    }
}
