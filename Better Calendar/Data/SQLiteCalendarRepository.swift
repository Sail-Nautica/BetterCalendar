import Foundation
import GRDB

struct SQLiteCalendarRepository: LocalCalendarRepository {
    static let databaseFileName = "BetterCalendar.sqlite"
    static let migrationIdentifiers = [
        "v001_create_calendars",
        "v002_create_events",
        "v003_create_reminders",
        "v004_create_recurrence",
        "v005_create_search_index",
        "v006_create_event_extensions",
        "v007_create_sync_and_settings",
        "v008_add_deletion_snapshot",
        "v009_extend_search_index",
        "v010_add_raw_ics_metadata",
        "v011_create_change_journal",
        "v012_create_event_versions",
        "v013_extend_pending_mutations",
        "v014_extend_deleted_objects",
        "v015_add_version_numbers",
        "v016_add_engine_indexes",
        "v017_rebuild_search_index",
        "v018_add_calendar_provider_identity",
        "v019_add_calendar_availability",
        "v020_create_event_attendees"
    ]

    /// Spec 2.17: a checksum over the migration set, stored alongside the applied migration
    /// count so a partial or tampered-with migration history is detectable on next launch.
    ///
    /// FNV-1a rather than `Hashable`: Swift seeds `Hasher` per process, so a stored
    /// `hashValue` would mismatch on every relaunch and report corruption that isn't there.
    /// This needs to be stable across processes, OS versions and architectures, and it is a
    /// corruption tripwire rather than a security boundary, so a non-cryptographic hash with
    /// a fixed specification is the right tool.
    static func migrationChecksum(through appliedCount: Int) -> String {
        let identifiers = migrationIdentifiers.prefix(max(appliedCount, 0)).joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(identifiers.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "fnv1a64:%016llx", hash)
    }

    /// The result of comparing `schema_metadata` against the migration set this build ships.
    /// M1 records the values and exposes the comparison; spec 2.18's "halt into recovery
    /// mode" policy that consumes it is M3's launch-recovery sequence.
    enum SchemaMetadataStatus: Equatable {
        /// Stored version and checksum agree with this build's migration set.
        case consistent(appliedMigrationCount: Int)
        /// A database written by an older build, with a checksum matching that build's prefix
        /// of the migration set. Migrating forward is safe.
        case behind(appliedMigrationCount: Int)
        /// A database written by a *newer* build than this one. Downgrade is not supported.
        case ahead(appliedMigrationCount: Int)
        /// The stored checksum does not match the identifiers claimed to have been applied —
        /// a partial or rewritten migration history.
        case checksumMismatch(appliedMigrationCount: Int, storedChecksum: String?)
        /// No `schema_metadata` rows at all, i.e. a pre-v007 database.
        case missing
    }

    private let fileURLOverride: URL?
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURLOverride = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> LocalCalendarDatabase {
        let databaseQueue = try openDatabase()
        return try databaseQueue.read { db in
            let calendars = try fetchCalendars(in: db)
            guard !calendars.isEmpty else {
                return .seed
            }

            return LocalCalendarDatabase(
                schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
                calendars: calendars,
                events: try fetchEvents(in: db),
                pendingMutations: try fetchPendingMutations(in: db),
                deletedEventTombstones: try fetchDeletedEventTombstones(in: db),
                settings: try fetchSettings(in: db),
                recurrenceExceptions: try fetchRecurrenceExceptions(in: db)
            )
        }
    }

    /// Whole-database replacement. Spec 2.2 removes this from the per-mutation path — see
    /// `apply(_:)` — but it remains the right shape for the bulk operations that genuinely do
    /// rewrite everything: first-run seeding, "delete all local data", sample-data loading and
    /// the flat-file repository's own format.
    func save(_ database: LocalCalendarDatabase) throws {
        let databaseQueue = try openDatabase()
        try databaseQueue.write { db in
            try replaceDatabase(database, in: db)
        }
    }

    /// Spec 2.2: apply one transaction's worth of change, incrementally, inside a single
    /// SQLite write transaction.
    ///
    /// GRDB's `write` wraps the block in `BEGIN`/`COMMIT` and rolls back on any thrown error,
    /// so either every row in the transaction lands or none does. That is what spec 2.13's
    /// "written in the same transaction as the delete" requires, and it is why the tombstone
    /// travels inside `EngineTransaction` rather than being written by a follow-up call.
    func apply(_ transaction: EngineTransaction) throws {
        guard !transaction.isEmpty else { return }

        let databaseQueue = try openDatabase()
        try databaseQueue.write { db in
            for change in transaction.orderedChanges {
                switch change {
                case .upsertCalendar(let calendar):
                    let previousName = try String.fetchOne(
                        db,
                        sql: "SELECT name FROM calendars WHERE id = ?",
                        arguments: [calendar.id.uuidString]
                    )
                    try upsert(calendar: calendar, in: db)
                    // The FTS index denormalises the calendar name (BC-SRCH-001), so a rename
                    // has to be pushed into every row that copied it. Guarded on an actual
                    // change: `event_id` is UNINDEXED, so this predicate is a scan.
                    if let previousName, previousName != calendar.name {
                        try db.execute(
                            sql: """
                                UPDATE event_search SET calendar_name = ?
                                WHERE event_id IN (SELECT id FROM events WHERE calendar_id = ?)
                                """,
                            arguments: [calendar.name, calendar.id.uuidString]
                        )
                    }

                case .deleteCalendar(let id):
                    // `events.calendar_id` cascades, but `event_search` is an FTS5 virtual
                    // table with no foreign keys of its own — its rows have to be swept
                    // explicitly, before the cascade removes the events that identify them.
                    try db.execute(
                        sql: "DELETE FROM event_search WHERE event_id IN (SELECT id FROM events WHERE calendar_id = ?)",
                        arguments: [id.uuidString]
                    )
                    try db.execute(sql: "DELETE FROM calendars WHERE id = ?", arguments: [id.uuidString])

                case .upsertEvent(let event):
                    try upsert(event: event, in: db)
                    let calendarName = try String.fetchOne(
                        db,
                        sql: "SELECT name FROM calendars WHERE id = ?",
                        arguments: [event.calendarID.uuidString]
                    )
                    try replaceEventChildRows(for: event, calendarName: calendarName, in: db)

                case .deleteEvent(let id):
                    try db.execute(sql: "DELETE FROM event_search WHERE event_id = ?", arguments: [id.uuidString])
                    try db.execute(sql: "DELETE FROM events WHERE id = ?", arguments: [id.uuidString])

                case .upsertRecurrenceException(let exception):
                    try upsert(exception: exception, in: db)

                case .deleteRecurrenceException(let id):
                    try db.execute(sql: "DELETE FROM event_recurrence_exceptions WHERE id = ?", arguments: [id.uuidString])
                }
            }

            // Spec 2.8/2.9: journal entries before the version rows that reference them —
            // `event_versions.change_journal_entry_id` is an immediate (non-deferred) foreign
            // key, and `PRAGMA foreign_keys = ON` checks it per statement, not at commit.
            for entry in transaction.journalEntries {
                try insert(journalEntry: entry, in: db)
            }

            for version in transaction.eventVersions {
                try insert(eventVersion: version, in: db)
            }

            for mutation in transaction.outboxRows {
                try upsert(mutation: mutation, in: db)
            }

            for tombstone in transaction.tombstones {
                try upsert(tombstone: tombstone, in: db)
            }

            for tombstoneID in transaction.removedTombstoneIDs {
                try db.execute(sql: "DELETE FROM deleted_objects WHERE id = ?", arguments: [tombstoneID.uuidString])
            }

            if let settings = transaction.settings {
                try upsertSettings(settings, in: db)
            }
        }
    }

    /// Reminders, the recurrence rule and the search row are wholly owned by their event and
    /// carry no identity a caller can hold onto, so replacing an event replaces them outright
    /// rather than diffing them row by row.
    private func replaceEventChildRows(for event: CalendarEvent, calendarName: String?, in db: Database) throws {
        try db.execute(sql: "DELETE FROM event_reminders WHERE event_id = ?", arguments: [event.id.uuidString])
        try db.execute(sql: "DELETE FROM event_recurrence_rules WHERE event_id = ?", arguments: [event.id.uuidString])
        try db.execute(sql: "DELETE FROM event_search WHERE event_id = ?", arguments: [event.id.uuidString])
        // Spec 3.15: attendees are wholly owned by their event and carry no identity a caller
        // holds onto, so they are replaced outright like the reminders above. Deliberately *not*
        // indexed into `event_search`: attendee names and addresses are third-party personal
        // data, and putting them in a search index is how they end up somewhere they were never
        // meant to be.
        try db.execute(sql: "DELETE FROM event_attendees WHERE event_id = ?", arguments: [event.id.uuidString])

        for reminder in event.reminders {
            try insert(reminder: reminder, eventID: event.id, in: db)
        }

        for attendee in event.attendees {
            try insert(attendee: attendee, eventID: event.id, in: db)
        }

        if let recurrence = event.recurrence, recurrence.frequency != .never {
            try insert(recurrence: recurrence, event: event, in: db)
        }

        try insertSearchRow(for: event, calendarName: calendarName, in: db)
    }

