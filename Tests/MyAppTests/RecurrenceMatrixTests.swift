import XCTest
@testable import Better_Calendar

/// Spec 2.3/2.4 (BC-ENG-001, BC-ENG-002): `RecurrenceSplitter`'s three `EditScope`s. Each
/// destructive assertion here checks a snapshot of the *whole* series — every occurrence's
/// date, not just the one being edited — since a split that gets the boundary wrong by one
/// occurrence, or silently drops/duplicates one, is exactly the bug a single spot check misses.
final class RecurrenceMatrixTests: XCTestCase {

    /// Daily at 14:00 UTC, ten occurrences: Sep 1 through Sep 10, 2026.
    private var dailyTenOccurrences: RecurrenceRule {
        RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], end: .afterOccurrences(10))
    }

    private var allTenDailyStarts: [Date] {
        (1...10).map { TestData.date(String(format: "2026-09-%02dT14:00:00Z", $0)) }
    }

    // MARK: - This Event (BC-ENG-001)

    func testThisEventOnlyLeavesSeriesUnchanged() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-03T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        let outcome = RecurrenceSplitter.planEdit(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { event in
            event.title = "Guest lecture"
        }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        XCTAssertTrue(result.flaggedExceptions.isEmpty)
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 2, "the master plus one standalone replacement")
        let replacement = try XCTUnwrap(reloaded.events.first { $0.id != master.id })
        XCTAssertEqual(replacement.title, "Guest lecture")
        XCTAssertEqual(replacement.recurrenceMasterID, master.id)
        XCTAssertEqual(replacement.recurrenceOriginalStart, splitStart)

        let reloadedMaster = try XCTUnwrap(reloaded.events.first { $0.id == master.id })
        XCTAssertEqual(reloadedMaster.recurrence, master.recurrence, "the master's own rule must be untouched")
        XCTAssertEqual(reloadedMaster.versionNumber, master.versionNumber, "This Event never bumps the master's version")

        let exception = try XCTUnwrap(reloaded.recurrenceExceptions.first)
        XCTAssertEqual(exception.exceptionType, .modified)
        XCTAssertEqual(exception.replacementEventID, replacement.id)

        // Whole-series snapshot: every other occurrence of the master is untouched, and the
        // edited slot is served by the replacement instead of the master.
        let masterDates = expandedStartDates(of: reloadedMaster, exceptions: reloaded.recurrenceExceptions)
        XCTAssertEqual(masterDates, allTenDailyStarts.filter { $0 != splitStart })
    }

    func testThisEventOnlyReeditingExistingReplacementUpdatesItInPlaceAndChecksVersion() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-03T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        try fixture.apply(RecurrenceSplitter.planEdit(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { $0.title = "v1" })

        var reloaded = try fixture.repository.load()
        let replacement = try XCTUnwrap(reloaded.events.first { $0.id != master.id })
        XCTAssertEqual(replacement.versionNumber, 1)

        try fixture.apply(RecurrenceSplitter.planEdit(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: replacement.versionNumber, in: try fixture.context()) { $0.title = "v2" })

        reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 2, "re-editing must update, not duplicate, the replacement")
        let updated = try XCTUnwrap(reloaded.events.first { $0.id == replacement.id })
        XCTAssertEqual(updated.title, "v2")
        XCTAssertEqual(updated.versionNumber, 2)

        // A stale version (the pre-edit one) must be rejected, not silently overwritten.
        let staleOutcome = RecurrenceSplitter.planEdit(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: 1, in: try fixture.context()) { $0.title = "should not land" }
        guard case .conflicted(let currentVersionNumber) = staleOutcome else {
            return XCTFail("expected a conflict, got \(staleOutcome)")
        }
        XCTAssertEqual(currentVersionNumber, 2)
    }

    func testThisEventOnlyDeleteCancelsSingleOccurrenceWithoutTouchingSiblings() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-03T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        let outcome = RecurrenceSplitter.planDelete(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, exceptions: [], in: try fixture.context())
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 1, "no replacement is created for a plain cancel")
        let exception = try XCTUnwrap(reloaded.recurrenceExceptions.first)
        XCTAssertEqual(exception.exceptionType, .cancelled)
        XCTAssertNil(exception.replacementEventID)

        let masterDates = expandedStartDates(of: reloaded.events[0], exceptions: reloaded.recurrenceExceptions)
        XCTAssertEqual(masterDates, allTenDailyStarts.filter { $0 != splitStart })
    }

    func testThisEventOnlyDeleteOfAnAlreadyModifiedOccurrenceRemovesTheReplacementNotADuplicateException() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-03T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        try fixture.apply(RecurrenceSplitter.planEdit(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { $0.title = "v1" })

        let outcome = RecurrenceSplitter.planDelete(scope: .thisEventOnly, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, exceptions: [], in: try fixture.context())
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 1, "the replacement must be removed outright")
        XCTAssertEqual(reloaded.recurrenceExceptions.count, 1, "exactly one exception row must survive — never two for the same slot")
        XCTAssertNil(reloaded.recurrenceExceptions[0].replacementEventID)
    }

    // MARK: - All Events

    func testAllEventsEditFlagsExceptionsIncompatibleWithTheNewRuleWithoutRemovingThem() throws {
        let fixture = try makeSeededRepository(recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday], end: .afterOccurrences(6)))
        let master = fixture.database.events[0]
        // 2026-09-07 is a Monday; the second occurrence (Wed 2026-09-09) gets a modified exception.
        let wednesdayOccurrence = TestData.date("2026-09-09T14:00:00Z")
        let exception = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: wednesdayOccurrence, originalOccurrenceLocalDate: nil, exceptionType: .modified, replacementEventID: nil)
        try fixture.insert(exceptions: [exception])

        // Drop Wednesday from the rule entirely — the Wednesday exception no longer corresponds
        // to any occurrence the new rule generates.
        let outcome = RecurrenceSplitter.planEdit(scope: .allEvents, master: master, occurrenceKey: OccurrenceKey(recurrenceMasterID: master.id, originalStart: master.startDate), expectedVersionNumber: master.versionNumber, in: try fixture.context()) { event in
            event.recurrence?.weekdays = [.monday]
        }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        XCTAssertEqual(result.flaggedExceptions.map(\.id), [exception.id])
        try fixture.repository.apply(result.transaction)

        // Never silently dropped: the exception row is still there after the edit lands.
        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.recurrenceExceptions.map(\.id), [exception.id])
    }

    func testAllEventsEditDoesNotFlagExceptionsStillCompatibleWithTheNewRule() throws {
        let fixture = try makeSeededRepository(recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday, .wednesday], end: .afterOccurrences(6)))
        let master = fixture.database.events[0]
        let mondayOccurrence = TestData.date("2026-09-07T14:00:00Z")
        let exception = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: mondayOccurrence, originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)
        try fixture.insert(exceptions: [exception])

        let outcome = RecurrenceSplitter.planEdit(scope: .allEvents, master: master, occurrenceKey: OccurrenceKey(recurrenceMasterID: master.id, originalStart: master.startDate), expectedVersionNumber: master.versionNumber, in: try fixture.context()) { event in
            // Widen, rather than narrow, the rule — Monday stays valid.
            event.recurrence?.weekdays = [.monday, .wednesday, .friday]
        }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        XCTAssertTrue(result.flaggedExceptions.isEmpty, "Monday is still generated by the widened rule")
    }

    // MARK: - This and Future (BC-ENG-002)

    func testThisAndFutureSplitsAtCorrectBoundaryPreservingTotalOccurrenceCount() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-05T14:00:00Z") // the 5th occurrence (index 4)
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        let outcome = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { event in
            event.title = "Evening section"
        }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        XCTAssertEqual(result.transaction.entityChanges.count, 2, "exactly the truncated master and the new master, no other rows")
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 2)
        let truncatedMaster = try XCTUnwrap(reloaded.events.first { $0.id == master.id })
        let newMaster = try XCTUnwrap(reloaded.events.first { $0.id != master.id })

        XCTAssertEqual(truncatedMaster.versionNumber, master.versionNumber + 1)
        XCTAssertEqual(newMaster.versionNumber, 1)
        XCTAssertEqual(newMaster.title, "Evening section")
        XCTAssertEqual(newMaster.startDate, splitStart)

        // Whole-series snapshot: the two halves together reproduce exactly the original ten
        // dates, each exactly once, split at the fifth occurrence.
        let beforeDates = expandedStartDates(of: truncatedMaster, exceptions: [])
        let afterDates = expandedStartDates(of: newMaster, exceptions: [])
        XCTAssertEqual(beforeDates, Array(allTenDailyStarts.prefix(4)))
        XCTAssertEqual(afterDates, Array(allTenDailyStarts.suffix(6)))
        XCTAssertEqual(Set(beforeDates + afterDates), Set(allTenDailyStarts), "no occurrence gained or lost across the split")
        XCTAssertEqual(beforeDates.count + afterDates.count, allTenDailyStarts.count)
    }

    func testThisAndFutureEditAtTheFirstOccurrenceDegeneratesToAnAllEventsEdit() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: master.startDate)

        let outcome = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { $0.title = "Renamed" }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }

        XCTAssertEqual(result.transaction.entityChanges.count, 1, "no split — only the master itself changes")
        try fixture.repository.apply(result.transaction)
        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 1)
        XCTAssertEqual(reloaded.events[0].title, "Renamed")
        XCTAssertEqual(reloaded.events[0].recurrence?.end, .afterOccurrences(10), "still the original, un-truncated count")
    }

    func testThisAndFutureTransfersLaterExceptionsAndRetiresTheSplitPointException() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-05T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        // Before the split: stays with the truncated original master untouched.
        let beforeException = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: TestData.date("2026-09-02T14:00:00Z"), originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)
        // Exactly at the split point: retired (folded into the new master's own first occurrence).
        let atSplitException = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: splitStart, originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)
        // After the split: transferred to the new master.
        let afterException = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: TestData.date("2026-09-08T14:00:00Z"), originalOccurrenceLocalDate: nil, exceptionType: .cancelled, replacementEventID: nil)

        try fixture.insert(exceptions: [beforeException, atSplitException, afterException])

        let outcome = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { _ in }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        let newMaster = try XCTUnwrap(reloaded.events.first { $0.id != master.id })

        XCTAssertEqual(reloaded.recurrenceExceptions.count, 2, "the at-split exception is retired; before/after survive")
        XCTAssertTrue(reloaded.recurrenceExceptions.contains { $0.id == beforeException.id && $0.masterEventID == master.id })
        XCTAssertTrue(reloaded.recurrenceExceptions.contains { $0.id == afterException.id && $0.masterEventID == newMaster.id })
        XCTAssertFalse(reloaded.recurrenceExceptions.contains { $0.id == atSplitException.id })
    }

    func testThisAndFutureEditRejectsStaleVersionNumber() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: TestData.date("2026-09-05T14:00:00Z"))

        let outcome = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber + 1, in: try fixture.context()) { _ in }
        guard case .conflicted(let currentVersionNumber) = outcome else { return XCTFail("expected a conflict, got \(outcome)") }
        XCTAssertEqual(currentVersionNumber, master.versionNumber)
    }

    func testThisAndFutureEditReplayingTheSameIdempotencyKeyIsANoOp() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: TestData.date("2026-09-05T14:00:00Z"))
        let idempotencyKey = UUID()

        let first = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, idempotencyKey: idempotencyKey, in: try fixture.context()) { $0.title = "First" }
        guard case .applied(let result) = first else { return XCTFail("expected .applied, got \(first)") }
        try fixture.repository.apply(result.transaction)

        let second = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, idempotencyKey: idempotencyKey, in: try fixture.context()) { $0.title = "Second" }
        guard case .duplicate = second else { return XCTFail("expected the replay to short-circuit as a duplicate, got \(second)") }

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 2, "the replay must not re-split the series a second time")
    }

    func testThisAndFutureDeleteTruncatesMasterAndDropsFutureExceptionsAndTheirReplacements() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-05T14:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        let replacement = TestData.event(id: UUID(), title: "Replacement", startDate: TestData.date("2026-09-08T15:00:00Z"), endDate: TestData.date("2026-09-08T16:00:00Z"))
        let futureModified = RecurrenceException(id: UUID(), masterEventID: master.id, originalOccurrenceStart: TestData.date("2026-09-08T14:00:00Z"), originalOccurrenceLocalDate: nil, exceptionType: .modified, replacementEventID: replacement.id)
        try fixture.insert(events: [replacement])
        try fixture.insert(exceptions: [futureModified])

        let exceptions = try fixture.repository.load().recurrenceExceptions
        let outcome = RecurrenceSplitter.planDelete(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, exceptions: exceptions, in: try fixture.context())
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertEqual(reloaded.events.count, 1, "no new master for a delete, and the future replacement is gone too")
        XCTAssertTrue(reloaded.recurrenceExceptions.isEmpty)

        let truncatedMaster = reloaded.events[0]
        let dates = expandedStartDates(of: truncatedMaster, exceptions: [])
        XCTAssertEqual(dates, Array(allTenDailyStarts.prefix(4)))
    }

    func testThisAndFutureDeleteAtTheFirstOccurrenceTombstonesTheWholeSeriesWithRecurrenceSplitCause() throws {
        let fixture = try makeSeededRepository(recurrence: dailyTenOccurrences)
        let master = fixture.database.events[0]
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: master.startDate)

        let outcome = RecurrenceSplitter.planDelete(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, exceptions: [], in: try fixture.context())
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        XCTAssertEqual(result.transaction.tombstones.map(\.deletedBy), [.recurrenceSplit])
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        XCTAssertTrue(reloaded.events.isEmpty)
        XCTAssertEqual(reloaded.deletedEventTombstones.map(\.deletedBy), [.recurrenceSplit])
    }

    // MARK: - All-day boundary (CLAUDE.md: all-day compares local dates, never UTC instants)

    func testThisAndFutureSplitBoundaryUsesLocalCalendarDateForAllDayEventsRegardlessOfTimeZone() throws {
        let allDayDaily = RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], end: .afterOccurrences(5))
        let allDayEvent = TestData.event(
            startDate: TestData.date("2026-09-01T00:00:00Z"),
            endDate: TestData.date("2026-09-02T00:00:00Z"),
            isAllDay: true,
            timeZoneIdentifier: "Pacific/Kiritimati", // UTC+14 — deliberately far from UTC.
            recurrence: allDayDaily
        )
        let fixture = try makeSeededRepository(events: [allDayEvent])
        let master = fixture.database.events[0]
        let splitStart = TestData.date("2026-09-04T00:00:00Z")
        let key = OccurrenceKey(recurrenceMasterID: master.id, originalStart: splitStart)

        let outcome = RecurrenceSplitter.planEdit(scope: .thisAndFuture, master: master, occurrenceKey: key, expectedVersionNumber: master.versionNumber, in: try fixture.context()) { _ in }
        guard case .applied(let result) = outcome else { return XCTFail("expected .applied, got \(outcome)") }
        try fixture.repository.apply(result.transaction)

        let reloaded = try fixture.repository.load()
        let truncatedMaster = try XCTUnwrap(reloaded.events.first { $0.id == master.id })
        guard case .onDate(let endDate) = truncatedMaster.recurrence?.end else {
            return XCTFail("expected the truncated master to end on a date")
        }

        let localCalendar = truncatedMaster.calendarInOriginalTimeZone
        XCTAssertEqual(LocalCalendarDate(date: endDate, calendar: localCalendar), LocalCalendarDate(date: TestData.date("2026-09-03T00:00:00Z"), calendar: localCalendar))

        let beforeDates = expandedStartDates(of: truncatedMaster, exceptions: [])
        XCTAssertEqual(beforeDates.count, 3, "Sep 1-3 stay with the truncated master")
    }

    // MARK: - Helpers

    /// Expands `event` over a window comfortably wider than any date this file's fixtures use.
    private func expandedStartDates(of event: CalendarEvent, exceptions: [RecurrenceException]) -> [Date] {
        let window = DateInterval(start: TestData.date("2026-08-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z"))
        return RecurrenceExpander().occurrences(of: event, in: window, exceptions: exceptions).map(\.occurrenceStartDate)
    }

    private struct RepositoryFixture {
        let repository: SQLiteCalendarRepository
        let databaseURL: URL
        let database: LocalCalendarDatabase

        func context(source: JournalSource = .userEdit) throws -> EventMutationUseCases.Context {
            EventMutationUseCases.Context(database: try repository.load(), now: TestData.date("2026-09-01T12:00:00Z"), source: source)
        }

        func apply(_ outcome: RecurrenceSplitter.Outcome) throws {
            guard case .applied(let result) = outcome else {
                XCTFail("expected the outcome to be .applied, got \(outcome)")
                return
            }
            try repository.apply(result.transaction)
        }

        func insert(events: [CalendarEvent]) throws {
            for event in events {
                try repository.apply(EngineTransaction(entityChanges: [.upsertEvent(event)]))
            }
        }

        func insert(exceptions: [RecurrenceException]) throws {
            for exception in exceptions {
                try repository.apply(EngineTransaction(entityChanges: [.upsertRecurrenceException(exception)]))
            }
        }
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    /// `TestData.event`'s own defaults anchor to Sep 2, not Sep 1 — explicit here so this file's
    /// dates (`allTenDailyStarts` et al.) match what's actually seeded.
    private func makeSeededRepository(recurrence: RecurrenceRule) throws -> RepositoryFixture {
        let event = TestData.event(
            startDate: TestData.date("2026-09-01T14:00:00Z"),
            endDate: TestData.date("2026-09-01T15:00:00Z"),
            recurrence: recurrence
        )
        return try makeSeededRepository(events: [event])
    }

    private func makeSeededRepository(events: [CalendarEvent]) throws -> RepositoryFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "RecurrenceMatrixTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let databaseURL = directory.appending(path: "BetterCalendar.sqlite")
        let repository = SQLiteCalendarRepository(fileURL: databaseURL)
        try repository.save(TestData.database(events: events))

        return RepositoryFixture(repository: repository, databaseURL: databaseURL, database: try repository.load())
    }
}
