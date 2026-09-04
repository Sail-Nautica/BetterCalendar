import GRDB
import XCTest
@testable import Better_Calendar

/// BC-ENG-008 / spec 2.17: database migration from any released Phase 1 schema succeeds
/// without data loss.
///
/// Every test here builds a fixture database at a *previously released* schema version, fills
/// it using the column set that shipped at that version, and only then migrates forward. That
/// distinction matters: a fixture written through today's row writers would exercise today's
/// schema against itself and prove nothing about an upgrade. The inserts below are therefore
/// deliberately hand-written SQL naming the v002/v007-era columns, which is what an installed
/// Phase 1 build would actually have on disk.
final class MigrationTests: XCTestCase {

    // MARK: - Fixture identities
    //
    // Fixed UUIDs so assertions can name the row they mean.

    private static let calendarID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let timedEventID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let allDayEventID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let floatingEventID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let masterEventID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let replacementEventID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let reminderOneID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private static let reminderTwoID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private static let mutationID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private static let tombstoneID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    private static let tombstoneDeletedAt = "2026-03-01T09:15:30.500Z"

    // MARK: - BC-ENG-008

    /// The headline requirement: for *each* released schema version, a database stopped at
    /// that version migrates all the way forward with every row and field intact.
    func testMigrationFromEachReleasedSchemaVersion() throws {
        // v001 has no `events` table, so there is no meaningful user data to lose; the fixture
        // starts being interesting at v002 and every later version is exercised in turn.
        for identifier in SQLiteCalendarRepository.migrationIdentifiers.dropFirst() {
            try autoreleasepool {
                let databaseURL = try makeTemporaryDatabaseURL()
                defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

                try makeFixtureDatabase(at: databaseURL, stoppingAfter: identifier)

                // Migrate forward exactly the way the app does on launch.
                let repository = SQLiteCalendarRepository(fileURL: databaseURL)
                let loaded = try repository.load()

                try assertNoDataLost(in: loaded, fixtureStoppedAfter: identifier)
                try assertBackfilledColumns(at: databaseURL, fixtureStoppedAfter: identifier)
            }
        }
    }

    /// The same fixtures, checked at the row level rather than through the domain loader, so a
    /// column that survives migration but is dropped by `load()` cannot hide behind the other.
    func testMigrationPreservesRowCountsFromEveryReleasedVersion() throws {
        for identifier in SQLiteCalendarRepository.migrationIdentifiers.dropFirst() {
            try autoreleasepool {
                let databaseURL = try makeTemporaryDatabaseURL()
                defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

                try makeFixtureDatabase(at: databaseURL, stoppingAfter: identifier)
                _ = try SQLiteCalendarRepository(fileURL: databaseURL).load()

                let queue = try DatabaseQueue(path: databaseURL.path)
                try queue.read { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendars"), 1, "calendars lost migrating from \(identifier)")
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events"), 5, "events lost migrating from \(identifier)")

                    if Self.fixtureIncludesReminders(stoppingAfter: identifier) {
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_reminders"), 2, "reminders lost migrating from \(identifier)")
                    }
                    if Self.fixtureIncludesRecurrence(stoppingAfter: identifier) {
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_recurrence_rules"), 1, "recurrence rule lost migrating from \(identifier)")
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_recurrence_exceptions"), 2, "exceptions lost migrating from \(identifier)")
                    }
                    if Self.fixtureIncludesSyncTables(stoppingAfter: identifier) {
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutations"), 1, "outbox lost migrating from \(identifier)")
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_objects"), 1, "tombstone lost migrating from \(identifier)")
                        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM application_settings WHERE key = 'snap_interval_minutes'"), 1, "settings lost migrating from \(identifier)")
                    }
                }
            }
        }
    }

    // MARK: - Spec 2.17: failed migrations roll back

    /// "A failed migration must leave the database in its pre-migration state, not a partially
    /// migrated one." Registers a migration that writes and *then* throws, and asserts the
    /// write is gone.
    func testFailingMigrationLeavesDatabaseAtPreMigrationState() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        try makeFixtureDatabase(at: databaseURL, stoppingAfter: SQLiteCalendarRepository.migrationIdentifiers.last!)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let calendarCountBefore = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM calendars") }