    /// BC-SRCH-001: an indexed FTS5 prefix-per-word query across title/notes/location/calendar
    /// name/URL host — the recall step. Exact ranking is intentionally left to the caller,
    /// which already holds full event data in memory and can apply spec 1.13's precise
    /// tie-breaking rules more directly than translating them into SQL.
    func searchEventIDs(matching query: String) throws -> [UUID] {
        let ftsQuery = Self.sanitizedFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        let databaseQueue = try openDatabase()
        return try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT event_id FROM event_search WHERE event_search MATCH ?",
                arguments: [ftsQuery]
            )
            return rows.compactMap { UUID(uuidString: $0["event_id"]) }
        }
    }

    /// Turns free-text user input into an FTS5 query: each whitespace-separated token becomes
    /// a quoted prefix match, ANDed together by FTS5's default query syntax. Quoting each token
    /// as a phrase (`"token"*`) sidesteps FTS5's special-character query syntax (`-`, `:`, `(`,
    /// unbalanced `"`, etc.) — none of it is meant to be available to a calendar search box.
    static func sanitizedFTSQuery(_ query: String) -> String {
        query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    /// M7's Settings diagnostics surface (spec 2.20): reads live `change_journal`/
    /// `schema_metadata` state rather than recomputing what *this build* expects to find — the
    /// whole point is to reveal drift, not restate the build's own assumptions.
    func diagnostics() throws -> RepositoryDiagnostics {
        let databaseQueue = try openDatabase()
        return try databaseQueue.read { db in
            let journalRowCount = try db.tableExists("change_journal") ? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal") : nil

            guard try db.tableExists("schema_metadata") else {
                return RepositoryDiagnostics(changeJournalRowCount: journalRowCount, lastAppliedMigrationIdentifier: nil, migrationChecksum: nil)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM schema_metadata")
            var values: [String: String] = [:]
            for row in rows {
                values[row["key"]] = row["value"]
            }
            let appliedCount = values["schema_version"].flatMap(Int.init)
            let lastIdentifier = appliedCount.flatMap { count -> String? in
                guard count > 0, count <= Self.migrationIdentifiers.count else { return nil }
                return Self.migrationIdentifiers[count - 1]
            }

            return RepositoryDiagnostics(changeJournalRowCount: journalRowCount, lastAppliedMigrationIdentifier: lastIdentifier, migrationChecksum: values["migration_checksum"])
        }
    }

    private func openDatabase() throws -> DatabaseQueue {
        let fileURL = try databaseURL()
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let databaseQueue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(databaseQueue)

        // Spec 2.17: stamp the applied migration count and checksum after the set actually
        // ran. `migrate` is transactional per migration, so reaching this line means every
        // identifier in the list is applied.
        //
        // Read before writing. `openDatabase` runs on every repository call — including each
        // `searchEventIDs` keystroke — and an unconditional write here would put a write
        // transaction on the path of operations that only read. After the first launch on a
        // given build the stored values already agree and there is nothing to do.
        let isUpToDate = try databaseQueue.read { db in
            try Self.schemaMetadataStatus(in: db) == .consistent(appliedMigrationCount: Self.migrationIdentifiers.count)
        }
        if !isUpToDate {
            try databaseQueue.write { db in
                try Self.writeSchemaMetadata(in: db)
            }
        }

        return databaseQueue
    }

    /// Reads the stored schema metadata without migrating, for spec 2.18's launch-time
    /// verification step. Opens the file directly rather than through `openDatabase`, whose
    /// whole job is to migrate and re-stamp.
    func schemaMetadataStatus() throws -> SchemaMetadataStatus {
        let fileURL = try databaseURL()
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }

        let databaseQueue = try DatabaseQueue(path: fileURL.path)
        return try databaseQueue.read { db in
            try Self.schemaMetadataStatus(in: db)
        }
    }

    /// Spec 2.18 step 4: SQLite's own structural integrity check, run after step 3's
    /// migrations — via `openDatabase()`, so a database that still needs migrating gets that
    /// done first rather than being checked in a stale shape.
    func integrityCheckPassed() throws -> Bool {
        let databaseQueue = try openDatabase()
        return try databaseQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
        }
    }

    private func databaseURL() throws -> URL {
        if let fileURLOverride {
            return fileURLOverride
        }

        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: Self.databaseFileName)
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v001_create_calendars") { db in
            try db.execute(sql: """
                CREATE TABLE calendars (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    provider_account_id TEXT,
                    provider_calendar_id TEXT,
                    name TEXT NOT NULL,
                    color_hex TEXT NOT NULL,
                    is_visible INTEGER NOT NULL DEFAULT 1,
                    is_read_only INTEGER NOT NULL DEFAULT 0,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    time_zone_id TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX calendars_one_default_idx ON calendars(is_default) WHERE is_default = 1 AND deleted_at IS NULL")
        }

        migrator.registerMigration("v002_create_events") { db in
            try db.execute(sql: """
                CREATE TABLE events (
                    id TEXT PRIMARY KEY NOT NULL,
                    calendar_id TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    provider_object_id TEXT,
                    provider_version TEXT,
                    title TEXT NOT NULL,
                    notes TEXT,
                    location_name TEXT,
                    location_latitude REAL,
                    location_longitude REAL,
                    url TEXT,
                    event_type TEXT NOT NULL CHECK (event_type IN ('timed', 'allDay', 'floating')),
                    start_instant TEXT,
                    end_instant TEXT,
                    start_local_date TEXT,
                    end_local_date_exclusive TEXT,
                    original_timezone_id TEXT,
                    availability TEXT NOT NULL DEFAULT 'busy',
                    status TEXT NOT NULL DEFAULT 'confirmed',
                    privacy TEXT NOT NULL DEFAULT 'default',
                    color_override TEXT,
                    recurrence_master_id TEXT REFERENCES events(id) ON DELETE SET NULL,
                    recurrence_original_start TEXT,
                    is_recurrence_master INTEGER NOT NULL DEFAULT 0,
                    sync_status TEXT NOT NULL DEFAULT 'synced',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    CHECK (
                        (event_type = 'timed' AND start_instant IS NOT NULL AND end_instant IS NOT NULL AND start_local_date IS NULL AND end_local_date_exclusive IS NULL)
                        OR
                        (event_type = 'allDay' AND start_instant IS NULL AND end_instant IS NULL AND start_local_date IS NOT NULL AND end_local_date_exclusive IS NOT NULL)
                        OR
                        (event_type = 'floating')
                    )
                )
                """)
            try db.execute(sql: "CREATE INDEX events_calendar_id_idx ON events(calendar_id)")
            try db.execute(sql: "CREATE INDEX events_timed_range_idx ON events(start_instant, end_instant) WHERE event_type = 'timed'")
            try db.execute(sql: "CREATE INDEX events_all_day_range_idx ON events(start_local_date, end_local_date_exclusive) WHERE event_type = 'allDay'")
            try db.execute(sql: "CREATE INDEX events_provider_object_idx ON events(provider, provider_object_id)")
        }

        migrator.registerMigration("v003_create_reminders") { db in
            try db.execute(sql: """
                CREATE TABLE event_reminders (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    trigger_type TEXT NOT NULL CHECK (trigger_type IN ('relative', 'absolute')),
                    offset_seconds INTEGER,
                    absolute_instant TEXT,
                    delivery_method TEXT NOT NULL DEFAULT 'localNotification',
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    notification_identifier TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX event_reminders_event_id_idx ON event_reminders(event_id)")
        }

        migrator.registerMigration("v004_create_recurrence") { db in
            try db.execute(sql: """
                CREATE TABLE event_recurrence_rules (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL UNIQUE REFERENCES events(id) ON DELETE CASCADE,
                    frequency TEXT NOT NULL CHECK (frequency IN ('daily', 'weekly', 'monthly', 'yearly')),
                    interval INTEGER NOT NULL DEFAULT 1,
                    days_of_week TEXT,
                    days_of_month TEXT,
                    months_of_year TEXT,
                    week_start INTEGER NOT NULL DEFAULT 2,
                    count INTEGER,
                    until_instant TEXT,
                    until_local_date TEXT,
                    set_positions TEXT,
                    raw_rrule TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE event_recurrence_exceptions (
                    id TEXT PRIMARY KEY NOT NULL,
                    master_event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    original_occurrence_start TEXT,
                    original_occurrence_local_date TEXT,
                    exception_type TEXT NOT NULL CHECK (exception_type IN ('modified', 'cancelled')),
                    replacement_event_id TEXT REFERENCES events(id) ON DELETE SET NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX event_recurrence_exceptions_master_idx ON event_recurrence_exceptions(master_event_id)")
        }

        migrator.registerMigration("v005_create_search_index") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE event_search USING fts5(
                    event_id UNINDEXED,
                    title,
                    notes,
                    location_name
                )
                """)
        }

        migrator.registerMigration("v006_create_event_extensions") { db in
            try db.execute(sql: """
                CREATE TABLE event_attachments (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    file_name TEXT NOT NULL,
                    file_url TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE event_links (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    title TEXT,
                    url TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE event_tags (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX event_tags_event_id_idx ON event_tags(event_id)")
            try db.execute(sql: "CREATE UNIQUE INDEX event_tags_unique_name_idx ON event_tags(event_id, name)")
        }

        migrator.registerMigration("v007_create_sync_and_settings") { db in
            try db.execute(sql: """
                CREATE TABLE pending_mutations (
                    id TEXT PRIMARY KEY NOT NULL,
                    object_id TEXT NOT NULL,
                    object_type TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE deleted_objects (
                    id TEXT PRIMARY KEY NOT NULL,
                    object_id TEXT NOT NULL,
                    object_type TEXT NOT NULL,
                    title TEXT,
                    deleted_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE application_settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE schema_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(
                sql: "INSERT INTO schema_metadata (key, value, updated_at) VALUES ('schema_version', ?, ?)",
                arguments: [String(Self.migrationIdentifiers.count), encodeInstant(Date())]
            )
        }

        // Spec 0.12: a soft-deleted event must be recoverable even after a force-quit, not
        // only via the in-memory Undo closure. This stores a full JSON snapshot of the deleted
        // event alongside its tombstone, plus when the tombstone was last purge-eligible.
        migrator.registerMigration("v008_add_deletion_snapshot") { db in
            try db.execute(sql: "ALTER TABLE deleted_objects ADD COLUMN event_snapshot_json TEXT")
            try db.execute(sql: "ALTER TABLE deleted_objects ADD COLUMN deletion_synced_at TEXT")
        }

        // BC-SRCH-001, spec 1.13: index calendar name and URL host too, in addition to the
        // original title/notes/location columns. FTS5 virtual tables can't have columns added
        // in place, so this drops and recreates the (previously unqueried, so no data to lose)
        // table under the same name.
        migrator.registerMigration("v009_extend_search_index") { db in
            try db.execute(sql: "DROP TABLE event_search")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE event_search USING fts5(
                    event_id UNINDEXED,
                    title,
                    notes,
                    location_name,
                    calendar_name,
                    url_host
                )
                """)
        }

        // BC-ICS-001, spec 1.18: preserve unrecognized ICS properties from import so a later
        // export is non-destructive.
        migrator.registerMigration("v010_add_raw_ics_metadata") { db in
            try db.execute(sql: "ALTER TABLE events ADD COLUMN raw_ics_properties TEXT")
        }

        // Spec 2.8: the append-only change journal. Deliberately carries no foreign key on
        // `entity_id` — the journal has to outlive the row it describes, which is exactly the
        // case a `delete` entry records. `applied_mutation_id` links back to the outbox row
        // that carried the change once it is applied (spec 2.10), and stays NULL until then.
        migrator.registerMigration("v011_create_change_journal") { db in
            try db.execute(sql: """
                CREATE TABLE change_journal (
                    id TEXT PRIMARY KEY NOT NULL,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
                    field_diff TEXT,
                    source TEXT NOT NULL,
                    occurred_at TEXT NOT NULL,
                    applied_mutation_id TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX change_journal_entity_idx ON change_journal(entity_id, occurred_at)")
            try db.execute(sql: "CREATE INDEX change_journal_occurred_at_idx ON change_journal(occurred_at)")
        }

        // Spec 2.9: full-snapshot version history. Like the journal it has no foreign key to
        // `events` — history whose rows vanish when the event is deleted is not history. The
        // foreign key to `change_journal` is safe in the other direction precisely because
        // the journal is append-only, and it enforces spec 2.9's requirement that every
        // version row be attributable to the journal entry that produced it.
        migrator.registerMigration("v012_create_event_versions") { db in
            try db.execute(sql: """
                CREATE TABLE event_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL,
                    version_number INTEGER NOT NULL,
                    snapshot_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    change_journal_entry_id TEXT NOT NULL REFERENCES change_journal(id)
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX event_versions_event_version_idx ON event_versions(event_id, version_number)")
            try db.execute(sql: "CREATE INDEX event_versions_event_created_idx ON event_versions(event_id, created_at)")
        }

        // Spec 2.10: extend the Phase 0 outbox into a retryable, idempotent queue.
        //
        // `idempotency_key` cannot be declared UNIQUE inline: SQLite's ALTER TABLE ADD COLUMN
        // rejects UNIQUE and PRIMARY KEY constraints, so the uniqueness spec 2.11 depends on
        // is enforced by a separate unique index. Existing rows are backfilled with distinct
        // keys rather than left NULL, so the index applies to the whole table and a Phase 1
        // database that force-quit mid-mutation still has a replayable outbox.
        migrator.registerMigration("v013_extend_pending_mutations") { db in
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN payload TEXT")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN idempotency_key TEXT")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN last_attempt_at TEXT")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN next_retry_at TEXT")
            try db.execute(sql: "ALTER TABLE pending_mutations ADD COLUMN change_journal_entry_id TEXT")

            // A UUID-shaped random key per existing row. `randomblob`/`hex` is the only
            // source of uniqueness SQLite offers here; the result is not a conforming v4
            // UUID (the version and variant nibbles are random too) but it round-trips
            // through `UUID(uuidString:)`, which is all the outbox requires of it.
            try db.execute(sql: """
                UPDATE pending_mutations
                SET idempotency_key =
                    substr(hex(randomblob(4)), 1, 8) || '-' ||
                    substr(hex(randomblob(2)), 1, 4) || '-' ||
                    substr(hex(randomblob(2)), 1, 4) || '-' ||
                    substr(hex(randomblob(2)), 1, 4) || '-' ||
                    substr(hex(randomblob(6)), 1, 12)
                WHERE idempotency_key IS NULL
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX pending_mutations_idempotency_key_idx ON pending_mutations(idempotency_key)")
            try db.execute(sql: "CREATE INDEX pending_mutations_status_idx ON pending_mutations(status, next_retry_at)")
        }

        // Spec 2.13: tombstones gain a cause and an explicit purge deadline.
        //
        // `purge_after` is backfilled from `deleted_at` with `strftime` rather than left for
        // the app to compute on read, so the retention deadline is a stored fact that a
        // future purge job can index. The format string reproduces `encodeInstant`'s
        // ISO-8601-with-milliseconds shape exactly — `datetime()` would return a
        // space-separated string that `decodeInstant` cannot parse.
        migrator.registerMigration("v014_extend_deleted_objects") { db in
            try db.execute(sql: "ALTER TABLE deleted_objects ADD COLUMN deleted_by TEXT NOT NULL DEFAULT 'userEdit'")
            try db.execute(sql: "ALTER TABLE deleted_objects ADD COLUMN purge_after TEXT")

            let retentionDays = Int(EngineRetentionPolicy.tombstoneRetentionInterval / 86_400)
            try db.execute(
                sql: """
                    UPDATE deleted_objects
                    SET purge_after = strftime('%Y-%m-%dT%H:%M:%fZ', deleted_at, ?)
                    WHERE purge_after IS NULL
                    """,
                arguments: ["+\(retentionDays) days"]
            )
            try db.execute(sql: "CREATE INDEX deleted_objects_purge_after_idx ON deleted_objects(purge_after)")
        }

        // Spec 2.14: local optimistic-concurrency counters, independent of the provider
        // `provider_version`/ETag column reserved in Phase 0. Existing rows start at version
        // 1 rather than 0 so "never edited" and "edited once" are distinguishable from the
        // first update onward.
        migrator.registerMigration("v015_add_version_numbers") { db in
            try db.execute(sql: "ALTER TABLE events ADD COLUMN version_number INTEGER NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN version_number INTEGER NOT NULL DEFAULT 1")
        }

        // Spec 2.6/2.19: the covering index for the interval query conflict detection runs on
        // every create, move and resize. Phase 1's `events_timed_range_idx` is partial on
        // `event_type = 'timed'` and does not lead with `calendar_id`, so a per-calendar
        // range scan could not use it.
        migrator.registerMigration("v016_add_engine_indexes") { db in
            try db.execute(sql: "CREATE INDEX events_calendar_range_idx ON events(calendar_id, start_instant, end_instant)")
            try db.execute(sql: "CREATE INDEX events_recurrence_master_idx ON events(recurrence_master_id) WHERE recurrence_master_id IS NOT NULL")
            // Seed the metadata rows for the benefit of anything that migrates a queue
            // directly without going through `openDatabase` — the migration tests do exactly
            // that. Counted through *this* migration rather than through the whole list, so
            // that a future v017 failing and rolling back cannot leave metadata claiming it
            // succeeded.
            try Self.writeSchemaMetadata(in: db, appliedCount: Self.appliedCount(through: "v016_add_engine_indexes"))
        }

        // Repairs the search index for anyone upgrading from a pre-v009 database.
        //
        // `v009` dropped and recreated `event_search` to add two columns, on the reasoning
        // that the table had never been queried so there was nothing to lose. That was true
        // in Phase 1 for an unobvious reason: every mutation went through `replaceDatabase`,
        // which rebuilt the whole index as a side effect, so the empty table refilled itself
        // the first time the user touched anything. Spec 2.2's incremental write path removes
        // that accident, and without this migration an upgraded database would search an
        // index that is empty until each individual event happens to be edited.
        //
        // Written in Swift rather than as `INSERT ... SELECT` because `url_host` needs real
        // URL parsing to match what `insertSearchRow` stores for every subsequently-saved
        // event; an index whose rows disagree about what a column means is worse than none.
        migrator.registerMigration("v017_rebuild_search_index") { db in
            try db.execute(sql: "DELETE FROM event_search")
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id AS id, e.title AS title, e.notes AS notes,
                       e.location_name AS location_name, e.url AS url, c.name AS calendar_name
                FROM events e
                LEFT JOIN calendars c ON c.id = e.calendar_id
                WHERE e.deleted_at IS NULL
                """)

            for row in rows {
                let urlString: String? = row["url"]
                try db.execute(
                    sql: """
                        INSERT INTO event_search (event_id, title, notes, location_name, calendar_name, url_host)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row["id"] as String,
                        row["title"] as String?,
                        row["notes"] as String?,
                        row["location_name"] as String?,
                        row["calendar_name"] as String?,
                        urlString.flatMap { URL(string: $0)?.host }
                    ]
                )
            }
        }

        // Spec 3.6: the three columns the calendar record still lacked. The other five fields
        // provider identity needs — `provider`, `provider_account_id`, `provider_calendar_id`,
        // `is_read_only`, `time_zone_id` — have existed since `v001`; they were simply written
        // with hardcoded values because no provider existed to fill them. This migration adds
        // what was missing and backfills every existing row as what it actually is: a local,
        // writable, Better Calendar-owned calendar.
        //
        // `connection_method` is NOT NULL with a default so the backfill is implicit and a row
        // can never be in an "unknown transport" state — every calendar is reached exactly one
        // way, and before Phase 3 that way is always `local`.
        migrator.registerMigration("v018_add_calendar_provider_identity") { db in
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN account_name TEXT")
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN connection_method TEXT NOT NULL DEFAULT 'local'")
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN capabilities_json TEXT")

            // Repair the hardcoded values `calendarArguments` wrote before this migration:
            // `provider_calendar_id` was set to the local UUID for every row, which is correct
            // for a local calendar and is exactly what the reader now expects, so it stays.
            // `provider` is normalized defensively in case an older build wrote something else.
            try db.execute(sql: "UPDATE calendars SET provider = 'betterCalendarLocal' WHERE provider IS NULL OR provider = ''")

            // Spec 3.29 and BC-EK-020/021: the lookup the duplicate-connection rule performs on
            // every discovery pass. Partial, because local calendars have no account identity to
            // collide on and would otherwise all share one NULL bucket.
            try db.execute(sql: """
                CREATE INDEX calendars_provider_identity_idx
                ON calendars(provider, provider_account_id, provider_calendar_id)
                WHERE provider_account_id IS NOT NULL
                """)
        }

        // Spec 3B.4 / 3.8: a calendar that disappears from EventKit — account removed, calendar
        // deleted elsewhere — is marked rather than purged, so the local-only state on the row
        // (`is_visible`, `is_default`, `sort_order`) survives to be restored if it comes back.
        //
        // `is_unavailable` is NOT NULL with a default, so every existing row backfills as what
        // it is: available. `unavailable_since` is written now and read in Phase 3E, which owes
        // spec 3.26 a retention limit for hidden mirror rows and an ADR recording it — adding
        // the column here means that phase writes a policy rather than a migration.
        migrator.registerMigration("v019_add_calendar_availability") { db in
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN is_unavailable INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE calendars ADD COLUMN unavailable_since TEXT")
        }

        // Spec 3C.10. Three things Phase 3C needs and one it does not:
        //
        // - `event_attendees` (spec 3.15), a table rather than a blob, because free/busy has to
        //   ask "did the current user decline this" without decoding JSON per event.
        // - `provider_external_id`, the cross-device identifier that recognises the same event
        //   after a restore. Distinct from `provider_object_id`, which is what you pass back to
        //   fetch or save — the two answer different questions (spec 3C.1).
        // - `provider_raw_fields`, the payload spec 3.17 requires be preserved so a title-only
        //   edit cannot strip a video-call link.
        // - `has_unrepresentable_recurrence`, which makes an event the engine cannot express
        //   read-only at the model layer rather than editable-and-approximated.
        //
        // No column is added for the last-modified value spec 3L expected: `provider_version`
        // has existed since `v001` and is exactly what spec 3.12 maps `lastModified` onto.
        // `events.status` likewise already exists — it stops being hardcoded rather than being
        // added, the same shape as the `v018` calendar work.
        migrator.registerMigration("v020_create_event_attendees") { db in
            try db.execute(sql: """
                CREATE TABLE event_attendees (
                    id TEXT PRIMARY KEY NOT NULL,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    name TEXT,
                    email TEXT,
                    participation_status TEXT NOT NULL DEFAULT 'unknown',
                    role TEXT NOT NULL DEFAULT 'unknown',
                    is_organizer INTEGER NOT NULL DEFAULT 0,
                    is_current_user INTEGER NOT NULL DEFAULT 0,
                    sort_order INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE INDEX event_attendees_event_idx ON event_attendees(event_id)")

            try db.execute(sql: "ALTER TABLE events ADD COLUMN provider_external_id TEXT")
            try db.execute(sql: "ALTER TABLE events ADD COLUMN provider_raw_fields TEXT")
            try db.execute(sql: "ALTER TABLE events ADD COLUMN has_unrepresentable_recurrence INTEGER NOT NULL DEFAULT 0")

            // Partial, because every pre-Phase-3 row has no external identifier and would
            // otherwise share one NULL bucket.
            try db.execute(sql: """
                CREATE INDEX events_provider_external_idx ON events(provider_external_id)
                WHERE provider_external_id IS NOT NULL
                """)
        }

        return migrator
    }

    /// The number of migrations up to and including `identifier`.
    static func appliedCount(through identifier: String) -> Int {
        guard let index = migrationIdentifiers.firstIndex(of: identifier) else {
            return migrationIdentifiers.count
        }
        return index + 1
    }

    /// Records the applied migration count and its checksum (spec 2.17).
    ///
    /// The authoritative call site is after a successful `migrate`, not inside a migration: a
    /// checksum written once by `v016` would describe the migration set as it stood when v016
    /// shipped, and would report a false mismatch for every build that adds a v017. The
    /// stored value has to track the set actually applied, which only the caller of `migrate`
    /// knows.
    static func writeSchemaMetadata(in db: Database, appliedCount: Int = migrationIdentifiers.count) throws {
        let now = encodeInstant(Date())
        try db.execute(
            sql: "INSERT OR REPLACE INTO schema_metadata (key, value, updated_at) VALUES ('schema_version', ?, ?)",
            arguments: [String(appliedCount), now]
        )
        try db.execute(
            sql: "INSERT OR REPLACE INTO schema_metadata (key, value, updated_at) VALUES ('migration_checksum', ?, ?)",
            arguments: [migrationChecksum(through: appliedCount), now]
        )
    }

    /// Compares stored `schema_metadata` against this build's migration set (spec 2.17), for
    /// the launch-time verification spec 2.18 step 2 performs. Read-only: deciding what to do
    /// about a mismatch is the caller's business.
    static func schemaMetadataStatus(in db: Database) throws -> SchemaMetadataStatus {
        guard try db.tableExists("schema_metadata") else { return .missing }

        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM schema_metadata")
        var values: [String: String] = [:]
        for row in rows {
            values[row["key"]] = row["value"]
        }

        guard let versionString = values["schema_version"], let appliedCount = Int(versionString) else {
            return .missing
        }

        // Databases written before v016 have a `schema_version` but no checksum. That is a
        // known-good older shape, not corruption.
        guard let storedChecksum = values["migration_checksum"] else {
            return appliedCount >= migrationIdentifiers.count ? .consistent(appliedMigrationCount: appliedCount) : .behind(appliedMigrationCount: appliedCount)
        }

        guard appliedCount <= migrationIdentifiers.count else {
            return .ahead(appliedMigrationCount: appliedCount)
        }

        guard storedChecksum == migrationChecksum(through: appliedCount) else {
            return .checksumMismatch(appliedMigrationCount: appliedCount, storedChecksum: storedChecksum)
        }

        return appliedCount == migrationIdentifiers.count
            ? .consistent(appliedMigrationCount: appliedCount)
            : .behind(appliedMigrationCount: appliedCount)
    }

    /// Deletes and re-inserts every entity table.
    ///
    /// `change_journal` and `event_versions` are deliberately *not* in the sweep below. Spec
    /// 2.8 makes the journal append-only — "never mutated or deleted except by an explicit,
    /// logged retention policy" — so a bulk save must leave the history of how the database
    /// got here intact, and spec 2.9 says the same of version rows. Erasing local data on
    /// purpose is a different operation, and it belongs to M3's recovery work rather than
    /// falling out of a save.
    private func replaceDatabase(_ database: LocalCalendarDatabase, in db: Database) throws {
        try db.execute(sql: "DELETE FROM event_search")
        try db.execute(sql: "DELETE FROM event_tags")
        try db.execute(sql: "DELETE FROM event_links")
        try db.execute(sql: "DELETE FROM event_attachments")
        try db.execute(sql: "DELETE FROM event_recurrence_exceptions")
        try db.execute(sql: "DELETE FROM event_recurrence_rules")
        try db.execute(sql: "DELETE FROM event_reminders")
        try db.execute(sql: "DELETE FROM event_attendees")
        try db.execute(sql: "DELETE FROM pending_mutations")
        try db.execute(sql: "DELETE FROM deleted_objects")
        try db.execute(sql: "DELETE FROM events")
        try db.execute(sql: "DELETE FROM calendars")

        for calendar in database.calendars {
            try insert(calendar: calendar, in: db)
        }

        let calendarNamesByID = Dictionary(uniqueKeysWithValues: database.calendars.map { ($0.id, $0.name) })

        for event in database.events {
            try insert(event: event, in: db)
            try insertSearchRow(for: event, calendarName: calendarNamesByID[event.calendarID], in: db)

            for reminder in event.reminders {
                try insert(reminder: reminder, eventID: event.id, in: db)
            }

            // Spec 3.15. The incremental path (`upsert(event:)`) writes these too; both paths
            // need it, because the whole-database replacement is what `load()`, `withBulkMutation`
            // and ICS import go through — an event that round-tripped through any of those
            // would otherwise come back with its guest list silently emptied.
            for attendee in event.attendees {
                try insert(attendee: attendee, eventID: event.id, in: db)
            }

            if let recurrence = event.recurrence, recurrence.frequency != .never {
                try insert(recurrence: recurrence, event: event, in: db)
            }
        }

        for mutation in database.pendingMutations {
            try insert(mutation: mutation, in: db)
        }

        for tombstone in database.deletedEventTombstones {
            try insert(tombstone: tombstone, in: db)
        }

        for exception in database.recurrenceExceptions {
            try insert(exception: exception, in: db)
        }

        try upsertSettings(database.settings, in: db)
        try Self.writeSchemaMetadata(in: db)
    }

    // MARK: - Row writers
    //
    // Column lists and argument builders are declared once and shared by the plain-INSERT
    // (bulk replace) and UPSERT (incremental `apply`) paths. Keeping a 29-column list in two
    // hand-maintained SQL literals is precisely where a column silently stops being persisted,
    // so the SQL for both shapes is generated from the same array instead.

    private static let calendarColumns = [
        "id", "provider", "provider_account_id", "provider_calendar_id", "name", "color_hex",
        "is_visible", "is_read_only", "is_default", "time_zone_id", "sort_order",
        "created_at", "updated_at", "deleted_at", "version_number",
        "account_name", "connection_method", "capabilities_json",
        "is_unavailable", "unavailable_since"
    ]

    private static let eventColumns = [
        "id", "calendar_id", "provider", "provider_object_id", "provider_version",
        "title", "notes", "location_name", "location_latitude", "location_longitude", "url",
        "event_type", "start_instant", "end_instant", "start_local_date", "end_local_date_exclusive",
        "original_timezone_id", "availability", "status", "privacy", "color_override",
        "recurrence_master_id", "recurrence_original_start", "is_recurrence_master",
        "sync_status", "created_at", "updated_at", "deleted_at", "raw_ics_properties", "version_number",
        "provider_external_id", "provider_raw_fields", "has_unrepresentable_recurrence"
    ]

    private static func insertSQL(table: String, columns: [String]) -> String {
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
    }

    private static func upsertSQL(table: String, columns: [String]) -> String {
        let assignments = columns
            .filter { $0 != "id" }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        return "\(insertSQL(table: table, columns: columns)) ON CONFLICT(id) DO UPDATE SET \(assignments)"
    }

    /// Spec 3.6. Every value here used to be hardcoded — provider was always
    /// `betterCalendarLocal`, the account was always `nil`, `provider_calendar_id` was the local
    /// UUID again, and `is_read_only` was always `0`. The columns existed since `v001`; nothing
    /// filled them. They now carry what the domain type says.
    ///
    /// `color_hex` keeps its established meaning for local calendars — the design token's hex —
    /// and carries the provider's exact color when one is present, which is the only shape that
    /// round-trips a device calendar's arbitrary RGB. See ADR 0004.
    private func calendarArguments(_ calendar: BetterCalendar) -> StatementArguments {
        [
            calendar.id.uuidString,
            calendar.provider.databaseValue,
            calendar.providerAccountID,
            calendar.providerCalendarID ?? calendar.id.uuidString,
            calendar.name,
            calendar.colorHex ?? calendar.colorName.hexValue,
            calendar.isVisible.databaseInt,
            calendar.isReadOnly.databaseInt,
            calendar.isDefault.databaseInt,
            calendar.timeZoneIdentifier,
            calendar.sortOrder,
            encodeInstant(calendar.createdAt),
            encodeInstant(calendar.updatedAt),
            nil,
            calendar.versionNumber,
            calendar.accountName,
            calendar.connectionMethod.rawValue,
            encodeCapabilities(calendar.capabilities),
            calendar.isUnavailable.databaseInt,
            calendar.unavailableSince.map(encodeInstant)
        ]
    }

    /// Capabilities are stored as one JSON blob rather than seven columns: the set is provider-
    /// defined and will grow as adapters are added, and widening a JSON payload needs no
    /// migration while widening a column list does. `CalendarCapabilities` decodes tolerantly for
    /// exactly this reason.
    private func encodeCapabilities(_ capabilities: CalendarCapabilities) -> String? {
        guard capabilities != .localDefaults else { return nil }
        guard let data = try? JSONEncoder().encode(capabilities) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `nil` — the value every pre-`v018` row and every ordinary local calendar carries — means
    /// the permissive local defaults, so this never fails closed and never locks a user out of
    /// their own calendar because a blob failed to parse.
    private func decodeCapabilities(_ json: String?) -> CalendarCapabilities {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CalendarCapabilities.self, from: data) else {
            return .localDefaults
        }
        return decoded
    }

    private func insert(calendar: BetterCalendar, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "calendars", columns: Self.calendarColumns),
            arguments: calendarArguments(calendar)
        )
    }

    private func upsert(calendar: BetterCalendar, in db: Database) throws {
        try db.execute(
            sql: Self.upsertSQL(table: "calendars", columns: Self.calendarColumns),
            arguments: calendarArguments(calendar)
        )
    }

    private func eventArguments(_ event: CalendarEvent) -> StatementArguments {
        let isAllDay = event.isAllDay
        // Floating events persist instants exactly like timed events; the schema's compound
        // CHECK places no column requirements on the floating branch, so no migration is needed.
        let eventType = event.timeType.rawValue
        let startInstant = isAllDay ? nil : encodeInstant(event.startDate)
        let endInstant = isAllDay ? nil : encodeInstant(event.endDate)
        let startLocalDate = isAllDay ? localDateString(for: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil
        let endLocalDateExclusive = isAllDay ? localDateString(for: event.endDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil

        return [
            event.id.uuidString,
            event.calendarID.uuidString,
            event.providerMetadata.provider.databaseValue,
            event.providerMetadata.providerObjectID,
            event.providerMetadata.providerVersion,
            event.title,
            event.notes,
            event.location,
            nil,
            nil,
            event.urlString,
            eventType,
            startInstant,
            endInstant,
            startLocalDate,
            endLocalDateExclusive,
            event.timeZoneIdentifier,
            event.availability.rawValue,
            // Spec 3C.2: hardcoded `'confirmed'` on every write since `v001`. It now carries
            // what the provider actually says, which is what lets a cancelled meeting be shown
            // as cancelled and excluded from free/busy.
            event.providerMetadata.status.rawValue,
            "default",
            nil,
            event.recurrenceMasterID?.uuidString,
            event.recurrenceOriginalStart.map(encodeInstant),
            event.recurrence == nil ? 0 : 1,
            event.providerMetadata.syncStatus.databaseValue,
            encodeInstant(event.createdAt),
            encodeInstant(event.updatedAt),
            event.providerMetadata.deletedAt.map(encodeInstant),
            event.providerMetadata.rawICSProperties,
            event.versionNumber,
            event.providerMetadata.providerExternalID,
            event.providerMetadata.providerRawFields,
            event.providerMetadata.hasUnrepresentableRecurrence.databaseInt
        ]
    }

    private func insert(event: CalendarEvent, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "events", columns: Self.eventColumns),
            arguments: eventArguments(event)
        )
    }

    private func upsert(event: CalendarEvent, in db: Database) throws {
        try db.execute(
            sql: Self.upsertSQL(table: "events", columns: Self.eventColumns),
            arguments: eventArguments(event)
        )
    }

    private func insert(reminder: EventReminder, eventID: UUID, in db: Database) throws {
        guard let offsetSeconds = reminder.offset.relativeOffsetSeconds else { return }
        try db.execute(
            sql: """
                INSERT INTO event_reminders (
                    id, event_id, trigger_type, offset_seconds, absolute_instant,
                    delivery_method, is_enabled, notification_identifier
                )
                VALUES (?, ?, 'relative', ?, NULL, 'localNotification', 1, ?)
                """,
            arguments: [
                reminder.id.uuidString,
                eventID.uuidString,
                offsetSeconds,
                "event-\(eventID.uuidString)-reminder-\(reminder.id.uuidString)"
            ]
        )
    }

    private func insert(attendee: EventAttendee, eventID: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO event_attendees (
                    id, event_id, name, email, participation_status, role,
                    is_organizer, is_current_user, sort_order
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                attendee.id.uuidString,
                eventID.uuidString,
                attendee.name,
                attendee.email,
                attendee.participationStatus.rawValue,
                attendee.role.rawValue,
                attendee.isOrganizer.databaseInt,
                attendee.isCurrentUser.databaseInt,
                attendee.sortOrder
            ]
        )
    }

    private func insert(recurrence: RecurrenceRule, event: CalendarEvent, in db: Database) throws {
        let endValues = recurrenceEndValues(recurrence.end, event: event)
        try db.execute(
            sql: """
                INSERT INTO event_recurrence_rules (
                    id, event_id, frequency, interval, days_of_week, days_of_month,
                    months_of_year, week_start, count, until_instant, until_local_date,
                    set_positions, raw_rrule
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                UUID().uuidString,
                event.id.uuidString,
                recurrence.frequency.rawValue,
                max(recurrence.interval, 1),
                encodeIntegerArray(recurrence.weekdays.sorted().map(\.rawValue)),
                encodeIntegerArray(recurrence.daysOfMonth.sorted()),
                nil,
                Weekday.monday.rawValue,
                endValues.count,
                endValues.untilInstant,
                endValues.untilLocalDate,
                encodeIntegerArray(recurrence.setPositions.sorted()),
                nil
            ]
        )
    }

    private func insertSearchRow(for event: CalendarEvent, calendarName: String?, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO event_search (event_id, title, notes, location_name, calendar_name, url_host)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                event.id.uuidString,
                event.title,
                event.notes,
                event.location,
                calendarName,
                event.urlString.flatMap { URL(string: $0)?.host }
            ]
        )
    }

    private static let pendingMutationColumns = [
        "id", "object_id", "object_type", "operation", "created_at",
        "payload", "idempotency_key", "status", "attempt_count",
        "last_attempt_at", "next_retry_at", "change_journal_entry_id"
    ]

    private func pendingMutationArguments(_ mutation: PendingMutation) -> StatementArguments {
        [
            mutation.id.uuidString,
            mutation.objectID.uuidString,
            mutation.objectType.rawValue,
            mutation.operation.rawValue,
            encodeInstant(mutation.createdAt),
            mutation.payload,
            mutation.idempotencyKey.uuidString,
            mutation.status.rawValue,
            mutation.attemptCount,
            mutation.lastAttemptAt.map(encodeInstant),
            mutation.nextRetryAt.map(encodeInstant),
            mutation.changeJournalEntryID?.uuidString
        ]
    }

    private func insert(mutation: PendingMutation, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "pending_mutations", columns: Self.pendingMutationColumns),
            arguments: pendingMutationArguments(mutation)
        )
    }

    /// The retry bookkeeping (`status`, `attempt_count`, the retry timestamps) now comes off
    /// the model, which is what lets the mutation processor (M3) update it in place — a bare
    /// re-enqueue of the same row no longer rewinds it, because the caller is the one who read
    /// the current values before writing this one back.
    private func upsert(mutation: PendingMutation, in db: Database) throws {
        try db.execute(
            sql: Self.upsertSQL(table: "pending_mutations", columns: Self.pendingMutationColumns),
            arguments: pendingMutationArguments(mutation)
        )
    }

    private static let tombstoneColumns = [
        "id", "object_id", "object_type", "title", "deleted_at",
        "event_snapshot_json", "deletion_synced_at", "deleted_by", "purge_after"
    ]

    private func tombstoneArguments(_ tombstone: DeletedObjectTombstone) -> StatementArguments {
        [
            tombstone.id.uuidString,
            tombstone.entityID.uuidString,
            tombstone.entityType.rawValue,
            tombstone.title,
            encodeInstant(tombstone.deletedAt),
            tombstone.eventSnapshotJSON,
            tombstone.deletionSyncedAt.map(encodeInstant),
            tombstone.deletedBy.rawValue,
            encodeInstant(tombstone.purgeAfter)
        ]
    }

    private func insert(tombstone: DeletedObjectTombstone, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "deleted_objects", columns: Self.tombstoneColumns),
            arguments: tombstoneArguments(tombstone)
        )
    }

    private func upsert(tombstone: DeletedObjectTombstone, in db: Database) throws {
        try db.execute(
            sql: Self.upsertSQL(table: "deleted_objects", columns: Self.tombstoneColumns),
            arguments: tombstoneArguments(tombstone)
        )
    }

    private static let changeJournalColumns = [
        "id", "entity_type", "entity_id", "operation", "field_diff", "source", "occurred_at", "applied_mutation_id"
    ]

    /// Insert-only: spec 2.8 makes the journal append-only, so there is deliberately no
    /// `upsert(journalEntry:)` for a use case to reach for by accident.
    private func insert(journalEntry: ChangeJournalEntry, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "change_journal", columns: Self.changeJournalColumns),
            arguments: [
                journalEntry.id.uuidString,
                journalEntry.entityType.rawValue,
                journalEntry.entityID.uuidString,
                journalEntry.operation.rawValue,
                journalEntry.fieldDiff,
                journalEntry.source.rawValue,
                encodeInstant(journalEntry.occurredAt),
                journalEntry.appliedMutationID?.uuidString
            ]
        )
    }

    private static let eventVersionColumns = [
        "id", "event_id", "version_number", "snapshot_json", "created_at", "change_journal_entry_id"
    ]

    /// Insert-only: spec 2.9 version rows are history, never edited in place.
    private func insert(eventVersion: EventVersion, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "event_versions", columns: Self.eventVersionColumns),
            arguments: [
                eventVersion.id.uuidString,
                eventVersion.eventID.uuidString,
                eventVersion.versionNumber,
                eventVersion.snapshotJSON,
                encodeInstant(eventVersion.createdAt),
                eventVersion.changeJournalEntryID.uuidString
            ]
        )
    }

    private static let recurrenceExceptionColumns = [
        "id", "master_event_id", "original_occurrence_start", "original_occurrence_local_date",
        "exception_type", "replacement_event_id"
    ]

    private func recurrenceExceptionArguments(_ exception: RecurrenceException) -> StatementArguments {
        [
            exception.id.uuidString,
            exception.masterEventID.uuidString,
            exception.originalOccurrenceStart.map(encodeInstant),
            exception.originalOccurrenceLocalDate,
            exception.exceptionType.rawValue,
            exception.replacementEventID?.uuidString
        ]
    }

    private func insert(exception: RecurrenceException, in db: Database) throws {
        try db.execute(
            sql: Self.insertSQL(table: "event_recurrence_exceptions", columns: Self.recurrenceExceptionColumns),
            arguments: recurrenceExceptionArguments(exception)
        )
    }

    private func upsert(exception: RecurrenceException, in db: Database) throws {
        try db.execute(
            sql: Self.upsertSQL(table: "event_recurrence_exceptions", columns: Self.recurrenceExceptionColumns),
            arguments: recurrenceExceptionArguments(exception)
        )
    }

    private func fetchRecurrenceExceptions(in db: Database) throws -> [RecurrenceException] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM event_recurrence_exceptions")
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let masterEventID = UUID(uuidString: row["master_event_id"]),
                  let exceptionType = RecurrenceExceptionType(rawValue: row["exception_type"]) else {
                return nil
            }

            return RecurrenceException(
                id: id,
                masterEventID: masterEventID,
                originalOccurrenceStart: decodeInstant(row["original_occurrence_start"]),
                originalOccurrenceLocalDate: row["original_occurrence_local_date"],
                exceptionType: exceptionType,
                replacementEventID: (row["replacement_event_id"] as String?).flatMap(UUID.init(uuidString:))
            )
        }
    }

    private func fetchCalendars(in db: Database) throws -> [BetterCalendar] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM calendars WHERE deleted_at IS NULL ORDER BY sort_order ASC, name ASC")
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            // Spec 3.6: a hex that matches one of the six design tokens *is* that token, and
            // `colorHex` stays nil so rendering behaves exactly as it did before this field
            // existed. Anything else is a provider's own color, kept verbatim.
            let storedHex: String? = row["color_hex"]
            let matchedToken = storedHex.flatMap(CalendarColorName.init(hexValue:))
            // `calendarArguments` writes `providerCalendarID ?? id` so the column is never null
            // (it has been the local UUID for every row ever written). Normalize the round trip
            // here rather than there: a value that is just the local id again carries no
            // provider identity, so it reads back as the `nil` it was written from. A device
            // calendar's identifier is an EventKit string and never collides with this.
            let storedProviderCalendarID: String? = row["provider_calendar_id"]
            let distinctProviderCalendarID = storedProviderCalendarID == id.uuidString ? nil : storedProviderCalendarID
            return BetterCalendar(
                id: id,
                name: row["name"],
                colorName: matchedToken ?? .betterBlue,
                isVisible: row.boolValue("is_visible"),
                isDefault: row.boolValue("is_default"),
                sortOrder: row["sort_order"],
                createdAt: decodeInstant(row["created_at"]) ?? .now,
                updatedAt: decodeInstant(row["updated_at"]) ?? .now,
                versionNumber: row["version_number"] ?? 1,
                provider: EventProvider(databaseValue: row["provider"] ?? ""),
                connectionMethod: ConnectionMethod(rawValue: row["connection_method"] ?? "") ?? .local,
                providerAccountID: row["provider_account_id"],
                providerCalendarID: distinctProviderCalendarID,
                accountName: row["account_name"],
                colorHex: matchedToken == nil ? storedHex : nil,
                isReadOnly: row.boolValue("is_read_only"),
                timeZoneIdentifier: row["time_zone_id"],
                capabilities: decodeCapabilities(row["capabilities_json"]),
                isUnavailable: row.boolValue("is_unavailable"),
                unavailableSince: (row["unavailable_since"] as String?).flatMap(decodeInstant)
            )
        }
    }

    private func fetchEvents(in db: Database) throws -> [CalendarEvent] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM events WHERE deleted_at IS NULL ORDER BY COALESCE(start_instant, start_local_date) ASC, title ASC")
        var events: [CalendarEvent] = []

        for row in rows {
            guard let event = try event(from: row, in: db) else { continue }
            events.append(event)
        }

        return events
    }

    private func event(from row: Row, in db: Database) throws -> CalendarEvent? {
        guard let id = UUID(uuidString: row["id"]),
              let calendarID = UUID(uuidString: row["calendar_id"]) else {
            return nil
        }

        let eventType: String = row["event_type"]
        let timeType = EventTimeType(rawValue: eventType) ?? .timed
        let isAllDay = timeType == .allDay
        let timeZoneIdentifier: String = row["original_timezone_id"] ?? TimeZone.current.identifier
        let startDate: Date
        let endDate: Date

        if isAllDay {
            guard let startLocalDate: String = row["start_local_date"],
                  let endLocalDate: String = row["end_local_date_exclusive"],
                  let decodedStartDate = date(fromLocalDateString: startLocalDate, timeZoneIdentifier: timeZoneIdentifier),
                  let decodedEndDate = date(fromLocalDateString: endLocalDate, timeZoneIdentifier: timeZoneIdentifier) else {
                return nil
            }
            startDate = decodedStartDate
            endDate = decodedEndDate
        } else {
            guard let decodedStartDate = decodeInstant(row["start_instant"]),
                  let decodedEndDate = decodeInstant(row["end_instant"]) else {
                return nil
            }
            startDate = decodedStartDate
            endDate = decodedEndDate
        }

        let reminders = try fetchReminders(eventID: id, in: db)
        let recurrence = try fetchRecurrence(eventID: id, isAllDay: isAllDay, timeZoneIdentifier: timeZoneIdentifier, in: db)
        let attendees = try fetchAttendees(eventID: id, in: db)

        return CalendarEvent(
            id: id,
            calendarID: calendarID,
            title: row["title"],
            startDate: startDate,
            endDate: endDate,
            // Constructed with `timeType` rather than the boolean shim: routing through
            // `isAllDay:` would collapse a stored floating event into a timed one on load.
            timeType: timeType,
            timeZoneIdentifier: timeZoneIdentifier,
            location: row["location_name"],
            urlString: row["url"],
            notes: row["notes"],
            reminders: reminders,
            recurrence: recurrence,
            providerMetadata: ProviderMetadata(
                provider: EventProvider(databaseValue: row["provider"]),
                // Spec 3C.1: an event carries no account or calendar identifier of its own. Its
                // `calendarID` points at a mirrored `BetterCalendar` that already holds both,
                // and duplicating them here would create two places for one fact to live —
                // which is one more than can be kept in agreement. `load()` used to invent
                // `providerCalendarID` from the row's `calendar_id`; that was the same
                // hardcoding `v018` removed for calendars.
                providerAccountID: nil,
                providerCalendarID: nil,
                providerObjectID: row["provider_object_id"],
                providerVersion: row["provider_version"],
                syncStatus: SyncStatus(databaseValue: row["sync_status"]),
                deletedAt: decodeInstant(row["deleted_at"]),
                rawICSProperties: row["raw_ics_properties"],
                providerExternalID: row["provider_external_id"],
                providerRawFields: row["provider_raw_fields"],
                status: EventStatus(rawValue: row["status"] ?? "") ?? .confirmed,
                hasUnrepresentableRecurrence: row.boolValue("has_unrepresentable_recurrence")
            ),
            attendees: attendees,
            createdAt: decodeInstant(row["created_at"]) ?? .now,
            updatedAt: decodeInstant(row["updated_at"]) ?? .now,
            availability: EventAvailability(rawValue: row["availability"]) ?? .busy,
            recurrenceMasterID: (row["recurrence_master_id"] as String?).flatMap(UUID.init(uuidString:)),
            recurrenceOriginalStart: decodeInstant(row["recurrence_original_start"]),
            versionNumber: row["version_number"] ?? 1
        )
    }

    private func fetchReminders(eventID: UUID, in db: Database) throws -> [EventReminder] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM event_reminders WHERE event_id = ? AND is_enabled = 1 ORDER BY offset_seconds ASC",
            arguments: [eventID.uuidString]
        )

        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let offset = ReminderOffset(relativeOffsetSeconds: row["offset_seconds"]) else {
                return nil
            }
            return EventReminder(id: id, offset: offset)
        }
    }

    private func fetchAttendees(eventID: UUID, in db: Database) throws -> [EventAttendee] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM event_attendees WHERE event_id = ? ORDER BY sort_order ASC, id ASC",
            arguments: [eventID.uuidString]
        )

        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return EventAttendee(
                id: id,
                name: row["name"],
                email: row["email"],
                participationStatus: EventParticipationStatus(rawValue: row["participation_status"] ?? "") ?? .unknown,
                role: EventAttendeeRole(rawValue: row["role"] ?? "") ?? .unknown,
                isOrganizer: row.boolValue("is_organizer"),
                isCurrentUser: row.boolValue("is_current_user"),
                sortOrder: row["sort_order"] ?? 0
            )
        }
    }

    private func fetchRecurrence(eventID: UUID, isAllDay: Bool, timeZoneIdentifier: String, in db: Database) throws -> RecurrenceRule? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM event_recurrence_rules WHERE event_id = ?", arguments: [eventID.uuidString]) else {
            return nil
        }

        guard let frequency = RecurrenceFrequency(rawValue: row["frequency"]) else {
            return nil
        }

        let weekdayValues = decodeIntegerArray(row["days_of_week"]) ?? []
        let weekdays = Set(weekdayValues.compactMap(Weekday.init(rawValue:)))
        let daysOfMonth = decodeIntegerArray(row["days_of_month"]) ?? []
        let setPositions = decodeIntegerArray(row["set_positions"]) ?? []

        let end: RecurrenceEnd
        if let count: Int = row["count"] {
            end = .afterOccurrences(count)
        } else if let untilInstant = decodeInstant(row["until_instant"]) {
            end = .onDate(untilInstant)
        } else if let untilLocalDate: String = row["until_local_date"],
                  let date = date(fromLocalDateString: untilLocalDate, timeZoneIdentifier: timeZoneIdentifier) {
            end = .onDate(date)
        } else {
            end = .never
        }

        return RecurrenceRule(
            frequency: frequency,
            interval: max(row["interval"] as Int, 1),
            weekdays: weekdays,
            daysOfMonth: daysOfMonth,
            setPositions: setPositions,
            end: end
        )
    }

    private func fetchPendingMutations(in db: Database) throws -> [PendingMutation] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM pending_mutations ORDER BY created_at ASC")
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let objectID = UUID(uuidString: row["object_id"]),
                  let objectType = MutationObjectType(rawValue: row["object_type"]),
                  let operation = MutationOperation(rawValue: row["operation"]) else {
                return nil
            }

            return PendingMutation(
                id: id,
                objectID: objectID,
                objectType: objectType,
                operation: operation,
                createdAt: decodeInstant(row["created_at"]) ?? .now,
                payload: row["payload"],
                idempotencyKey: (row["idempotency_key"] as String?).flatMap(UUID.init(uuidString:)) ?? id,
                status: (row["status"] as String?).flatMap(MutationStatus.init(rawValue:)) ?? .pending,
                attemptCount: row["attempt_count"] ?? 0,
                lastAttemptAt: decodeInstant(row["last_attempt_at"]),
                nextRetryAt: decodeInstant(row["next_retry_at"]),
                changeJournalEntryID: (row["change_journal_entry_id"] as String?).flatMap(UUID.init(uuidString:))
            )
        }
    }

    private func fetchDeletedEventTombstones(in db: Database) throws -> [DeletedObjectTombstone] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM deleted_objects WHERE object_type = 'event' ORDER BY deleted_at ASC")
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let eventID = UUID(uuidString: row["object_id"]) else {
                return nil
            }
            let deletedAt = decodeInstant(row["deleted_at"]) ?? .now

            return DeletedObjectTombstone(
                id: id,
                entityType: EngineEntityType(rawValue: row["object_type"]) ?? .event,
                entityID: eventID,
                title: row["title"] ?? "Deleted Event",
                deletedAt: deletedAt,
                deletedBy: (row["deleted_by"] as String?).flatMap(TombstoneCause.init(rawValue:)) ?? .userEdit,
                purgeAfter: decodeInstant(row["purge_after"]) ?? EngineRetentionPolicy.purgeDate(forTombstoneDeletedAt: deletedAt),
                eventSnapshotJSON: row["event_snapshot_json"],
                deletionSyncedAt: decodeInstant(row["deletion_synced_at"])
            )
        }
    }

    /// One `application_settings` row per key (BC-SET-001, spec 1.20). Optional `AppSettings`
    /// fields simply have no row when unset; `upsertSettings` deletes the row for a key that
    /// becomes unset rather than ever issuing a blanket `DELETE`, so it never clobbers a
    /// forward-compatible key this schema doesn't yet model.
    private enum SettingsKey: String, CaseIterable {
        case defaultEventDurationMinutes = "default_event_duration_minutes"
        case defaultReminderOffset = "default_reminder_offset"
        case firstWeekday = "first_weekday"
        case showWeekends = "show_weekends"
        case timeFormat = "time_format"
        case defaultCalendarView = "default_calendar_view"
        case allDayReminderHour = "all_day_reminder_hour"
        case snapIntervalMinutes = "snap_interval_minutes"
        case appearance = "appearance"
        case reduceCalendarAnimation = "reduce_calendar_animation"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case lastSelectedTab = "last_selected_tab"
        case lastSelectedDate = "last_selected_date"
        case secondaryTimeZoneIdentifier = "secondary_time_zone_identifier"
        // Spec 3.3: a new key needs no migration — `application_settings` is key-value, and
        // `upsertSettings` deletes only the keys it knows about, so an older build reading a
        // newer database is unaffected.
        case hasSeenCalendarAccessPrimer = "has_seen_calendar_access_primer"
    }

    private func fetchSettings(in db: Database) throws -> AppSettings {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM application_settings")
        var values: [String: String] = [:]
        for row in rows {
            values[row["key"]] = row["value"]
        }

        var settings = AppSettings.defaultSettings

        if let raw = values[SettingsKey.defaultEventDurationMinutes.rawValue], let minutes = Int(raw) {
            settings.defaultEventDurationMinutes = minutes
        }
        if let raw = values[SettingsKey.defaultReminderOffset.rawValue], let seconds = Int(raw) {
            settings.defaultReminderOffset = ReminderOffset(relativeOffsetSeconds: seconds)
        }
        if let raw = values[SettingsKey.firstWeekday.rawValue], let rawValue = Int(raw) {
            settings.firstWeekday = Weekday(rawValue: rawValue)
        }
        if let raw = values[SettingsKey.showWeekends.rawValue] {
            settings.showWeekends = raw == "1"
        }
        if let raw = values[SettingsKey.timeFormat.rawValue], let value = TimeFormatPreference(rawValue: raw) {
            settings.timeFormat = value
        }
        if let raw = values[SettingsKey.defaultCalendarView.rawValue], let value = CalendarViewMode(rawValue: raw) {
            settings.defaultCalendarView = value
        }
        if let raw = values[SettingsKey.allDayReminderHour.rawValue], let hour = Int(raw) {
            settings.allDayReminderHour = hour
        }
        if let raw = values[SettingsKey.snapIntervalMinutes.rawValue], let minutes = Int(raw) {
            settings.snapIntervalMinutes = minutes
        }
        if let raw = values[SettingsKey.appearance.rawValue], let value = AppearancePreference(rawValue: raw) {
            settings.appearance = value
        }
        if let raw = values[SettingsKey.reduceCalendarAnimation.rawValue] {
            settings.reduceCalendarAnimation = raw == "1"
        }
        if let raw = values[SettingsKey.hasCompletedOnboarding.rawValue] {
            settings.hasCompletedOnboarding = raw == "1"
        }
        if let raw = values[SettingsKey.lastSelectedTab.rawValue], let value = BetterCalendarTab(rawValue: raw) {
            settings.lastSelectedTab = value
        }
        if let raw = values[SettingsKey.lastSelectedDate.rawValue] {
            settings.lastSelectedDate = decodeInstant(raw)
        }
        settings.secondaryTimeZoneIdentifier = values[SettingsKey.secondaryTimeZoneIdentifier.rawValue]
        if let raw = values[SettingsKey.hasSeenCalendarAccessPrimer.rawValue] {
            settings.hasSeenCalendarAccessPrimer = raw == "1"
        }

        return settings
    }

    private func upsertSettings(_ settings: AppSettings, in db: Database) throws {
        var values: [SettingsKey: String] = [
            .defaultEventDurationMinutes: String(settings.defaultEventDurationMinutes),
            .showWeekends: settings.showWeekends.databaseInt.description,
            .timeFormat: settings.timeFormat.rawValue,
            .defaultCalendarView: settings.defaultCalendarView.rawValue,
            .allDayReminderHour: String(settings.allDayReminderHour),
            .snapIntervalMinutes: String(settings.snapIntervalMinutes),
            .appearance: settings.appearance.rawValue,
            .reduceCalendarAnimation: settings.reduceCalendarAnimation.databaseInt.description,
            .hasCompletedOnboarding: settings.hasCompletedOnboarding.databaseInt.description,
            .hasSeenCalendarAccessPrimer: settings.hasSeenCalendarAccessPrimer.databaseInt.description
        ]

        if let offsetSeconds = settings.defaultReminderOffset?.relativeOffsetSeconds {
            values[.defaultReminderOffset] = String(offsetSeconds)
        }
        if let firstWeekday = settings.firstWeekday {
            values[.firstWeekday] = String(firstWeekday.rawValue)
        }
        if let lastSelectedTab = settings.lastSelectedTab {
            values[.lastSelectedTab] = lastSelectedTab.rawValue
        }
        if let lastSelectedDate = settings.lastSelectedDate {
            values[.lastSelectedDate] = encodeInstant(lastSelectedDate)
        }
        if let secondaryTimeZoneIdentifier = settings.secondaryTimeZoneIdentifier {
            values[.secondaryTimeZoneIdentifier] = secondaryTimeZoneIdentifier
        }

        let now = encodeInstant(Date())
        for (key, value) in values {
            try db.execute(
                sql: "INSERT OR REPLACE INTO application_settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [key.rawValue, value, now]
            )
        }

        let presentKeys = Set(values.keys)
        for key in SettingsKey.allCases where !presentKeys.contains(key) {
            try db.execute(sql: "DELETE FROM application_settings WHERE key = ?", arguments: [key.rawValue])
        }
    }

    private func recurrenceEndValues(_ end: RecurrenceEnd, event: CalendarEvent) -> (count: Int?, untilInstant: String?, untilLocalDate: String?) {
        switch end {
        case .never:
            return (nil, nil, nil)
        case .afterOccurrences(let count):
            return (count, nil, nil)
        case .onDate(let date):
            if event.isAllDay {
                return (nil, nil, localDateString(for: date, timeZoneIdentifier: event.timeZoneIdentifier))
            }
            return (nil, encodeInstant(date), nil)
        }
    }
}

