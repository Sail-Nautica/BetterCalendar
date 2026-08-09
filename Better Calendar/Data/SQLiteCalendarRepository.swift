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
        "v009_extend_search_index"
    ]

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

    func save(_ database: LocalCalendarDatabase) throws {
        let databaseQueue = try openDatabase()
        try databaseQueue.write { db in
            try replaceDatabase(database, in: db)
        }
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

    private func openDatabase() throws -> DatabaseQueue {
        let fileURL = try databaseURL()
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let databaseQueue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(databaseQueue)
        return databaseQueue
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

        return migrator
    }

    private func replaceDatabase(_ database: LocalCalendarDatabase, in db: Database) throws {
        try db.execute(sql: "DELETE FROM event_search")
        try db.execute(sql: "DELETE FROM event_tags")
        try db.execute(sql: "DELETE FROM event_links")
        try db.execute(sql: "DELETE FROM event_attachments")
        try db.execute(sql: "DELETE FROM event_recurrence_exceptions")
        try db.execute(sql: "DELETE FROM event_recurrence_rules")
        try db.execute(sql: "DELETE FROM event_reminders")
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

        try db.execute(
            sql: "INSERT OR REPLACE INTO schema_metadata (key, value, updated_at) VALUES ('schema_version', ?, ?)",
            arguments: [String(Self.migrationIdentifiers.count), encodeInstant(Date())]
        )
    }

    private func insert(calendar: BetterCalendar, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO calendars (
                    id, provider, provider_account_id, provider_calendar_id, name, color_hex,
                    is_visible, is_read_only, is_default, time_zone_id, sort_order,
                    created_at, updated_at, deleted_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                calendar.id.uuidString,
                EventProvider.betterCalendar.databaseValue,
                nil,
                calendar.id.uuidString,
                calendar.name,
                calendar.colorName.hexValue,
                calendar.isVisible.databaseInt,
                0,
                calendar.isDefault.databaseInt,
                nil,
                calendar.sortOrder,
                encodeInstant(calendar.createdAt),
                encodeInstant(calendar.updatedAt),
                nil
            ]
        )
    }

    private func insert(event: CalendarEvent, in db: Database) throws {
        let isAllDay = event.isAllDay
        // Floating events persist instants exactly like timed events; the schema's compound
        // CHECK places no column requirements on the floating branch, so no migration is needed.
        let eventType = event.timeType.rawValue
        let startInstant = isAllDay ? nil : encodeInstant(event.startDate)
        let endInstant = isAllDay ? nil : encodeInstant(event.endDate)
        let startLocalDate = isAllDay ? localDateString(for: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil
        let endLocalDateExclusive = isAllDay ? localDateString(for: event.endDate, timeZoneIdentifier: event.timeZoneIdentifier) : nil

        try db.execute(
            sql: """
                INSERT INTO events (
                    id, calendar_id, provider, provider_object_id, provider_version,
                    title, notes, location_name, location_latitude, location_longitude, url,
                    event_type, start_instant, end_instant, start_local_date, end_local_date_exclusive,
                    original_timezone_id, availability, status, privacy, color_override,
                    recurrence_master_id, recurrence_original_start, is_recurrence_master,
                    sync_status, created_at, updated_at, deleted_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
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
                "busy",
                "confirmed",
                "default",
                nil,
                event.recurrenceMasterID?.uuidString,
                event.recurrenceOriginalStart.map(encodeInstant),
                event.recurrence == nil ? 0 : 1,
                event.providerMetadata.syncStatus.databaseValue,
                encodeInstant(event.createdAt),
                encodeInstant(event.updatedAt),
                event.providerMetadata.deletedAt.map(encodeInstant)
            ]
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

    private func insert(mutation: PendingMutation, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO pending_mutations (id, object_id, object_type, operation, created_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                mutation.id.uuidString,
                mutation.objectID.uuidString,
                mutation.objectType.rawValue,
                mutation.operation.rawValue,
                encodeInstant(mutation.createdAt)
            ]
        )
    }

    private func insert(tombstone: DeletedEventTombstone, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO deleted_objects (
                    id, object_id, object_type, title, deleted_at,
                    event_snapshot_json, deletion_synced_at
                )
                VALUES (?, ?, 'event', ?, ?, ?, ?)
                """,
            arguments: [
                tombstone.id.uuidString,
                tombstone.eventID.uuidString,
                tombstone.title,
                encodeInstant(tombstone.deletedAt),
                tombstone.eventSnapshotJSON,
                tombstone.deletionSyncedAt.map(encodeInstant)
            ]
        )
    }

    private func insert(exception: RecurrenceException, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO event_recurrence_exceptions (
                    id, master_event_id, original_occurrence_start, original_occurrence_local_date,
                    exception_type, replacement_event_id
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                exception.id.uuidString,
                exception.masterEventID.uuidString,
                exception.originalOccurrenceStart.map(encodeInstant),
                exception.originalOccurrenceLocalDate,
                exception.exceptionType.rawValue,
                exception.replacementEventID?.uuidString
            ]
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
            return BetterCalendar(
                id: id,
                name: row["name"],
                colorName: CalendarColorName(hexValue: row["color_hex"]) ?? .betterBlue,
                isVisible: row.boolValue("is_visible"),
                isDefault: row.boolValue("is_default"),
                sortOrder: row["sort_order"],
                createdAt: decodeInstant(row["created_at"]) ?? .now,
                updatedAt: decodeInstant(row["updated_at"]) ?? .now
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
                providerAccountID: nil,
                providerCalendarID: calendarID.uuidString,
                providerObjectID: row["provider_object_id"],
                providerVersion: row["provider_version"],
                syncStatus: SyncStatus(databaseValue: row["sync_status"]),
                deletedAt: decodeInstant(row["deleted_at"])
            ),
            createdAt: decodeInstant(row["created_at"]) ?? .now,
            updatedAt: decodeInstant(row["updated_at"]) ?? .now,
            recurrenceMasterID: (row["recurrence_master_id"] as String?).flatMap(UUID.init(uuidString:)),
            recurrenceOriginalStart: decodeInstant(row["recurrence_original_start"])
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
                createdAt: decodeInstant(row["created_at"]) ?? .now
            )
        }
    }

    private func fetchDeletedEventTombstones(in db: Database) throws -> [DeletedEventTombstone] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM deleted_objects WHERE object_type = 'event' ORDER BY deleted_at ASC")
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let eventID = UUID(uuidString: row["object_id"]) else {
                return nil
            }

            return DeletedEventTombstone(
                id: id,
                eventID: eventID,
                title: row["title"] ?? "Deleted Event",
                deletedAt: decodeInstant(row["deleted_at"]) ?? .now,
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
            .hasCompletedOnboarding: settings.hasCompletedOnboarding.databaseInt.description
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

private extension CalendarColorName {
    var hexValue: String {
        switch self {
        case .betterBlue:
            "#4F7DFF"
        case .success:
            "#2EA86B"
        case .warning:
            "#E68A2E"
        case .destructive:
            "#D94D4D"
        case .navy:
            "#17243D"
        case .gray:
            "#5C6678"
        }
    }

    init?(hexValue: String) {
        switch hexValue.uppercased() {
        case "#4F7DFF":
            self = .betterBlue
        case "#2EA86B":
            self = .success
        case "#E68A2E":
            self = .warning
        case "#D94D4D":
            self = .destructive
        case "#17243D":
            self = .navy
        case "#5C6678":
            self = .gray
        default:
            return nil
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
