import XCTest
@testable import Better_Calendar

final class ICSCalendarCodecTests: XCTestCase {
    func testExportEscapesTextAndIncludesWeeklyRecurrenceRule() {
        let calendar = TestData.calendar(name: "School, Main")
        let event = TestData.event(
            title: "Study, Plan; Phase\\One",
            startDate: TestData.date("2026-09-02T14:00:00Z"),
            endDate: TestData.date("2026-09-02T15:00:00Z"),
            location: "Mason; Hall",
            notes: "Line 1\nLine 2",
            recurrence: RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.wednesday, .monday], end: .never)
        )

        let ics = ICSCalendarCodec.export(events: [event], calendars: [calendar])

        XCTAssertTrue(ics.contains("SUMMARY:Study\\, Plan\\; Phase\\\\One"))
        XCTAssertTrue(ics.contains("CATEGORIES:School\\, Main"))
        XCTAssertTrue(ics.contains("LOCATION:Mason\\; Hall"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Line 1\\nLine 2"))
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"))
    }

    func testExportFormatsAllDayDatesWithoutTimes() {
        let event = TestData.event(
            startDate: allDayDate(year: 2026, month: 9, day: 3),
            endDate: allDayDate(year: 2026, month: 9, day: 4),
            isAllDay: true
        )

        let ics = ICSCalendarCodec.export(events: [event], calendars: [TestData.calendar()])

        XCTAssertTrue(ics.contains("DTSTART:20260903"))
        XCTAssertTrue(ics.contains("DTEND:20260904"))
    }

    func testImportParsesUTCAndAllDayEventsAndCountsFailures() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Office\\, Hours
        DTSTART:20260902T150000Z
        DTEND:20260902T160000Z
        LOCATION:Mason\\; Hall
        DESCRIPTION:Bring notes\\nQuestions
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Break
        DTSTART:20260903
        DTEND:20260904
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Missing Start
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)

        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.failedCount, 1)

        let timedEvent = try XCTUnwrap(summary.events.first { $0.title == "Office, Hours" })
        XCTAssertEqual(timedEvent.startDate, TestData.date("2026-09-02T15:00:00Z"))
        XCTAssertEqual(timedEvent.endDate, TestData.date("2026-09-02T16:00:00Z"))
        XCTAssertFalse(timedEvent.isAllDay)
        XCTAssertEqual(timedEvent.location, "Mason; Hall")
        XCTAssertEqual(timedEvent.notes, "Bring notes\nQuestions")

        let allDayEvent = try XCTUnwrap(summary.events.first { $0.title == "Break" })
        XCTAssertEqual(localDateString(allDayEvent.startDate), "2026-09-03")
        XCTAssertEqual(localDateString(allDayEvent.endDate), "2026-09-04")
        XCTAssertTrue(allDayEvent.isAllDay)
    }

    // BC-ICS-001
    func testImportParsesWeeklyRRuleWithByDay() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:weekly-1
        SUMMARY:Standup
        DTSTART:20260907T140000Z
        DTEND:20260907T143000Z
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)
        let recurrence = try XCTUnwrap(event.recurrence)

        XCTAssertEqual(recurrence.frequency, .weekly)
        XCTAssertEqual(recurrence.interval, 2)
        XCTAssertEqual(recurrence.weekdays, [.monday, .wednesday])
    }

    // BC-ICS-001
    func testImportParsesMonthlyRRuleWithPositionalLastFriday() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:monthly-1
        SUMMARY:Retro
        DTSTART:20260904T140000Z
        DTEND:20260904T150000Z
        RRULE:FREQ=MONTHLY;BYDAY=-1FR
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)
        let recurrence = try XCTUnwrap(event.recurrence)

        XCTAssertEqual(recurrence.frequency, .monthly)
        XCTAssertEqual(recurrence.setPositions, [-1])
        XCTAssertEqual(recurrence.weekdays, [.friday])
    }

    // BC-ICS-001
    func testImportParsesByMonthDayAndCount() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:monthly-2
        SUMMARY:Rent
        DTSTART:20260901T090000Z
        DTEND:20260901T093000Z
        RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15;COUNT=6
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)
        let recurrence = try XCTUnwrap(event.recurrence)

        XCTAssertEqual(recurrence.daysOfMonth, [1, 15])
        XCTAssertEqual(recurrence.end, .afterOccurrences(6))
    }

    // BC-ICS-001
    func testImportCreatesModifiedExceptionForRecurrenceIDBlock() throws {
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

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)

        XCTAssertEqual(summary.events.count, 2)
        let master = try XCTUnwrap(summary.events.first { $0.recurrenceMasterID == nil })
        let replacement = try XCTUnwrap(summary.events.first { $0.recurrenceMasterID != nil })

        XCTAssertEqual(replacement.recurrenceMasterID, master.id)
        XCTAssertEqual(replacement.title, "Standup (moved room)")
        XCTAssertEqual(replacement.location, "Room 202")
        XCTAssertNil(replacement.recurrence)

        let exception = try XCTUnwrap(summary.recurrenceExceptions.first)
        XCTAssertEqual(exception.exceptionType, .modified)
        XCTAssertEqual(exception.masterEventID, master.id)
        XCTAssertEqual(exception.replacementEventID, replacement.id)
    }

    // BC-ICS-001
    func testImportCreatesCancelledExceptionForEachExdate() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:series-2
        SUMMARY:Standup
        DTSTART:20260907T140000Z
        DTEND:20260907T143000Z
        RRULE:FREQ=WEEKLY;BYDAY=MO
        EXDATE:20260914T140000Z
        EXDATE:20260921T140000Z
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)

        XCTAssertEqual(summary.recurrenceExceptions.count, 2)
        XCTAssertTrue(summary.recurrenceExceptions.allSatisfy { $0.exceptionType == .cancelled })
        XCTAssertEqual(
            Set(summary.recurrenceExceptions.compactMap(\.originalOccurrenceStart)),
            [TestData.date("2026-09-14T14:00:00Z"), TestData.date("2026-09-21T14:00:00Z")]
        )
    }

    // BC-ICS-001
    func testImportParsesValarmTriggerIntoReminderOffset() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Lecture
        DTSTART:20260902T140000Z
        DTEND:20260902T150000Z
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        TRIGGER:-PT10M
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)

        XCTAssertEqual(event.reminders.map(\.offset), [.minutesBefore(10)])
    }

    // BC-ICS-001
    func testImportHonorsExplicitTZIDWhenResolvable() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Seminar
        DTSTART;TZID=America/Detroit:20260902T140000Z
        DTEND;TZID=America/Detroit:20260902T150000Z
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)

        XCTAssertEqual(event.timeZoneIdentifier, "America/Detroit")
    }

    // BC-ICS-001
    func testImportFallsBackToCurrentZoneWhenTZIDIsUnknown() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Seminar
        DTSTART;TZID=Not/ARealZone:20260902T140000Z
        DTEND;TZID=Not/ARealZone:20260902T150000Z
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)

        XCTAssertEqual(event.timeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertEqual(summary.failedCount, 0, "An unresolvable TZID should fall back, not fail the import.")
    }

    // BC-ICS-001
    func testImportParsesDurationWhenDtendAbsent() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Workshop
        DTSTART:20260902T140000Z
        DURATION:PT1H30M
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)

        XCTAssertEqual(event.endDate, TestData.date("2026-09-02T15:30:00Z"))
    }

    // BC-ICS-001
    func testImportPreservesUIDAsProviderObjectIDAndRawPropertiesIsPopulated() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:custom-uid-123
        SUMMARY:Workshop
        DTSTART:20260902T140000Z
        DTEND:20260902T150000Z
        X-CUSTOM-PROP:some value
        END:VEVENT
        END:VCALENDAR
        """

        let summary = ICSCalendarCodec.importEvents(from: text, defaultCalendarID: TestData.calendarID)
        let event = try XCTUnwrap(summary.events.first)

        XCTAssertEqual(event.providerMetadata.providerObjectID, "custom-uid-123")
        XCTAssertNotNil(event.providerMetadata.rawICSProperties)
        XCTAssertTrue(event.providerMetadata.rawICSProperties?.contains("X-CUSTOM-PROP") ?? false)
    }

    // BC-ICS-001
    func testLineUnfoldingRejoinsFoldedContinuationLines() {
        // Each fold point below is "CRLF + one inserted marker space" immediately before an
        // original space in the source text — so the folded form shows two spaces (marker +
        // original) after each CRLF, and unfolding must strip exactly the marker, leaving the
        // single original space behind at both points.
        let folded = "DESCRIPTION:This is a long\r\n  description that wraps\r\n  across lines"
        let unfolded = ICSCalendarCodec.unfoldLines(folded)

        XCTAssertEqual(unfolded, "DESCRIPTION:This is a long description that wraps across lines")
    }

    // BC-ICS-002
    func testExportEmitsValarmPerReminderWithCorrectTrigger() {
        var event = TestData.event()
        event.reminders = [
            EventReminder(id: UUID(), offset: .minutesBefore(10)),
            EventReminder(id: UUID(), offset: .daysBefore(1)),
            EventReminder(id: UUID(), offset: .atStart)
        ]

        let ics = ICSCalendarCodec.export(events: [event], calendars: [TestData.calendar()])

        XCTAssertTrue(ics.contains("TRIGGER:-PT10M"))
        XCTAssertTrue(ics.contains("TRIGGER:-P1D"))
        XCTAssertTrue(ics.contains("TRIGGER:PT0S"))
        XCTAssertEqual(ics.components(separatedBy: "BEGIN:VALARM").count - 1, 3)
    }

    // BC-ICS-002
    func testExportEmitsExdateForCancelledAndSeparateVeventForModifiedException() throws {
        let master = TestData.event(
            id: UUID(),
            title: "Standup",
            startDate: TestData.date("2026-09-07T14:00:00Z"),
            endDate: TestData.date("2026-09-07T14:30:00Z"),
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .never)
        )
        var replacement = TestData.event(id: UUID(), title: "Standup (moved room)", startDate: TestData.date("2026-09-21T15:00:00Z"), endDate: TestData.date("2026-09-21T15:30:00Z"))
        replacement.recurrenceMasterID = master.id
        replacement.recurrenceOriginalStart = TestData.date("2026-09-21T14:00:00Z")

        let cancelled = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-14T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .cancelled,
            replacementEventID: nil
        )
        let modified = RecurrenceException(
            id: UUID(),
            masterEventID: master.id,
            originalOccurrenceStart: TestData.date("2026-09-21T14:00:00Z"),
            originalOccurrenceLocalDate: nil,
            exceptionType: .modified,
            replacementEventID: replacement.id
        )

        let ics = ICSCalendarCodec.export(events: [master, replacement], calendars: [TestData.calendar()], recurrenceExceptions: [cancelled, modified])

        XCTAssertTrue(ics.contains("EXDATE:20260914T140000Z"))
        XCTAssertTrue(ics.contains("RECURRENCE-ID:20260921T140000Z"))
        XCTAssertEqual(ics.components(separatedBy: "BEGIN:VEVENT").count - 1, 2, "Master + one modified-occurrence VEVENT, not the replacement as its own independent entry.")

        // Both VEVENTs share the master's UID (RFC 5545: RECURRENCE-ID identifies an
        // occurrence override of the series named by UID, not a separate series).
        let uidLines = ics.components(separatedBy: "\r\n").filter { $0.hasPrefix("UID:") }
        XCTAssertEqual(Set(uidLines).count, 1)
    }

    // BC-ICS-002
    func testExportFoldsLongLinesAt75Octets() {
        let event = TestData.event(notes: String(repeating: "a", count: 200))

        let ics = ICSCalendarCodec.export(events: [event], calendars: [TestData.calendar()])
        let physicalLines = ics.components(separatedBy: "\r\n")

        XCTAssertTrue(physicalLines.allSatisfy { $0.utf8.count <= 75 }, "No physical line should exceed 75 octets.")
        XCTAssertTrue(physicalLines.contains { $0.hasPrefix(" ") }, "A folded continuation line starts with a single space.")
    }

    // BC-ICS-002
    func testFoldThenUnfoldRoundTripsOriginalContent() {
        let original = "DESCRIPTION:\(String(repeating: "word ", count: 40))"
        let folded = ICSCalendarCodec.foldLines(original)
        let unfolded = ICSCalendarCodec.unfoldLines(folded)

        XCTAssertEqual(unfolded, original)
    }

    // BC-ICS-002
    func testExportFloatingEventOmitsUTCDesignator() {
        // 2026-09-04T00:00:00Z is 2026-09-03 20:00 in America/Detroit (EDT, UTC-4 in September).
        let event = TestData.event(
            startDate: TestData.date("2026-09-04T00:00:00Z"),
            endDate: TestData.date("2026-09-04T01:00:00Z"),
            timeType: .floating,
            timeZoneIdentifier: "America/Detroit"
        )

        let ics = ICSCalendarCodec.export(events: [event], calendars: [TestData.calendar()])
        let dtstartLine = ics.components(separatedBy: "\r\n").first { $0.hasPrefix("DTSTART:") }

        XCTAssertEqual(dtstartLine, "DTSTART:20260903T200000")
    }

    // BC-ICS-001
    @MainActor
    func testStoreImportDetectsDuplicateByUIDAcrossTwoImportRuns() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:repeat-import-uid
        SUMMARY:Workshop
        DTSTART:20260902T140000Z
        DTEND:20260902T150000Z
        END:VEVENT
        END:VCALENDAR
        """

        let firstImport = store.importICS(text)
        XCTAssertEqual(firstImport.importedCount, 1)
        XCTAssertEqual(store.events.count, 1)

        // Same UID, different title/start — a naive title+startDate check would treat this as
        // new, but UID-based dedup must still catch it.
        let secondText = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:repeat-import-uid
        SUMMARY:Workshop (renamed)
        DTSTART:20260903T140000Z
        DTEND:20260903T150000Z
        END:VEVENT
        END:VCALENDAR
        """
        let secondImport = store.importICS(secondText)

        XCTAssertEqual(secondImport.importedCount, 0)
        XCTAssertEqual(secondImport.skippedCount, 1)
        XCTAssertEqual(store.events.count, 1)
    }

    @MainActor
    func testStoreImportCountsDuplicateEventsAsSkippedWithoutSaving() {
        // Both start *and* end must match the imported event below (spec 2.15's duplicate match
        // is `(calendarID, normalizedTitle, startInstant, endInstant)`, not title+start alone) —
        // explicit here rather than relying on `TestData.event`'s independent startDate/endDate
        // defaults, which would otherwise give this a zero-duration span that doesn't represent
        // the same real "Office Hours" meeting as the imported [15:00, 16:00) one.
        let existingEvent = TestData.event(title: "Office Hours", startDate: TestData.date("2026-09-02T15:00:00Z"), endDate: TestData.date("2026-09-02T16:00:00Z"))
        let repository = StubCalendarRepository(loadResult: .success(TestData.database(events: [existingEvent])))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Office Hours
        DTSTART:20260902T150000Z
        DTEND:20260902T160000Z
        END:VEVENT
        END:VCALENDAR
        """

        let summary = store.importICS(text)

        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(repository.savedDatabases.isEmpty)
    }

    private func allDayDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func localDateString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }
}