private extension Row {
    func boolValue(_ column: String) -> Bool {
        let value: Int = self[column]
        return value != 0
    }
}

private extension Bool {
    var databaseInt: Int {
        self ? 1 : 0
    }
}

private extension EventProvider {
    var databaseValue: String {
        switch self {
        case .betterCalendar:
            "betterCalendarLocal"
        case .google:
            "google"
        case .apple:
            "eventKit"
        case .university:
            "university"
        case .exchange:
            "exchange"
        case .deviceLocal:
            "deviceLocal"
        case .subscribed:
            "subscribed"
        case .otherAccount:
            "otherAccount"
        }
    }

    init(databaseValue: String) {
        switch databaseValue {
        case "betterCalendarLocal":
            self = .betterCalendar
        case "google":
            self = .google
        case "eventKit":
            self = .apple
        case "university":
            self = .university
        case "exchange":
            self = .exchange
        case "deviceLocal":
            self = .deviceLocal
        case "subscribed":
            self = .subscribed
        case "otherAccount":
            self = .otherAccount
        default:
            self = .betterCalendar
        }
    }
}

private extension SyncStatus {
    var databaseValue: String {
        switch self {
        case .synced:
            "synced"
        case .pendingCreate:
            "pendingCreate"
        case .pendingUpdate:
            "pendingUpdate"
        case .pendingDelete:
            "pendingDelete"
        case .failed:
            "failed"
        }
    }

