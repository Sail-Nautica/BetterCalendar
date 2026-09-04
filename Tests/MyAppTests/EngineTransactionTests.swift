import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 2.2: the incremental, transactional write path that replaces Phase 1's
/// wipe-and-reinsert `save`.
///
/// The load-bearing property is that an `EngineTransaction` means the same thing to both of
/// its consumers — the pure in-memory `applying(_:)` and the SQLite `apply(_:)`. If those two
/// ever disagree, the store's optimistic in-memory update and what is actually on disk drift
/// apart, and the rollback envelope in `withPersistedMutation` starts restoring a state that
/// was never true.
final class EngineTransactionTests: XCTestCase {

    // MARK: - The two consumers agree

    func testSQLiteApplyAndInMemoryApplyingProduceTheSameDatabase() throws {
        let fixture = try makeSeededRepository()

        let newEvent = TestData.event(
            id: UUID(),
            calendarID: TestData.calendarID,
            title: "Added",
            startDate: TestData.date("2026-09-05T09:00:00Z"),
            endDate: TestData.date("2026-09-05T10:00:00Z")
        )
        var editedEvent = fixture.database.events[0]
        editedEvent.title = "Renamed"
        editedEvent.location = "Room 41"

        let transaction = EngineTransaction(
            entityChanges: [
                .upsertEvent(newEvent),
                .upsertEvent(editedEvent),
                .upsertCalendar(TestData.calendar(name: "Renamed Calendar"))
            ]
        )

        try fixture.repository.apply(transaction)

        let fromDisk = try fixture.repository.load()
        let inMemory = fixture.database.applying(transaction)

        assertEquivalent(fromDisk, inMemory)
    }