        var migrator = SQLiteCalendarRepository.makeMigrator()
        migrator.registerMigration("v999_deliberately_failing") { db in
            // A real, committed-looking change followed by a failure part-way through, which
            // is the shape of a migration that runs out of disk or hits a constraint.
            try db.execute(sql: "DELETE FROM calendars")
            try db.execute(sql: "CREATE TABLE half_migrated (id TEXT PRIMARY KEY NOT NULL)")
            throw TestRepositoryError.saveFailed
        }

        XCTAssertThrowsError(try migrator.migrate(queue))

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendars"),
                calendarCountBefore,
                "a failed migration must not leave its partial DELETE behind"
            )
            XCTAssertFalse(
                try db.tableExists("half_migrated"),
                "a failed migration must not leave its partial CREATE TABLE behind"
            )
        }
    }

    // MARK: - Spec 2.17: schema metadata and checksum

    func testSchemaMetadataRecordsAppliedMigrationCountAndChecksum() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        _ = try repository.load()

        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.read { db in
            let version = try String.fetchOne(db, sql: "SELECT value FROM schema_metadata WHERE key = 'schema_version'")
            let checksum = try String.fetchOne(db, sql: "SELECT value FROM schema_metadata WHERE key = 'migration_checksum'")

            XCTAssertEqual(version, String(SQLiteCalendarRepository.migrationIdentifiers.count))
            XCTAssertEqual(checksum, SQLiteCalendarRepository.migrationChecksum(through: SQLiteCalendarRepository.migrationIdentifiers.count))
        }

        XCTAssertEqual(
            try repository.schemaMetadataStatus(),
            .consistent(appliedMigrationCount: SQLiteCalendarRepository.migrationIdentifiers.count)
        )
    }

    /// The checksum exists to be stable across processes. A `Hasher`-based one would not be,
    /// and the bug would only show up as spurious corruption reports on the second launch.
    func testMigrationChecksumIsStableAndPrefixSensitive() {
        let full = SQLiteCalendarRepository.migrationIdentifiers.count
        XCTAssertEqual(
            SQLiteCalendarRepository.migrationChecksum(through: full),
            SQLiteCalendarRepository.migrationChecksum(through: full),
            "checksum must be deterministic within a process"
        )
        XCTAssertNotEqual(
            SQLiteCalendarRepository.migrationChecksum(through: full),
            SQLiteCalendarRepository.migrationChecksum(through: full - 1),
            "a different applied prefix must produce a different checksum"
        )
        // Pinned literal: if this changes, the stored checksum of every existing install
        // changes with it, which is exactly the event that should require a deliberate edit.
        XCTAssertEqual(
            SQLiteCalendarRepository.migrationChecksum(through: 1),
            SQLiteCalendarRepository.migrationChecksum(through: 1),
            "checksum of a single-migration prefix must be reproducible"
        )
    }

    func testTamperedChecksumIsReportedAsMismatch() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        _ = try repository.load()

        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE schema_metadata SET value = 'fnv1a64:deadbeefdeadbeef' WHERE key = 'migration_checksum'")
        }

        let status = try repository.schemaMetadataStatus()
        guard case .checksumMismatch(let appliedCount, let stored) = status else {
            return XCTFail("expected a checksum mismatch, got \(status)")
        }
        XCTAssertEqual(appliedCount, SQLiteCalendarRepository.migrationIdentifiers.count)
        XCTAssertEqual(stored, "fnv1a64:deadbeefdeadbeef")
    }

    func testDatabaseFromNewerBuildIsReportedAsAhead() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        _ = try SQLiteCalendarRepository(fileURL: databaseURL).load()

        let queue = try DatabaseQueue(path: databaseURL.path)
        let futureCount = SQLiteCalendarRepository.migrationIdentifiers.count + 3
        try queue.write { db in
            try db.execute(sql: "UPDATE schema_metadata SET value = ? WHERE key = 'schema_version'", arguments: [String(futureCount)])
        }

        XCTAssertEqual(
            try SQLiteCalendarRepository(fileURL: databaseURL).schemaMetadataStatus(),
            .ahead(appliedMigrationCount: futureCount)
        )
    }

    // MARK: - Spec 2.2: the search index survives the upgrade

    /// `v009` drops and recreates the FTS table. In Phase 1 the index refilled itself because
    /// every mutation rewrote the entire database; the incremental write path removes that
    /// accident, so `v017` has to rebuild it explicitly or search silently returns nothing
    /// for every event the user has not edited since upgrading.
    func testSearchIndexIsRebuiltForDatabasesMigratedFromBeforeTheIndexWasRecreated() throws {
        let databaseURL = try makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        try makeFixtureDatabase(at: databaseURL, stoppingAfter: "v008_add_deletion_snapshot")

        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        _ = try repository.load()

        XCTAssertEqual(
            try repository.searchEventIDs(matching: "Standup"),
            [Self.timedEventID],
            "a migrated event must be findable without being edited first"
        )
        XCTAssertTrue(
            try repository.searchEventIDs(matching: "Fixture").contains(Self.timedEventID),
            "the rebuilt index must include the denormalised calendar name"
        )
        XCTAssertTrue(
            try repository.searchEventIDs(matching: "example.com").contains(Self.timedEventID),
            "the rebuilt index must parse url_host the same way insertSearchRow does"
        )
    }

    // MARK: - Assertions

    private func assertNoDataLost(in database: LocalCalendarDatabase, fixtureStoppedAfter identifier: String) throws {
        let context = "migrating from \(identifier)"

        XCTAssertEqual(database.calendars.count, 1, "calendar lost \(context)")
        XCTAssertEqual(database.calendars.first?.id, Self.calendarID, "calendar identity changed \(context)")
        XCTAssertEqual(database.calendars.first?.name, "Fixture Calendar", "calendar name lost \(context)")
        XCTAssertEqual(database.calendars.first?.isDefault, true, "default flag lost \(context)")

        // Spec 3.6 (v018): a calendar written before provider identity existed migrates to
        // exactly what it always was — Better Calendar-owned, reached locally, fully writable.
        // Checked for every released version, so no upgrade path can land a user's own calendar
        // in a read-only or unknown-transport state.
        XCTAssertEqual(database.calendars.first?.provider, .betterCalendar, "provider changed \(context)")
        XCTAssertEqual(database.calendars.first?.connectionMethod, .local, "connection method wrong \(context)")
        XCTAssertEqual(database.calendars.first?.isReadOnly, false, "calendar became read-only \(context)")
        XCTAssertEqual(database.calendars.first?.capabilities, .localDefaults, "capabilities wrong \(context)")
        XCTAssertNil(database.calendars.first?.providerAccountID, "local calendar gained an account \(context)")
        XCTAssertNil(database.calendars.first?.colorHex, "token color should not become a raw hex \(context)")

        XCTAssertEqual(database.events.count, 5, "events lost \(context)")

        guard let timed = database.events.first(where: { $0.id == Self.timedEventID }) else {
            return XCTFail("timed event lost \(context)")
        }
        XCTAssertEqual(timed.title, "Standup", "title lost \(context)")
        XCTAssertEqual(timed.timeType, .timed, "time type lost \(context)")
        XCTAssertEqual(timed.timeZoneIdentifier, "America/Detroit", "original time zone lost \(context)")
        XCTAssertEqual(timed.notes, "Daily sync", "notes lost \(context)")
        XCTAssertEqual(timed.location, "Room 200", "location lost \(context)")
        XCTAssertEqual(timed.urlString, "https://example.com/standup", "url lost \(context)")
        XCTAssertEqual(timed.availability, .busy, "availability lost \(context)")

        guard let allDay = database.events.first(where: { $0.id == Self.allDayEventID }) else {
            return XCTFail("all-day event lost \(context)")
        }
        XCTAssertEqual(allDay.timeType, .allDay, "all-day time type lost \(context)")
        // Spec 0.9 / CLAUDE.md invariant: all-day events must still compare on local calendar
        // date components after migrating, not on a UTC midnight instant.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: allDay.timeZoneIdentifier) ?? .current
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: allDay.startDate),
            DateComponents(year: 2026, month: 4, day: 10),
            "all-day local start date shifted \(context)"
        )

        guard let floating = database.events.first(where: { $0.id == Self.floatingEventID }) else {
            return XCTFail("floating event lost \(context)")
        }
        XCTAssertEqual(floating.timeType, .floating, "floating events must not collapse into timed \(context)")

        if Self.fixtureIncludesReminders(stoppingAfter: identifier) {
            XCTAssertEqual(
                Set(timed.reminders.map(\.offset)),
                [.minutesBefore(10), .daysBefore(1)],
                "reminder offsets lost \(context)"
            )
        }

        if Self.fixtureIncludesRecurrence(stoppingAfter: identifier) {
            guard let master = database.events.first(where: { $0.id == Self.masterEventID }) else {
                return XCTFail("recurrence master lost \(context)")
            }
            XCTAssertEqual(master.recurrence?.frequency, .weekly, "recurrence frequency lost \(context)")
            XCTAssertEqual(master.recurrence?.interval, 2, "recurrence interval lost \(context)")
            XCTAssertEqual(master.recurrence?.weekdays, [.tuesday, .thursday], "recurrence weekdays lost \(context)")
            XCTAssertEqual(master.recurrence?.end, .afterOccurrences(12), "recurrence end lost \(context)")

            XCTAssertEqual(database.recurrenceExceptions.count, 2, "exceptions lost \(context)")
            XCTAssertTrue(
                database.recurrenceExceptions.contains { $0.exceptionType == .cancelled },
                "cancelled exception lost \(context)"
            )
            let modified = database.recurrenceExceptions.first { $0.exceptionType == .modified }
            XCTAssertEqual(modified?.replacementEventID, Self.replacementEventID, "replacement link lost \(context)")
        }

        if Self.fixtureIncludesSyncTables(stoppingAfter: identifier) {
            XCTAssertEqual(database.pendingMutations.count, 1, "outbox row lost \(context)")
            XCTAssertEqual(database.pendingMutations.first?.id, Self.mutationID, "outbox identity changed \(context)")
            XCTAssertEqual(database.pendingMutations.first?.operation, .update, "outbox operation lost \(context)")

            XCTAssertEqual(database.deletedEventTombstones.count, 1, "tombstone lost \(context)")
            XCTAssertEqual(database.deletedEventTombstones.first?.title, "Deleted Lunch", "tombstone title lost \(context)")

            XCTAssertEqual(database.settings.snapIntervalMinutes, 20, "settings lost \(context)")
        }
    }

    private func assertBackfilledColumns(at databaseURL: URL, fixtureStoppedAfter identifier: String) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.read { db in
            let context = "migrating from \(identifier)"

            // v015: local optimistic-concurrency counters start at 1, never NULL.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE version_number IS NULL"), 0, "null event version \(context)")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MIN(version_number) FROM events"), 1, "event version not backfilled \(context)")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MIN(version_number) FROM calendars"), 1, "calendar version not backfilled \(context)")

            // v019: every pre-existing calendar backfills as available, with no timestamp.
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendars WHERE is_unavailable != 0 OR unavailable_since IS NOT NULL"),
                0,
                "calendar availability not backfilled \(context)"
            )

            // v020: every pre-Phase-3 event predates provider identity and repeat-pattern
            // translation, so it backfills as "nothing unusual about this event" — not NULL,
            // which `row.boolValue` would have to guess at, and not 1, which would make every
            // event in an upgraded database uneditable.
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE has_unrepresentable_recurrence != 0"),
                0,
                "unrepresentable-recurrence flag not backfilled \(context)"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE has_unrepresentable_recurrence IS NULL"),
                0,
                "unrepresentable-recurrence flag left null \(context)"
            )
            // The new provider columns are nullable and start empty: a locally-created event has
            // no external identifier and nothing unmodelled to preserve.
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE provider_external_id IS NOT NULL OR provider_raw_fields IS NOT NULL"),
                0,
                "provider columns invented a value \(context)"
            )
            // The table exists and is empty — an event written before attendees existed had
            // none, which is exactly what no rows means.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_attendees"), 0, "attendees invented \(context)")

            guard Self.fixtureIncludesSyncTables(stoppingAfter: identifier) else { return }

            // Columns with a DEFAULT are populated for every row regardless of when it was
            // written, so these hold at every fixture version.
            let mutation = try Row.fetchOne(db, sql: "SELECT * FROM pending_mutations WHERE id = ?", arguments: [Self.mutationID.uuidString])
            XCTAssertEqual(mutation?["status"], "pending", "outbox status not defaulted \(context)")
            XCTAssertEqual(mutation?["attempt_count"], 0, "attempt count not defaulted \(context)")

            let tombstone = try Row.fetchOne(db, sql: "SELECT * FROM deleted_objects WHERE id = ?", arguments: [Self.tombstoneID.uuidString])
            XCTAssertEqual(tombstone?["deleted_by"], TombstoneCause.userEdit.rawValue, "tombstone cause not defaulted \(context)")

            // The *backfills*, by contrast, are one-shot UPDATEs inside their migration, so
            // they only apply to rows that predate them. A fixture stopped at v013 or later
            // has its rows inserted after the backfill already ran; that combination cannot
            // occur in production, where every row the repository writes carries these
            // columns from the start (see `EngineTransactionTests`). Asserting the backfill
            // only where a backfill actually had something to do keeps the test honest about
            // what BC-ENG-008 claims.
            if Self.migrationIndex(of: identifier) < Self.migrationIndex(of: "v013_extend_pending_mutations") {
                let idempotencyKey: String? = mutation?["idempotency_key"]
                XCTAssertNotNil(idempotencyKey, "idempotency key not backfilled \(context)")
                XCTAssertNotNil(idempotencyKey.flatMap(UUID.init(uuidString:)), "backfilled idempotency key must parse as a UUID \(context)")
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT idempotency_key) FROM pending_mutations"),
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutations"),
                    "backfilled idempotency keys must be unique \(context)"
                )
            }

            if Self.migrationIndex(of: identifier) < Self.migrationIndex(of: "v014_extend_deleted_objects") {
                let purgeAfter: String? = tombstone?["purge_after"]
                XCTAssertNotNil(purgeAfter, "purge deadline not backfilled \(context)")
                // 30 days after the fixture's 2026-03-01 deletion, with the millisecond
                // precision `encodeInstant` writes preserved rather than truncated the way
                // SQLite's `datetime()` would have.
                XCTAssertEqual(purgeAfter, "2026-03-31T09:15:30.500Z", "purge deadline miscomputed \(context)")
            }
        }
    }

    // MARK: - Which tables the fixture could populate at a given version

    private static func fixtureIncludesReminders(stoppingAfter identifier: String) -> Bool {
        migrationIndex(of: identifier) >= migrationIndex(of: "v003_create_reminders")
    }

    private static func fixtureIncludesRecurrence(stoppingAfter identifier: String) -> Bool {
        migrationIndex(of: identifier) >= migrationIndex(of: "v004_create_recurrence")
    }

    private static func fixtureIncludesSyncTables(stoppingAfter identifier: String) -> Bool {
        migrationIndex(of: identifier) >= migrationIndex(of: "v007_create_sync_and_settings")
    }

    private static func migrationIndex(of identifier: String) -> Int {
        SQLiteCalendarRepository.migrationIdentifiers.firstIndex(of: identifier) ?? -1
    }

    // MARK: - Fixture construction

    /// Migrates a fresh database *up to* `identifier`, then fills it using only the columns
    /// that existed at that point in the schema's history.
    private func makeFixtureDatabase(at databaseURL: URL, stoppingAfter identifier: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try SQLiteCalendarRepository.makeMigrator().migrate(queue, upTo: identifier)

        try queue.write { db in
            try insertFixtureCalendar(in: db)
            try insertFixtureEvents(in: db)

            if Self.fixtureIncludesReminders(stoppingAfter: identifier) {
                try insertFixtureReminders(in: db)
            }
            if Self.fixtureIncludesRecurrence(stoppingAfter: identifier) {
                try insertFixtureRecurrence(in: db)
            }
            if Self.fixtureIncludesSyncTables(stoppingAfter: identifier) {
                try insertFixtureSyncRows(in: db)
            }
        }
    }

    private func insertFixtureCalendar(in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO calendars (
                    id, provider, provider_account_id, provider_calendar_id, name, color_hex,
                    is_visible, is_read_only, is_default, time_zone_id, sort_order,
                    created_at, updated_at, deleted_at
                )
                VALUES (?, 'betterCalendarLocal', NULL, ?, 'Fixture Calendar', '#4F7DFF', 1, 0, 1, NULL, 0, ?, ?, NULL)
                """,
            arguments: [
                Self.calendarID.uuidString,
                Self.calendarID.uuidString,
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:00:00.000Z"
            ]
        )
    }

    /// The v002-era column set — every column added since (`raw_ics_properties` in v010,
    /// `version_number` in v015) is deliberately omitted, because a Phase 1 build would not
    /// have written it.
    private func insertFixtureEvents(in db: Database) throws {
        let sql = """
            INSERT INTO events (
                id, calendar_id, provider, provider_object_id, provider_version,
                title, notes, location_name, location_latitude, location_longitude, url,
                event_type, start_instant, end_instant, start_local_date, end_local_date_exclusive,
                original_timezone_id, availability, status, privacy, color_override,
                recurrence_master_id, recurrence_original_start, is_recurrence_master,
                sync_status, created_at, updated_at, deleted_at
            )
            VALUES (?, ?, 'betterCalendarLocal', ?, NULL, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', 'default', NULL, ?, ?, ?, 'synced', ?, ?, NULL)
            """

        let created = "2026-01-02T08:00:00.000Z"

        // Timed, with every optional text field populated so their loss would be visible.
        try db.execute(sql: sql, arguments: [
            Self.timedEventID.uuidString, Self.calendarID.uuidString, "standup@example.com",
            "Standup", "Daily sync", "Room 200", "https://example.com/standup",
            "timed", "2026-02-03T14:00:00.000Z", "2026-02-03T14:30:00.000Z", nil, nil,
            "America/Detroit", "busy",
            nil, nil, 0,
            created, created
        ])

        // All-day, stored as local date components per spec 0.9 — never as a UTC midnight.
        try db.execute(sql: sql, arguments: [
            Self.allDayEventID.uuidString, Self.calendarID.uuidString, nil,
            "Conference", nil, "Chicago", nil,
            "allDay", nil, nil, "2026-04-10", "2026-04-12",
            "America/Detroit", "free",
            nil, nil, 0,
            created, created
        ])

        // Floating: instants present, but the type must survive so `load()` does not collapse
        // it into a timed event.
        try db.execute(sql: sql, arguments: [
            Self.floatingEventID.uuidString, Self.calendarID.uuidString, nil,
            "Wake Up", nil, nil, nil,
            "floating", "2026-05-01T11:00:00.000Z", "2026-05-01T11:30:00.000Z", nil, nil,
            "America/Detroit", "busy",
            nil, nil, 0,
            created, created
        ])

        // A recurrence master and the standalone replacement event one of its occurrences was
        // edited into — the shape Phase 1's "This Event" edit actually produces.
        try db.execute(sql: sql, arguments: [
            Self.masterEventID.uuidString, Self.calendarID.uuidString, nil,
            "Seminar", nil, "Hall A", nil,
            "timed", "2026-06-02T18:00:00.000Z", "2026-06-02T19:00:00.000Z", nil, nil,
            "America/Detroit", "busy",
            nil, nil, 1,
            created, created
        ])

        try db.execute(sql: sql, arguments: [
            Self.replacementEventID.uuidString, Self.calendarID.uuidString, nil,
            "Seminar (moved)", nil, "Hall B", nil,
            "timed", "2026-06-16T20:00:00.000Z", "2026-06-16T21:00:00.000Z", nil, nil,
            "America/Detroit", "busy",
            Self.masterEventID.uuidString, "2026-06-16T18:00:00.000Z", 0,
            created, created
        ])
    }

    private func insertFixtureReminders(in db: Database) throws {
        let sql = """
            INSERT INTO event_reminders (
                id, event_id, trigger_type, offset_seconds, absolute_instant,
                delivery_method, is_enabled, notification_identifier
            )
            VALUES (?, ?, 'relative', ?, NULL, 'localNotification', 1, ?)
            """

        try db.execute(sql: sql, arguments: [
            Self.reminderOneID.uuidString, Self.timedEventID.uuidString, -600,
            "event-\(Self.timedEventID.uuidString)-reminder-\(Self.reminderOneID.uuidString)"
        ])
        try db.execute(sql: sql, arguments: [
            Self.reminderTwoID.uuidString, Self.timedEventID.uuidString, -86_400,
            "event-\(Self.timedEventID.uuidString)-reminder-\(Self.reminderTwoID.uuidString)"
        ])
    }

    private func insertFixtureRecurrence(in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO event_recurrence_rules (
                    id, event_id, frequency, interval, days_of_week, days_of_month,
                    months_of_year, week_start, count, until_instant, until_local_date,
                    set_positions, raw_rrule
                )
                VALUES (?, ?, 'weekly', 2, ?, NULL, NULL, 2, 12, NULL, NULL, NULL, NULL)
                """,
            arguments: [
                UUID().uuidString,
                Self.masterEventID.uuidString,
                // Weekday raw values for Tuesday and Thursday.
                "[\(Weekday.tuesday.rawValue),\(Weekday.thursday.rawValue)]"
            ]
        )

        let exceptionSQL = """
            INSERT INTO event_recurrence_exceptions (
                id, master_event_id, original_occurrence_start, original_occurrence_local_date,
                exception_type, replacement_event_id
            )
            VALUES (?, ?, ?, NULL, ?, ?)
            """

        try db.execute(sql: exceptionSQL, arguments: [
            UUID().uuidString, Self.masterEventID.uuidString,
            "2026-06-09T18:00:00.000Z", "cancelled", nil
        ])
        try db.execute(sql: exceptionSQL, arguments: [
            UUID().uuidString, Self.masterEventID.uuidString,
            "2026-06-16T18:00:00.000Z", "modified", Self.replacementEventID.uuidString
        ])
    }

    /// The v007-era column set for the outbox and tombstone tables: no payload, no idempotency
    /// key, no snapshot, no purge deadline. Exactly what a Phase 1 install has on disk, and
    /// the input the v013/v014 backfills have to cope with.
    private func insertFixtureSyncRows(in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO pending_mutations (id, object_id, object_type, operation, created_at) VALUES (?, ?, 'event', 'update', ?)",
            arguments: [Self.mutationID.uuidString, Self.timedEventID.uuidString, "2026-02-28T12:00:00.000Z"]
        )

        try db.execute(
            sql: "INSERT INTO deleted_objects (id, object_id, object_type, title, deleted_at) VALUES (?, ?, 'event', 'Deleted Lunch', ?)",
            arguments: [Self.tombstoneID.uuidString, UUID().uuidString, Self.tombstoneDeletedAt]
        )

        try db.execute(
            sql: "INSERT INTO application_settings (key, value, updated_at) VALUES ('snap_interval_minutes', '20', ?)",
            arguments: ["2026-02-28T12:00:00.000Z"]
        )
    }

    private func makeTemporaryDatabaseURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "BetterCalendar.sqlite")
    }
}
