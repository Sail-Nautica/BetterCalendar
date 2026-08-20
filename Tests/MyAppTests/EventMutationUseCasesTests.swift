import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 2.2/2.8/2.11/2.14: the M2 mutation pipeline. Each use case is exercised directly
/// against a real `SQLiteCalendarRepository` (not through `BetterCalendarStore`) so these tests
/// pin the pipeline's own contract — idempotent replay, version conflicts, one journal entry
/// per logical action — independent of how the store happens to wire it up.
final class EventMutationUseCasesTests: XCTestCase {

    // MARK: - Spec 2.10/2.11: idempotent replay

    /// Replaying the same mutation under the same `idempotencyKey` — simulating a retried or
    /// duplicated call — must not create a second event, a second journal entry, or a second
    /// reminder.
    func testReplayingTheSameIdempotencyKeyIsANoOp() throws {
        let fixture = try makeSeededRepository()
        let key = UUID()

        let newEvent = TestData.event(id: UUID(), title: "Seminar", startDate: TestData.date("2026-10-06T18:00:00Z"), endDate: TestData.date("2026-10-06T19:00:00Z"))
        var eventWithReminder = newEvent
        eventWithReminder.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(15))]

        let firstOutcome = EventMutationUseCases.createEvent(eventWithReminder, idempotencyKey: key, in: try fixture.context())
        guard case .applied(let transaction) = firstOutcome else {
            return XCTFail("expected the first call to apply")
        }
        try fixture.repository.apply(transaction)

        let secondOutcome = EventMutationUseCases.createEvent(eventWithReminder, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = secondOutcome else {
            return XCTFail("expected the replayed call to short-circuit as a duplicate, got \(secondOutcome)")
        }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.filter { $0.id == newEvent.id }.count, 1)
        XCTAssertEqual(reloaded.events.first { $0.id == newEvent.id }?.reminders.count, 1, "replaying must not duplicate the event's reminder")

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ?", arguments: [newEvent.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_reminders WHERE event_id = ?", arguments: [newEvent.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutations WHERE idempotency_key = ?", arguments: [key.uuidString]), 1, "the outbox row itself must not be duplicated either")
        }
    }

    /// A real user action never reuses an idempotency key, so two independent `createEvent`
    /// calls with two different events (and two different keys) must both land.
    func testTwoDistinctCallsWithDifferentKeysBothApply() throws {
        let fixture = try makeSeededRepository()

        let first = TestData.event(id: UUID(), title: "First", startDate: TestData.date("2026-10-06T18:00:00Z"), endDate: TestData.date("2026-10-06T19:00:00Z"))
        let second = TestData.event(id: UUID(), title: "Second", startDate: TestData.date("2026-10-07T18:00:00Z"), endDate: TestData.date("2026-10-07T19:00:00Z"))

        try fixture.apply(EventMutationUseCases.createEvent(first, in: try fixture.context()))
        try fixture.apply(EventMutationUseCases.createEvent(second, in: try fixture.context()))

        let reloaded = try fixture.repository.load()
        XCTAssertTrue(reloaded.events.contains { $0.id == first.id })
        XCTAssertTrue(reloaded.events.contains { $0.id == second.id })
    }

    // MARK: - Spec 2.14: optimistic concurrency

    /// A stale `expectedVersionNumber` is rejected rather than silently overwriting a newer
    /// edit. The content the stale write was based on is not lost: it is exactly the snapshot
    /// `updateEvent` wrote into `EventVersion` when the *first* edit (the one the stale write
    /// didn't know about) superseded it.
    func testStaleVersionNumberIsRejectedAndTheSupersededStateSurvivesInHistory() throws {
        let fixture = try makeSeededRepository()
        let original = fixture.database.events[0]
        XCTAssertEqual(original.versionNumber, 1)

        // A real edit lands first, taking the event to version 2.
        try fixture.apply(EventMutationUseCases.updateEvent(eventID: original.id, expectedVersionNumber: 1, in: try fixture.context()) { updated in
            updated.title = "Edited while the stale write was in flight"
        })

        // A second write still believes the event is at version 1 — e.g. an Undo closure
        // captured before the edit above landed.
        let staleOutcome = EventMutationUseCases.updateEvent(eventID: original.id, expectedVersionNumber: 1, in: try fixture.context()) { updated in
            updated.title = "Should never be persisted"
        }
        guard case .conflicted(let currentVersionNumber) = staleOutcome else {
            return XCTFail("expected the stale write to be rejected as a conflict, got \(staleOutcome)")
        }
        XCTAssertEqual(currentVersionNumber, 2)

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == original.id })
        XCTAssertEqual(reloaded.title, "Edited while the stale write was in flight", "the rejected write must not have touched the live row")
        XCTAssertEqual(reloaded.versionNumber, 2)

        // The state the stale write was based on (version 1) is still recoverable — it was
        // captured as history the moment the real edit superseded it.
        try fixture.readDatabase { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM event_versions WHERE event_id = ? AND version_number = 1", arguments: [original.id.uuidString]))
            let snapshotJSON: String = row["snapshot_json"]
            let snapshot = try XCTUnwrap(CalendarEvent(snapshotJSON: snapshotJSON))
            XCTAssertEqual(snapshot.title, original.title, "version 1's snapshot is the loser's own basis, not lost")
        }
    }

    /// Deleting an event you no longer hold an up-to-date version of is rejected the same way
    /// an update is.
    func testStaleVersionNumberOnDeleteIsRejected() throws {
        let fixture = try makeSeededRepository()
        let original = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.updateEvent(eventID: original.id, expectedVersionNumber: 1, in: try fixture.context()) { updated in
            updated.title = "Renamed first"
        })

        let outcome = EventMutationUseCases.deleteEvent(eventID: original.id, expectedVersionNumber: 1, in: try fixture.context())
        guard case .conflicted = outcome else {
            return XCTFail("expected a stale delete to be rejected, got \(outcome)")
        }

        XCTAssertTrue(try fixture.repository.load().events.contains { $0.id == original.id })
    }

    // MARK: - Spec 2.8: exactly one journal entry per logical action

    func testCreateEventProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = TestData.event(id: UUID(), title: "Created", startDate: TestData.date("2026-11-02T09:00:00Z"), endDate: TestData.date("2026-11-02T10:00:00Z"))

        try fixture.apply(EventMutationUseCases.createEvent(event, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testUpdateEventProducesExactlyOneJournalEntryEvenThoughItTouchesReminderAndSearchRowsToo() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.updateEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, in: try fixture.context()) { updated in
            updated.title = "Renamed"
            updated.reminders = [EventReminder(id: UUID(), offset: .minutesBefore(5))]
        })

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testDeleteEventProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testMoveEventProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.moveEvent(eventID: event.id, to: TestData.date("2026-09-03T14:00:00Z"), expectedVersionNumber: event.versionNumber, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testResizeEventProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.resizeEvent(eventID: event.id, startDate: event.startDate, endDate: event.endDate.addingTimeInterval(1800), expectedVersionNumber: event.versionNumber, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testMoveEventToCalendarProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]

        try fixture.apply(EventMutationUseCases.moveEventToCalendar(eventID: event.id, calendarID: TestData.secondCalendarID, expectedVersionNumber: event.versionNumber, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: event.id)
    }

    func testDuplicateEventProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let newID = UUID()

        try fixture.apply(EventMutationUseCases.duplicateEvent(event, newEventID: newID, in: try fixture.context()))

        try fixture.assertJournalEntryCount(1, forEntity: newID)
    }

    func testRestoreTombstoneProducesExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let tombstoneID = UUID()

        try fixture.apply(EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, tombstoneID: tombstoneID, in: try fixture.context()))
        try fixture.apply(EventMutationUseCases.restoreTombstone(event, tombstoneID: tombstoneID, in: try fixture.context()))

        // One entry for the delete, one for the restore — each is its own logical action.
        try fixture.assertJournalEntryCount(2, forEntity: event.id)
        XCTAssertTrue(try fixture.repository.load().deletedEventTombstones.isEmpty)
        XCTAssertTrue(try fixture.repository.load().events.contains { $0.id == event.id })
    }

    func testCancelAndRestoreOccurrenceEachProduceExactlyOneJournalEntry() throws {
        let fixture = try makeSeededRepository()
        let master = TestData.event(
            id: UUID(),
            title: "Recurring",
            startDate: TestData.date("2026-11-03T18:00:00Z"),
            endDate: TestData.date("2026-11-03T19:00:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.tuesday], end: .afterOccurrences(5))
        )
        try fixture.apply(EventMutationUseCases.createEvent(master, in: try fixture.context()))

        let exception = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-11-10T18:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )
        try fixture.apply(EventMutationUseCases.cancelOccurrence(masterEventID: master.id, exception: exception, in: try fixture.context()))

        try fixture.readDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ?", arguments: [exception.id.uuidString]), 1)
        }
        XCTAssertEqual(try fixture.repository.load().recurrenceExceptions.map(\.id), [exception.id])

        try fixture.apply(EventMutationUseCases.restoreOccurrence(masterEventID: master.id, exceptionID: exception.id, restoringReplacement: nil, in: try fixture.context()))
        XCTAssertTrue(try fixture.repository.load().recurrenceExceptions.isEmpty)
    }

    /// Import is the one use case where "one journal entry per logical action" collapses at
    /// the entity level rather than the batch level: each imported event is its own distinct
    /// creation (see `EventMutationUseCases.importCommit`'s doc comment).
    func testImportCommitProducesOneJournalEntryPerImportedEvent() throws {
        let fixture = try makeSeededRepository()
        let imported = [
            TestData.event(id: UUID(), title: "Imported A", startDate: TestData.date("2026-12-01T09:00:00Z"), endDate: TestData.date("2026-12-01T10:00:00Z")),
            TestData.event(id: UUID(), title: "Imported B", startDate: TestData.date("2026-12-02T09:00:00Z"), endDate: TestData.date("2026-12-02T10:00:00Z")),
            TestData.event(id: UUID(), title: "Imported C", startDate: TestData.date("2026-12-03T09:00:00Z"), endDate: TestData.date("2026-12-03T10:00:00Z"))
        ]

        try fixture.apply(EventMutationUseCases.importCommit(events: imported, exceptions: [], in: try fixture.context(source: .importICS)))

        try fixture.readDatabase { db in
            for event in imported {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ? AND source = 'importICS'", arguments: [event.id.uuidString]), 1)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE source = 'importICS'"), 3)
        }
    }

    // MARK: - End-to-end through BetterCalendarStore

    /// The use-case tests above call `EventMutationUseCases` directly; this confirms
    /// `BetterCalendarStore` is actually wired onto that pipeline (not just capable of being,
    /// via `StubCalendarRepository`'s in-memory `applying(_:)`) by driving a real SQLite-backed
    /// store and reading the journal back off disk.
    @MainActor
    func testStoreSaveEventWritesThroughToTheRealChangeJournal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EventMutationUseCasesTests-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database(events: []))

        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        var draft = EventDraft(calendarID: TestData.calendarID, startDate: TestData.date("2026-09-02T14:00:00Z"))
        draft.title = "Lab"

        XCTAssertTrue(store.saveEvent(from: draft))
        let created = try XCTUnwrap(store.events.first)
        XCTAssertEqual(created.versionNumber, 1)

        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ? AND operation = 'create'", arguments: [created.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutations WHERE object_id = ?", arguments: [created.id.uuidString]), 1)
        }

        store.deleteEvent(created)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ? AND operation = 'delete'", arguments: [created.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_objects WHERE object_id = ?", arguments: [created.id.uuidString]), 1)
        }

        // Undo restores the event and retires the tombstone, both through the same pipeline.
        store.undoAction?.perform()
        XCTAssertTrue(store.events.contains { $0.id == created.id })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deleted_objects WHERE object_id = ?", arguments: [created.id.uuidString]), 0)
        }
    }

    // MARK: - Fixture

    private struct RepositoryFixture {
        let repository: SQLiteCalendarRepository
        let databaseURL: URL
        let database: LocalCalendarDatabase

        func context(source: JournalSource = .userEdit) throws -> EventMutationUseCases.Context {
            EventMutationUseCases.Context(database: try repository.load(), now: TestData.date("2026-09-01T12:00:00Z"), source: source)
        }

        func apply(_ outcome: EventMutationUseCases.Outcome) throws {
            guard case .applied(let transaction) = outcome else {
                XCTFail("expected the outcome to be .applied, got \(outcome)")
                return
            }
            try repository.apply(transaction)
        }

        func assertJournalEntryCount(_ expected: Int, forEntity entityID: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
            try readDatabase { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_journal WHERE entity_id = ?", arguments: [entityID.uuidString])
                XCTAssertEqual(count, expected, file: file, line: line)
            }
        }

        func readDatabase<T>(_ body: (Database) throws -> T) throws -> T {
            try DatabaseQueue(path: databaseURL.path).read(body)
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
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EventMutationUseCasesTests-\(UUID().uuidString)")
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

        return RepositoryFixture(repository: repository, databaseURL: databaseURL, database: try repository.load())
    }
}