    func testAppliedEventIsReadBackWithItsRemindersAndRecurrence() throws {
        let fixture = try makeSeededRepository()

        var event = TestData.event(
            id: UUID(),
            title: "Seminar",
            startDate: TestData.date("2026-10-06T18:00:00Z"),
            endDate: TestData.date("2026-10-06T19:00:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.tuesday], end: .afterOccurrences(8))
        )
        event.reminders = [
            EventReminder(id: UUID(), offset: .minutesBefore(15)),
            EventReminder(id: UUID(), offset: .daysBefore(1))
        ]

        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(event)]))

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.title, "Seminar")
        XCTAssertEqual(reloaded.recurrence?.frequency, .weekly)
        XCTAssertEqual(reloaded.recurrence?.interval, 2)
        XCTAssertEqual(reloaded.recurrence?.end, .afterOccurrences(8))
        XCTAssertEqual(Set(reloaded.reminders.map(\.offset)), [.minutesBefore(15), .daysBefore(1)])
    }

    /// An upsert replaces an event's owned child rows rather than accumulating them. Without
    /// this, editing an event five times would leave it with five copies of every reminder
    /// and five notifications firing.
    func testUpsertingAnEventReplacesRatherThanDuplicatesItsChildRows() throws {
        let fixture = try makeSeededRepository()

        var event = TestData.event(id: UUID(), title: "Lab", startDate: TestData.date("2026-10-07T18:00:00Z"), endDate: TestData.date("2026-10-07T19:00:00Z"))
        event.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(30))]
        event.recurrence = RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], end: .afterOccurrences(3))
        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(event)]))

        event.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(5))]
        event.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(event)]))

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.reminders.map(\.offset), [.minutesBefore(5)])
        XCTAssertEqual(reloaded.recurrence?.frequency, .weekly)

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_reminders WHERE event_id = ?", arguments: [event.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_recurrence_rules WHERE event_id = ?", arguments: [event.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_search WHERE event_id = ?", arguments: [event.id.uuidString]), 1)
        }
    }

    // MARK: - Spec 2.14: the version counter round-trips through the incremental path

    /// M1 left `version_number` out of the upsert column list entirely, because
    /// `CalendarEvent`/`BetterCalendar` carried no such field yet. M2 adds the field, and from
    /// here on the domain value is authoritative: whatever `versionNumber` the caller (in
    /// practice, `EventMutationUseCases`, which is the only code that increments it) puts on
    /// the struct is what lands in the column.
    func testUpsertWritesTheEventsVersionNumberFromTheDomainValue() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        var edited = event
        edited.title = "Edited after several versions"
        edited.versionNumber = 7
        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(edited)]))

        try fixture.readDatabase { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT version_number FROM events WHERE id = ?", arguments: [event.id.uuidString]),
                7,
                "an upsert writes the version number carried on the domain value"
            )
        }

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.versionNumber, 7)
    }

    func testUpsertWritesTheCalendarsVersionNumberFromTheDomainValue() throws {
        let fixture = try makeSeededRepository()

        var edited = TestData.calendar(name: "Edited")
        edited.versionNumber = 4
        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertCalendar(edited)]))

        try fixture.readDatabase { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT version_number FROM calendars WHERE id = ?", arguments: [TestData.calendarID.uuidString]),
                4,
                "an upsert writes the version number carried on the domain value"
            )
        }
    }

    // MARK: - Spec 2.13: the tombstone rides with the delete

    func testDeletingAnEventAndWritingItsTombstoneIsOneTransaction() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        let tombstone = DeletedEventTombstone(
            id: UUID(),
            eventID: event.id,
            title: event.title,
            deletedAt: TestData.date("2026-09-10T12:00:00Z"),
            eventSnapshotJSON: event.encodedSnapshotJSON(),
            deletionSyncedAt: nil
        )

        try fixture.repository.apply(EngineTransaction(
            entityChanges: [.deleteEvent(event.id)],
            tombstones: [tombstone]
        ))

        let reloaded = try fixture.repository.load()
        XCTAssertFalse(reloaded.events.contains { $0.id == event.id })
        XCTAssertEqual(reloaded.deletedEventTombstones.map(\.eventID), [event.id])
        XCTAssertNotNil(reloaded.deletedEventTombstones.first?.eventSnapshotJSON)

        // Spec 2.13's stored retention deadline, written alongside the tombstone rather than
        // computed on read.
        try fixture.readDatabase { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM deleted_objects WHERE id = ?", arguments: [tombstone.id.uuidString]))
            XCTAssertEqual(row["deleted_by"], TombstoneCause.userEdit.rawValue)
            let purgeAfter: String = try XCTUnwrap(row["purge_after"])
            XCTAssertTrue(purgeAfter.hasPrefix("2026-10-10T"), "expected 30 days after deletion, got \(purgeAfter)")
        }
    }

    func testRemovingATombstoneDeletesItsRow() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let tombstone = DeletedEventTombstone(
            id: UUID(),
            eventID: event.id,
            title: event.title,
            deletedAt: TestData.date("2026-09-10T12:00:00Z"),
            eventSnapshotJSON: nil,
            deletionSyncedAt: nil
        )

        try fixture.repository.apply(EngineTransaction(entityChanges: [.deleteEvent(event.id)], tombstones: [tombstone]))
        try fixture.repository.apply(EngineTransaction(removedTombstoneIDs: [tombstone.id]))

        XCTAssertTrue(try fixture.repository.load().deletedEventTombstones.isEmpty)
    }

    // MARK: - Atomicity

    /// The whole point of routing a mutation through one transaction: a failure part-way
    /// through leaves nothing behind. Here the second change violates the foreign key on
    /// `events.calendar_id`, and the first must not survive it.
    func testAFailedTransactionRollsBackEveryChangeInIt() throws {
        let fixture = try makeSeededRepository()

        let validEvent = TestData.event(id: UUID(), title: "Should not persist", startDate: TestData.date("2026-09-06T09:00:00Z"), endDate: TestData.date("2026-09-06T10:00:00Z"))
        let danglingEvent = TestData.event(
            id: UUID(),
            calendarID: UUID(), // no such calendar
            title: "Dangling",
            startDate: TestData.date("2026-09-07T09:00:00Z"),
            endDate: TestData.date("2026-09-07T10:00:00Z")
        )

        XCTAssertThrowsError(
            try fixture.repository.apply(EngineTransaction(entityChanges: [
                .upsertEvent(validEvent),
                .upsertEvent(danglingEvent)
            ]))
        )

        let reloaded = try fixture.repository.load()
        XCTAssertFalse(
            reloaded.events.contains { $0.id == validEvent.id },
            "a change that preceded the failure must be rolled back with it"
        )
        XCTAssertFalse(reloaded.events.contains { $0.id == danglingEvent.id })
        XCTAssertEqual(reloaded.events.count, fixture.database.events.count)
    }

    func testEmptyTransactionIsANoOp() throws {
        let fixture = try makeSeededRepository()
        let before = try fixture.repository.load()

        try fixture.repository.apply(.empty)

        assertEquivalent(try fixture.repository.load(), before)
    }

    // MARK: - Ordering constraints

    /// `calendars_one_default_idx` is a partial unique index and SQLite has no deferred
    /// constraints, so a default swap is only expressible in one transaction if the clearing
    /// write is ordered before the setting write.
    func testSwappingTheDefaultCalendarInOneTransactionDoesNotTripTheUniqueIndex() throws {
        let fixture = try makeSeededRepository()

        let oldDefault = TestData.calendar(id: TestData.calendarID, name: "School", isDefault: false)
        let newDefault = TestData.calendar(id: TestData.secondCalendarID, name: "Personal", isDefault: true, sortOrder: 1)

        // Deliberately listed in the order that would fail if applied verbatim.
        try fixture.repository.apply(EngineTransaction(entityChanges: [
            .upsertCalendar(newDefault),
            .upsertCalendar(oldDefault)
        ]))

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.calendars.filter(\.isDefault).map(\.id), [TestData.secondCalendarID])
        XCTAssertEqual(
            reloaded.calendars.filter(\.isDefault).map(\.id),
            fixture.database.applying(EngineTransaction(entityChanges: [
                .upsertCalendar(newDefault),
                .upsertCalendar(oldDefault)
            ])).calendars.filter(\.isDefault).map(\.id)
        )
    }

    func testDeletingACalendarRemovesItsEventsAndTheirSearchRows() throws {
        let fixture = try makeSeededRepository()

        try fixture.repository.apply(EngineTransaction(entityChanges: [.deleteCalendar(TestData.calendarID)]))

        let reloaded = try fixture.repository.load()
        XCTAssertFalse(reloaded.calendars.contains { $0.id == TestData.calendarID })
        XCTAssertTrue(reloaded.events.allSatisfy { $0.calendarID != TestData.calendarID })

        // `event_search` is an FTS5 virtual table with no foreign keys, so the cascade cannot
        // reach it — leaked rows would keep returning deleted events from search.
        try fixture.readDatabase { db in
            let orphaned = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM event_search
                WHERE event_id NOT IN (SELECT id FROM events)
                """)
            XCTAssertEqual(orphaned, 0, "search rows for cascade-deleted events must be swept explicitly")
        }
    }

    func testDeletingAReplacementEventClearsTheExceptionsPointerWithoutDroppingTheException() throws {
        let fixture = try makeSeededRepository()

        let master = TestData.event(id: UUID(), title: "Master", startDate: TestData.date("2026-11-03T18:00:00Z"), endDate: TestData.date("2026-11-03T19:00:00Z"), recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.tuesday], end: .afterOccurrences(5)))
        let replacement = TestData.event(id: UUID(), title: "Moved occurrence", startDate: TestData.date("2026-11-10T20:00:00Z"), endDate: TestData.date("2026-11-10T21:00:00Z"))
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-11-10T18:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .modified,
            replacementEventID: replacement.id
        )

        let setup = EngineTransaction(entityChanges: [
            .upsertEvent(master),
            .upsertEvent(replacement),
            .upsertRecurrenceException(exception)
        ])
        try fixture.repository.apply(setup)

        let deletion = EngineTransaction(entityChanges: [.deleteEvent(replacement.id)])
        try fixture.repository.apply(deletion)

        let fromDisk = try fixture.repository.load()
        let survivor = try XCTUnwrap(fromDisk.recurrenceExceptions.first { $0.id == exception.id })
        XCTAssertNil(survivor.replacementEventID, "ON DELETE SET NULL: the occurrence stays excepted, it does not come back")
        XCTAssertEqual(survivor.exceptionType, .modified)

        // And the pure consumer models the same cascade.
        let inMemory = fixture.database.applying(setup).applying(deletion)
        assertEquivalent(fromDisk, inMemory)
    }

    func testDeletingAMasterEventRemovesItsExceptions() throws {
        let fixture = try makeSeededRepository()

        let master = TestData.event(id: UUID(), title: "Master", startDate: TestData.date("2026-11-03T18:00:00Z"), endDate: TestData.date("2026-11-03T19:00:00Z"))
        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-11-10T18:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )

        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(master), .upsertRecurrenceException(exception)]))
        try fixture.repository.apply(EngineTransaction(entityChanges: [.deleteEvent(master.id)]))

        XCTAssertTrue(try fixture.repository.load().recurrenceExceptions.isEmpty)
    }

    // MARK: - Search index maintenance

    func testUpsertingAnEventKeepsTheSearchIndexCurrent() throws {
        let fixture = try makeSeededRepository()
        var event = fixture.database.events[0]

        event.title = "Thermodynamics"
        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(event)]))

        XCTAssertEqual(try fixture.repository.searchEventIDs(matching: "Thermodynamics"), [event.id])
        XCTAssertTrue(
            try fixture.repository.searchEventIDs(matching: "Calculus").isEmpty,
            "the previous title must not linger in the index"
        )
    }

    /// The index denormalises the calendar name, so renaming a calendar has to push the new
    /// name into every row that copied it.
    func testRenamingACalendarRefreshesTheDenormalisedNameInTheSearchIndex() throws {
        let fixture = try makeSeededRepository()

        try fixture.repository.apply(EngineTransaction(entityChanges: [
            .upsertCalendar(TestData.calendar(name: "Engineering"))
        ]))

        XCTAssertEqual(try fixture.repository.searchEventIDs(matching: "Engineering"), [TestData.eventID])
        XCTAssertTrue(try fixture.repository.searchEventIDs(matching: "School").isEmpty)
    }

    // MARK: - Spec 2.8/2.9: history outlives a bulk save

    /// `save` still exists for bulk paths, and it must not erase the append-only journal on
    /// its way past. M2 starts writing these tables; M1 only has to guarantee the bulk path
    /// leaves them alone.
    func testBulkSaveDoesNotEraseTheChangeJournalOrVersionHistory() throws {
        let fixture = try makeSeededRepository()

        let journalID = UUID()
        try fixture.writeDatabase { db in
            try db.execute(
                sql: """
                    INSERT INTO change_journal (id, entity_type, entity_id, operation, field_diff, source, occurred_at, applied_mutation_id)
                    VALUES (?, ?, ?, 'update', '{}', 'userEdit', ?, NULL)
                    """,
                arguments: [journalID.uuidString, EngineEntityType.event.rawValue, TestData.eventID.uuidString, "2026-09-01T12:00:00.000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO event_versions (id, event_id, version_number, snapshot_json, created_at, change_journal_entry_id)
                    VALUES (?, ?, 1, '{}', ?, ?)
                    """,
                arguments: [UUID().uuidString, TestData.eventID.uuidString, "2026-09-01T12:00:00.000Z", journalID.uuidString]
            )
        }

        try fixture.repository.save(fixture.database)

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal"), 1, "spec 2.8: the journal is append-only")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_versions"), 1, "spec 2.9: version history survives a bulk save")
        }
    }

    // MARK: - The other two repositories

    func testJSONRepositoryApplyMatchesInMemoryApplying() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EngineTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = JSONCalendarRepository(fileURL: directory.appending(path: "db.json"))
        let seeded = TestData.database()
        try repository.save(seeded)

        let transaction = EngineTransaction(entityChanges: [
            .upsertEvent(TestData.event(id: UUID(), title: "Added", startDate: TestData.date("2026-09-08T09:00:00Z"), endDate: TestData.date("2026-09-08T10:00:00Z")))
        ])
        try repository.apply(transaction)

        assertEquivalent(try repository.load(), seeded.applying(transaction))
    }

    func testStubRepositoryApplyIsObservableOnReload() throws {
        let repository = StubCalendarRepository()
        let seeded = try repository.load()

        let added = TestData.event(id: UUID(), title: "Added", startDate: TestData.date("2026-09-09T09:00:00Z"), endDate: TestData.date("2026-09-09T10:00:00Z"))
        try repository.apply(EngineTransaction(entityChanges: [.upsertEvent(added)]))

        XCTAssertEqual(repository.appliedTransactions.count, 1)
        XCTAssertTrue(try repository.load().events.contains { $0.id == added.id })
        XCTAssertEqual(try repository.load().events.count, seeded.events.count + 1)
    }

    // MARK: - Pure `applying` semantics

    func testApplyingSortsEventsByStartDate() {
        let early = TestData.event(id: UUID(), title: "Early", startDate: TestData.date("2026-09-01T08:00:00Z"), endDate: TestData.date("2026-09-01T09:00:00Z"))
        let late = TestData.event(id: UUID(), title: "Late", startDate: TestData.date("2026-09-30T08:00:00Z"), endDate: TestData.date("2026-09-30T09:00:00Z"))

        let result = TestData.database(events: []).applying(EngineTransaction(entityChanges: [
            .upsertEvent(late),
            .upsertEvent(early)
        ]))

        XCTAssertEqual(result.events.map(\.title), ["Early", "Late"])
    }

    func testApplyingAnUpsertForAnExistingIDReplacesRatherThanAppends() {
        let database = TestData.database()
        var edited = database.events[0]
        edited.title = "Replaced"

        let result = database.applying(EngineTransaction(entityChanges: [.upsertEvent(edited)]))

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].title, "Replaced")
    }

    func testOrderedChangesPutsDeletesAfterUpsertsAndParentsBeforeChildren() {
        let transaction = EngineTransaction(entityChanges: [
            .deleteCalendar(UUID()),
            .upsertRecurrenceException(RecurrenceException(id: UUID(), masterEventID: UUID(), originalOccurrenceStart: nil, originalOccurrenceLocalDate: "2026-01-01", exceptionType: .cancelled, replacementEventID: nil)),
            .deleteEvent(UUID()),
            .upsertEvent(TestData.event()),
            .upsertCalendar(TestData.calendar())
        ])

        let kinds = transaction.orderedChanges.map(kindLabel)
        XCTAssertEqual(kinds, ["upsertCalendar", "upsertEvent", "upsertException", "deleteEvent", "deleteCalendar"])
    }

    func testIsEmptyOnlyWhenNothingIsCarried() {
        XCTAssertTrue(EngineTransaction.empty.isEmpty)
        XCTAssertFalse(EngineTransaction(entityChanges: [.deleteEvent(UUID())]).isEmpty)
        XCTAssertFalse(EngineTransaction(removedTombstoneIDs: [UUID()]).isEmpty)
        XCTAssertFalse(EngineTransaction(settings: .defaultSettings).isEmpty)
    }

    // MARK: - Helpers

    private func kindLabel(_ change: EntityChange) -> String {
        switch change {
        case .upsertCalendar: "upsertCalendar"
        case .deleteCalendar: "deleteCalendar"
        case .upsertEvent: "upsertEvent"
        case .deleteEvent: "deleteEvent"
        case .upsertRecurrenceException: "upsertException"
        case .deleteRecurrenceException: "deleteException"
        }
    }

    /// Compares the parts of two databases that describe user data, keyed by identity rather
    /// than array position. Row order is a storage detail that the two consumers are not
    /// required to agree on; *contents* are exactly what they must agree on.
    private func assertEquivalent(
        _ lhs: LocalCalendarDatabase,
        _ rhs: LocalCalendarDatabase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.calendars.sorted { $0.id.uuidString < $1.id.uuidString },
                       rhs.calendars.sorted { $0.id.uuidString < $1.id.uuidString },
                       "calendars differ", file: file, line: line)
        XCTAssertEqual(lhs.events.sorted { $0.id.uuidString < $1.id.uuidString },
                       rhs.events.sorted { $0.id.uuidString < $1.id.uuidString },
                       "events differ", file: file, line: line)
        XCTAssertEqual(Set(lhs.recurrenceExceptions), Set(rhs.recurrenceExceptions), "recurrence exceptions differ", file: file, line: line)
        XCTAssertEqual(Set(lhs.deletedEventTombstones), Set(rhs.deletedEventTombstones), "tombstones differ", file: file, line: line)
        XCTAssertEqual(Set(lhs.pendingMutations), Set(rhs.pendingMutations), "pending mutations differ", file: file, line: line)
        XCTAssertEqual(lhs.settings, rhs.settings, "settings differ", file: file, line: line)
    }

    /// Spec 3C.1: the loader used to *invent* `providerCalendarID` from the row's `calendar_id`,
    /// which meant the same fact lived in two places — the event and the calendar it points at —
    /// and the event's copy was a local UUID rather than anything a provider would recognise.
    /// Phase 3C stops that: the calendar row carries the account and calendar identifiers, and
    /// the event carries neither.
    ///
    /// The consequence for this file is that `load()` and `applying(_:)` now agree on every
    /// field, so `assertDatabasesEqual` no longer normalises one away before comparing.
    func testLoadDoesNotInventProviderIdentityForAnEvent() throws {
        let fixture = try makeSeededRepository()
        let added = TestData.event(
            id: UUID(),
            calendarID: TestData.secondCalendarID,
            title: "Added",
            startDate: TestData.date("2026-09-11T09:00:00Z"),
            endDate: TestData.date("2026-09-11T10:00:00Z")
        )
        XCTAssertNil(added.providerMetadata.providerCalendarID)

        try fixture.repository.apply(EngineTransaction(entityChanges: [.upsertEvent(added)]))

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == added.id })
        XCTAssertNil(
            reloaded.providerMetadata.providerCalendarID,
            "an event's calendar already holds the provider calendar identifier; a second copy is one more than can be kept in agreement"
        )
        XCTAssertNil(reloaded.providerMetadata.providerAccountID)
    }

    /// The counterpart to the migration test's backfill assertions: rows the repository
    /// writes itself carry the spec 2.10/2.13 columns from the start, so the backfill is only
    /// ever needed for rows that predate the migration.
    func testRepositoryWrittenOutboxRowsCarryAnIdempotencyKey() throws {
        let fixture = try makeSeededRepository()
        let mutation = PendingMutation(
            id: UUID(),
            objectID: TestData.eventID,
            objectType: .event,
            operation: .update,
            createdAt: TestData.date("2026-09-12T09:00:00Z")
        )

        try fixture.repository.apply(EngineTransaction(outboxRows: [mutation]))

        try fixture.readDatabase { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM pending_mutations WHERE id = ?", arguments: [mutation.id.uuidString]))
            let key: String? = row["idempotency_key"]
            XCTAssertNotNil(key.flatMap(UUID.init(uuidString:)), "spec 2.10: an enqueued mutation always has an idempotency key")
            XCTAssertEqual(row["status"], "pending")
            XCTAssertEqual(row["attempt_count"], 0)
        }

        // Spec 2.10: the key is stable across rewrites of the same logical mutation, which is
        // what makes a retry safe to resend.
        let keyAfterFirstWrite = try fixture.readDatabase { db in
            try String.fetchOne(db, sql: "SELECT idempotency_key FROM pending_mutations WHERE id = ?", arguments: [mutation.id.uuidString])
        }
        try fixture.repository.apply(EngineTransaction(outboxRows: [mutation]))
        let keyAfterSecondWrite = try fixture.readDatabase { db in
            try String.fetchOne(db, sql: "SELECT idempotency_key FROM pending_mutations WHERE id = ?", arguments: [mutation.id.uuidString])
        }
        XCTAssertEqual(keyAfterFirstWrite, keyAfterSecondWrite)
        XCTAssertEqual(try fixture.repository.load().pendingMutations.count, 1, "re-applying the same mutation must not duplicate it")
    }

    private struct RepositoryFixture {
        let repository: SQLiteCalendarRepository
        let databaseURL: URL
        let database: LocalCalendarDatabase

        func readDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).read(body)
        }

        func writeDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).write(body)
        }
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeSeededRepository() throws -> RepositoryFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EngineTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)

        let seeded = TestData.database(
            calendars: [
                TestData.calendar(),
                TestData.calendar(id: TestData.secondCalendarID, name: "Personal", isDefault: false, sortOrder: 1)
            ]
        )
        try repository.save(seeded)

        // Read back rather than trusting the in-memory fixture: `load()` is what every later
        // comparison is against, and it applies the repository's own normalisation.
        return RepositoryFixture(repository: repository, databaseURL: databaseURL, database: try repository.load())
    }
}
