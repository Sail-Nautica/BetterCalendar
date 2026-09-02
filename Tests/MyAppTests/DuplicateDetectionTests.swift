import XCTest
@testable import Better_Calendar

/// Spec 2.15 (BC-ENG-007): `DuplicateDetector`, plus its wiring into
/// `BetterCalendarStore.commitImport`.
final class DuplicateDetectionTests: XCTestCase {

    // MARK: - Pure DuplicateDetector behavior

    func testProviderUIDMatchTakesPrecedenceEvenWhenTitleAndTimeDiffer() {
        var existing = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        existing.providerMetadata.providerObjectID = "shared-uid"
        var incoming = TestData.event(id: UUID(), title: "Workshop (renamed)", startDate: TestData.date("2026-09-03T14:00:00Z"), endDate: TestData.date("2026-09-03T15:00:00Z"))
        incoming.providerMetadata.providerObjectID = "shared-uid"

        let candidates = DuplicateDetector.candidates(for: incoming, among: [existing])

        XCTAssertEqual(candidates, [DuplicateDetector.Candidate(matchedEventID: existing.id, confidence: 1.0, reason: .providerUID)])
    }

    func testNoUIDMatchFallsBackToTitleAndTime() {
        let existing = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let incoming = TestData.event(id: UUID(), title: "workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))

        let candidates = DuplicateDetector.candidates(for: incoming, among: [existing])

        XCTAssertEqual(candidates.map(\.matchedEventID), [existing.id])
        XCTAssertEqual(candidates.first?.reason, .titleAndTime)
        XCTAssertEqual(candidates.first?.confidence, 1.0, "an exact field match scores at the top of the range")
    }

    func testTitleAndTimeMatchWithinToleranceIsDetectedWithReducedConfidence() {
        let existing = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        // Two minutes late — inside the 5-minute default tolerance.
        let incoming = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:02:00Z"), endDate: TestData.date("2026-09-02T15:02:00Z"))

        let candidates = DuplicateDetector.candidates(for: incoming, among: [existing])

        XCTAssertEqual(candidates.map(\.matchedEventID), [existing.id])
        XCTAssertLessThan(candidates.first?.confidence ?? 0, 1.0)
        XCTAssertGreaterThan(candidates.first?.confidence ?? 0, 0.5)
    }

    func testTitleAndTimeMatchOutsideToleranceIsNotDetected() {
        let existing = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let incoming = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T15:00:00Z"), endDate: TestData.date("2026-09-02T16:00:00Z"))

        XCTAssertTrue(DuplicateDetector.candidates(for: incoming, among: [existing]).isEmpty)
    }

    func testDifferentTitlesDoNotMatch() {
        let existing = TestData.event(id: UUID(), title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let incoming = TestData.event(id: UUID(), title: "Seminar", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))

        XCTAssertTrue(DuplicateDetector.candidates(for: incoming, among: [existing]).isEmpty)
    }

    func testDifferentCalendarsDoNotMatch() {
        let existing = TestData.event(id: UUID(), calendarID: TestData.calendarID, title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))
        let incoming = TestData.event(id: UUID(), calendarID: TestData.secondCalendarID, title: "Workshop", startDate: TestData.date("2026-09-02T14:00:00Z"), endDate: TestData.date("2026-09-02T15:00:00Z"))

        XCTAssertTrue(DuplicateDetector.candidates(for: incoming, among: [existing]).isEmpty)
    }

    /// Spec 2.15: "for recurring events, compare (recurrenceMasterID equivalent fields,
    /// originalStart) rather than per-occurrence fields" — a replacement's own title/time can
    /// differ arbitrarily from what it started as (that's the point of a "This Event" edit), so
    /// title+time is not what identifies it; its slot in its series is.
    func testRecurringOccurrenceMatchesByMasterAndOriginalStartDespiteDifferentTitle() {
        let masterID = UUID()
        var existingReplacement = TestData.event(id: UUID(), title: "Standup (moved room)", startDate: TestData.date("2026-09-14T15:00:00Z"), endDate: TestData.date("2026-09-14T15:30:00Z"))
        existingReplacement.recurrenceMasterID = masterID
        existingReplacement.recurrenceOriginalStart = TestData.date("2026-09-14T14:00:00Z")

        var incomingReplacement = TestData.event(id: UUID(), title: "Standup (renamed again)", startDate: TestData.date("2026-09-14T16:00:00Z"), endDate: TestData.date("2026-09-14T16:30:00Z"))
        incomingReplacement.recurrenceMasterID = masterID
        incomingReplacement.recurrenceOriginalStart = TestData.date("2026-09-14T14:00:00Z")

        let candidates = DuplicateDetector.candidates(for: incomingReplacement, among: [existingReplacement])

        XCTAssertEqual(candidates.map(\.matchedEventID), [existingReplacement.id])
        XCTAssertEqual(candidates.first?.reason, .recurringOccurrence)
    }

    func testRecurringOccurrenceForADifferentMasterDoesNotMatch() {
        var existingReplacement = TestData.event(id: UUID(), startDate: TestData.date("2026-09-14T15:00:00Z"), endDate: TestData.date("2026-09-14T15:30:00Z"))
        existingReplacement.recurrenceMasterID = UUID()
        existingReplacement.recurrenceOriginalStart = TestData.date("2026-09-14T14:00:00Z")

        var incomingReplacement = TestData.event(id: UUID(), startDate: TestData.date("2026-09-14T15:00:00Z"), endDate: TestData.date("2026-09-14T15:30:00Z"))
        incomingReplacement.recurrenceMasterID = UUID() // a different series entirely
        incomingReplacement.recurrenceOriginalStart = TestData.date("2026-09-14T14:00:00Z")

        XCTAssertTrue(DuplicateDetector.candidates(for: incomingReplacement, among: [existingReplacement]).isEmpty)
    }

    // MARK: - Store wiring (BC-ENG-007)

    /// The plan's own requirement-to-test mapping names this exact test.
    @MainActor
    func testReimportingSameICSCreatesNothing() throws {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:workshop-uid
        SUMMARY:Workshop
        DTSTART:20260902T140000Z
        DTEND:20260902T150000Z
        END:VEVENT
        END:VCALENDAR
        """

        let first = store.importICS(text)
        XCTAssertEqual(first.importedCount, 1)

        let second = store.importICS(text)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.skippedCount, 1)
        XCTAssertEqual(store.events.count, 1)
    }

    /// Same as above, but for a recurring series with a per-occurrence replacement (BC-REC-010) —
    /// the case M6's plan calls out by name: re-importing must skip the master *and* leave the
    /// existing replacement alone, not duplicate it via the master/replacement cascade.
    @MainActor
    func testReimportingSameRecurringSeriesWithAReplacementCreatesNothing() throws {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:series-1
        SUMMARY:Standup
        DTSTART:20260907T140000Z
        DTEND:20260907T143000Z
        RRULE:FREQ=WEEKLY;BYDAY=MO
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        RECURRENCE-ID:20260914T140000Z
        SUMMARY:Standup (moved room)
        DTSTART:20260914T150000Z
        DTEND:20260914T153000Z
        LOCATION:Room 202
        END:VEVENT
        END:VCALENDAR
        """

        let first = store.importICS(text)
        XCTAssertEqual(first.importedCount, 2, "the master plus its one replacement")
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.recurrenceExceptions.count, 1)

        let second = store.importICS(text)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertGreaterThanOrEqual(second.skippedCount, 1)
        XCTAssertEqual(store.events.count, 2, "neither the master nor the replacement was duplicated")
        XCTAssertEqual(store.recurrenceExceptions.count, 1)
    }
}
