import GRDB
import XCTest
@testable import Better_Calendar

/// Spec 2.10/2.11: a systematic one-test-per-use-case idempotent-replay matrix. The shared
/// mechanism (`EventMutationUseCases.existingOutcome(forIdempotencyKey:)`) is already proven
/// once by `EventMutationUseCasesTests.testReplayingTheSameIdempotencyKeyIsANoOp` (createEvent)
/// and `RecurrenceMatrixTests.testThisAndFutureEditReplayingTheSameIdempotencyKeyIsANoOp` — this
/// file is what actually exercises every *other* use case it backs, one at a time, so a future
/// change that accidentally drops the idempotency check from one specific entry point (rather
/// than the shared mechanism) still gets caught.
final class EngineIdempotencyTests: XCTestCase {

    // MARK: - update / delete / move / resize / moveToCalendar

    func testUpdateEventReplayDoesNotApplyTheMutationTwice() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let key = UUID()

        try fixture.apply(EventMutationUseCases.updateEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()) { $0.title = "v1" })

        let replay = EventMutationUseCases.updateEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()) { $0.title = "should never land" }
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.title, "v1")
        XCTAssertEqual(reloaded.versionNumber, event.versionNumber + 1, "bumped exactly once")
    }

    func testDeleteEventReplayDoesNotCreateASecondTombstone() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let key = UUID()

        try fixture.apply(EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try fixture.repository.load()
        XCTAssertTrue(reloaded.events.isEmpty)
        XCTAssertEqual(reloaded.deletedEventTombstones.count, 1)
    }

    func testMoveEventReplayLeavesTheEventAtTheFirstMovesDestination() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let key = UUID()
        let firstDestination = TestData.date("2026-09-05T14:00:00Z")

        try fixture.apply(EventMutationUseCases.moveEvent(eventID: event.id, to: firstDestination, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.moveEvent(eventID: event.id, to: TestData.date("2026-09-09T14:00:00Z"), expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.startDate, firstDestination)
        XCTAssertEqual(reloaded.versionNumber, event.versionNumber + 1)
    }

    func testResizeEventReplayLeavesTheEventAtTheFirstResizesDimensions() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let key = UUID()
        let firstEnd = event.endDate.addingTimeInterval(1800)

        try fixture.apply(EventMutationUseCases.resizeEvent(eventID: event.id, startDate: event.startDate, endDate: firstEnd, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.resizeEvent(eventID: event.id, startDate: event.startDate, endDate: event.endDate.addingTimeInterval(7200), expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.endDate, firstEnd)
    }

    func testMoveEventToCalendarReplayLeavesTheEventOnTheFirstDestinationCalendar() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let key = UUID()

        try fixture.apply(EventMutationUseCases.moveEventToCalendar(eventID: event.id, calendarID: TestData.secondCalendarID, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.moveEventToCalendar(eventID: event.id, calendarID: TestData.calendarID, expectedVersionNumber: event.versionNumber, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try XCTUnwrap(try fixture.repository.load().events.first { $0.id == event.id })
        XCTAssertEqual(reloaded.calendarID, TestData.secondCalendarID)
    }

    // MARK: - duplicate / restoreTombstone

    func testDuplicateEventReplayCreatesOnlyOneCopy() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let newID = UUID()
        let key = UUID()

        try fixture.apply(EventMutationUseCases.duplicateEvent(event, newEventID: newID, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.duplicateEvent(event, newEventID: newID, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.filter { $0.id == newID }.count, 1)
        XCTAssertEqual(reloaded.events.count, 2, "the original plus exactly one copy")
    }

    func testRestoreTombstoneReplayRestoresTheEventOnlyOnce() throws {
        let fixture = try makeSeededRepository()
        let event = fixture.database.events[0]
        let tombstoneID = UUID()
        try fixture.apply(EventMutationUseCases.deleteEvent(eventID: event.id, expectedVersionNumber: event.versionNumber, tombstoneID: tombstoneID, in: try fixture.context()))

        let key = UUID()
        try fixture.apply(EventMutationUseCases.restoreTombstone(event, tombstoneID: tombstoneID, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.restoreTombstone(event, tombstoneID: tombstoneID, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.filter { $0.id == event.id }.count, 1)
    }

    // MARK: - cancelOccurrence / restoreOccurrence

    func testCancelOccurrenceReplayCreatesOnlyOneException() throws {
        let fixture = try makeSeededRepository()
        let master = TestData.event(
            id: UUID(),
            title: "Recurring",
            startDate: TestData.date("2026-11-03T18:00:00Z"),
            endDate: TestData.date("2026-11-03T19:00:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.tuesday], end: .afterOccurrences(5))
        )
        try fixture.apply(EventMutationUseCases.createEvent(master, in: try fixture.context()))

        let exception = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: TestData.date("2026-11-10T18:00:00Z"), originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)
        let key = UUID()
        try fixture.apply(EventMutationUseCases.cancelOccurrence(masterEventID: master.id, exception: exception, idempotencyKey: key, in: try fixture.context()))

        let replay = EventMutationUseCases.cancelOccurrence(masterEventID: master.id, exception: exception, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.recurrenceExceptions.count, 1)
    }

    func testRestoreOccurrenceReplayIsANoOpAfterTheExceptionIsAlreadyGone() throws {
        let fixture = try makeSeededRepository()
        let master = TestData.event(
            id: UUID(),
            title: "Recurring",
            startDate: TestData.date("2026-11-03T18:00:00Z"),
            endDate: TestData.date("2026-11-03T19:00:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.tuesday], end: .afterOccurrences(5))
        )
        try fixture.apply(EventMutationUseCases.createEvent(master, in: try fixture.context()))
        let exception = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: TestData.date("2026-11-10T18:00:00Z"), originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)
        try fixture.apply(EventMutationUseCases.cancelOccurrence(masterEventID: master.id, exception: exception, in: try fixture.context()))

        let key = UUID()
        try fixture.apply(EventMutationUseCases.restoreOccurrence(masterEventID: master.id, exceptionID: exception.id, restoringReplacement: nil, idempotencyKey: key, in: try fixture.context()))
        XCTAssertTrue(try fixture.repository.load().recurrenceExceptions.isEmpty)

        let replay = EventMutationUseCases.restoreOccurrence(masterEventID: master.id, exceptionID: exception.id, restoringReplacement: nil, idempotencyKey: key, in: try fixture.context())
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }
        XCTAssertTrue(try fixture.repository.load().recurrenceExceptions.isEmpty)
    }

    // MARK: - importCommit

    func testImportCommitReplayWithTheSameKeyCommitsTheBatchOnlyOnce() throws {
        let fixture = try makeSeededRepository()
        let imported = [
            TestData.event(id: UUID(), title: "Imported A", startDate: TestData.date("2026-12-01T09:00:00Z"), endDate: TestData.date("2026-12-01T10:00:00Z")),
            TestData.event(id: UUID(), title: "Imported B", startDate: TestData.date("2026-12-02T09:00:00Z"), endDate: TestData.date("2026-12-02T10:00:00Z"))
        ]
        let key = UUID()

        try fixture.apply(EventMutationUseCases.importCommit(events: imported, exceptions: [], idempotencyKey: key, in: try fixture.context(source: .importICS)))

        let replay = EventMutationUseCases.importCommit(events: imported, exceptions: [], idempotencyKey: key, in: try fixture.context(source: .importICS))
        guard case .duplicate = replay else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(replay)") }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.filter { imported.map(\.id).contains($0.id) }.count, 2, "neither imported event landed twice")
    }

    // MARK: - Fixture (same shape as EventMutationUseCasesTests' own private one)

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
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeSeededRepository() throws -> RepositoryFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "EngineIdempotencyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database(calendars: [
            TestData.calendar(),
            TestData.calendar(id: TestData.secondCalendarID, name: "Personal", isDefault: false, sortOrder: 1)
        ]))

        return RepositoryFixture(repository: repository, databaseURL: databaseURL, database: try repository.load())
    }
}