    init(databaseValue: String) {
        switch databaseValue {
        case "pendingCreate":
            self = .pendingCreate
        case "pendingUpdate":
            self = .pendingUpdate
        case "pendingDelete":
            self = .pendingDelete
        case "failed":
            self = .failed
        default:
            self = .synced
        }
    }
}

private extension ReminderOffset {
    var relativeOffsetSeconds: Int? {
        switch self {
        case .none:
            nil
        case .atStart:
            0
        case .minutesBefore(let minutes):
            -minutes * 60
        case .daysBefore(let days):
            -days * 24 * 60 * 60
        }
    }

    init?(relativeOffsetSeconds: Int) {
        switch relativeOffsetSeconds {
        case 0:
            self = .atStart
        case let seconds where seconds < 0 && seconds % (24 * 60 * 60) == 0:
            self = .daysBefore(abs(seconds) / (24 * 60 * 60))
        case let seconds where seconds < 0 && seconds % 60 == 0:
            self = .minutesBefore(abs(seconds) / 60)
        default:
            return nil
        }
    }
}

private func encodeInstant(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func decodeInstant(_ value: String?) -> Date? {
    guard let value else { return nil }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: value) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func localDateString(for date: Date, timeZoneIdentifier: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
}

private func date(fromLocalDateString value: String, timeZoneIdentifier: String) -> Date? {
    let pieces = value.split(separator: "-").compactMap { Int($0) }
    guard pieces.count == 3 else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
}

private func encodeIntegerArray(_ values: [Int]) -> String? {
    guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func decodeIntegerArray(_ value: String?) -> [Int]? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([Int].self, from: data)
}
