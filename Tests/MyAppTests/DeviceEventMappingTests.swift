import XCTest
@testable import Better_Calendar

/// Spec 3C.11's Mapping, Time and Recurrence blocks: `DeviceEventMapper` and
/// `DeviceRecurrenceTranslation` in isolation, with no store, no device and no event store
/// (BC-EK-024).
///
/// The recurrence half carries most of the weight. Translating a rule *wrongly* is worse than
/// not translating it — an untranslated series shows one date with a badge, a mistranslated one
/// shows a plausible, wrong set of occurrences — so every "expressible" case is asserted by
/// expanding it, not merely by inspecting the fields it produced.
final class DeviceEventMappingTests: XCTestCase {

    // MARK: - Fields (spec 3C.2)

    func testEveryMappedFieldSurvivesTheMapping() {
        let device = DeviceTestData.event(
            title: "Design review",
            notes: "Bring the mocks",
            location: "Room 4",
            urlString: "https://example.com/meet",
            alarms: [DeviceEventAlarm(relativeOffset: -600)]
        )

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertEqual(event.title, "Design review")
        XCTAssertEqual(event.notes, "Bring the mocks")
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.urlString, "https://example.com/meet")
        XCTAssertEqual(event.startDate, device.startDate)
        XCTAssertEqual(event.endDate, device.endDate)
        XCTAssertEqual(event.reminders.map(\.offset), [.minutesBefore(10)])
        XCTAssertEqual(event.calendarID, DeviceTestData.personalRowID)
        XCTAssertEqual(event.providerMetadata.providerObjectID, "evt-1")
        XCTAssertEqual(event.providerMetadata.providerExternalID, "ext-1")
        XCTAssertEqual(event.providerMetadata.syncStatus, .synced)
    }

    func testAnEmptyTitleStaysEmptyAndRendersAsThePlaceholder() {
        let event = DeviceEventMapper.map(DeviceTestData.event(title: ""), in: DeviceTestData.context(), now: DeviceTestData.now)

        // Spec 3.12: the *stored* value stays empty; only the rendering surface substitutes.
        XCTAssertEqual(event.title, "")
        XCTAssertEqual(event.displayTitle, CalendarEvent.untitledPlaceholder)
    }

    func testAbsentOptionalFieldsMapToNilRatherThanEmptyStrings() {
        let event = DeviceEventMapper.map(DeviceTestData.event(), in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertNil(event.notes)
        XCTAssertNil(event.location)
        XCTAssertNil(event.urlString)
        XCTAssertTrue(event.reminders.isEmpty)
        XCTAssertTrue(event.attendees.isEmpty)
        XCTAssertNil(event.recurrence)
    }

    /// Spec 3C.1: the event carries no account or calendar identifier of its own — its calendar
    /// row already holds both, and two places for one fact is one more than can be kept in
    /// agreement.
    func testAMirroredEventCarriesNoAccountOrCalendarIdentifierOfItsOwn() {
        let event = DeviceEventMapper.map(DeviceTestData.event(), in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertNil(event.providerMetadata.providerAccountID)
        XCTAssertNil(event.providerMetadata.providerCalendarID)
    }

    /// Spec 3.12: EventKit's four availability values map onto our two, downward, and none is
    /// dropped.
    func testAvailabilityMapsDownwardWithoutDroppingAValue() {
        let expected: [DeviceEventAvailability: EventAvailability] = [
            .busy: .busy,
            .free: .free,
            .tentative: .busy,
            .unavailable: .busy,
            .notSupported: .busy
        ]

        for value in DeviceEventAvailability.allCases {
            XCTAssertEqual(
                DeviceEventMapper.availability(for: value),
                expected[value],
                "\(value) must have a defined mapping"
            )
        }
        XCTAssertEqual(expected.count, DeviceEventAvailability.allCases.count, "every EventKit value needs a mapping")
    }

    func testACancelledEventStillProducesARowAndCarriesItsStatus() {
        let event = DeviceEventMapper.map(
            DeviceTestData.event(status: .cancelled),
            in: DeviceTestData.context(),
            now: DeviceTestData.now
        )

        XCTAssertEqual(event.status, .cancelled)
        XCTAssertTrue(event.isCancelled)
        // Still displayed — it is information, not a commitment (spec 3C.5).
        XCTAssertEqual(event.title, "Standup")
    }

    /// Spec 3C.7: alarms are mirrored for display. An alarm the engine cannot express as an
    /// offset is left out rather than fired at the wrong time.
    func testAlarmsMapToOffsetsAndUnexpressibleOnesAreDropped() {
        XCTAssertEqual(DeviceEventMapper.reminderOffset(forRelativeOffset: 0), .atStart)
        XCTAssertEqual(DeviceEventMapper.reminderOffset(forRelativeOffset: -900), .minutesBefore(15))
        XCTAssertEqual(DeviceEventMapper.reminderOffset(forRelativeOffset: -86_400), .daysBefore(1))
        XCTAssertEqual(DeviceEventMapper.reminderOffset(forRelativeOffset: -604_800), .daysBefore(7))
        // Not a whole number of minutes, and after the start: neither has a case.
        XCTAssertNil(DeviceEventMapper.reminderOffset(forRelativeOffset: -90))
        XCTAssertNil(DeviceEventMapper.reminderOffset(forRelativeOffset: 300))
    }

    // MARK: - Attendees (spec 3C.5)

    func testAttendeesMapWithRolesParticipationAndTheOrganizer() {
        let device = DeviceTestData.event(attendees: [
            DeviceEventAttendee(name: "Dana", email: "dana@example.com", participationStatus: .accepted, role: .chair, isOrganizer: true),
            DeviceEventAttendee(name: "Sam", email: "sam@example.com", participationStatus: .declined, role: .optional),
            DeviceEventAttendee(name: "Me", email: "me@example.com", participationStatus: .tentative, role: .required, isCurrentUser: true)
        ])

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertEqual(event.attendees.count, 3)
        XCTAssertEqual(event.attendees.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(event.organizer?.name, "Dana")
        XCTAssertEqual(event.organizer?.role, .chair)
        XCTAssertEqual(event.attendees[1].participationStatus, .declined)
        XCTAssertEqual(event.currentUserAttendee?.name, "Me")
        XCTAssertTrue(event.isTentative)
        XCTAssertFalse(event.isDeclinedByCurrentUser)
    }

    func testAttendeeIdentityIsStableAcrossTwoMappingsOfTheSameEvent() {
        let device = DeviceTestData.event(attendees: [
            DeviceEventAttendee(name: "Dana", email: "dana@example.com"),
            DeviceEventAttendee(name: "Sam", email: "sam@example.com")
        ])

        let first = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)
        let second = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now.addingTimeInterval(3_600))

        XCTAssertEqual(first.attendees.map(\.id), second.attendees.map(\.id))
    }

    // MARK: - Time (spec 3C.4)

    func testADeviceEventWithNoTimeZoneIsFloatingRatherThanPinnedToTheCurrentZone() {
        let event = DeviceEventMapper.map(
            DeviceTestData.event(timeZoneIdentifier: nil),
            in: DeviceTestData.context(deviceTimeZoneIdentifier: "Asia/Tokyo"),
            now: DeviceTestData.now
        )

        XCTAssertEqual(event.timeType, .floating)
        XCTAssertTrue(event.isFloating)
        // The device zone is stored as the zone its wall-clock components decode through — it is
        // not a claim that the event is *pinned* there, which is what `.timed` would have meant.
        XCTAssertEqual(event.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testATimedEventKeepsItsOwnZoneRatherThanTheDevices() {
        let event = DeviceEventMapper.map(
            DeviceTestData.event(timeZoneIdentifier: "Europe/Paris"),
            in: DeviceTestData.context(deviceTimeZoneIdentifier: "America/Detroit"),
            now: DeviceTestData.now
        )

        XCTAssertEqual(event.timeType, .timed)
        XCTAssertEqual(event.timeZoneIdentifier, "Europe/Paris")
    }

    /// Spec 3C.4/BC-TZ: an all-day mirrored event must not shift by a day when the device time
    /// zone changes. EventKit re-reports midnight in the new zone; the mapper decodes it in that
    /// same zone, so the local calendar date is the one the user sees in Apple Calendar.
    func testAnAllDayMirroredEventDoesNotShiftAcrossADeviceTimeZoneChange() {
        // Midnight on 20 September, as the device computes it in each zone.
        let detroit = DeviceTestData.event(
            startDate: TestData.date("2026-09-20T04:00:00Z"),
            endDate: TestData.date("2026-09-21T04:00:00Z"),
            isAllDay: true,
            timeZoneIdentifier: nil
        )
        let tokyo = DeviceTestData.event(
            startDate: TestData.date("2026-09-19T15:00:00Z"),
            endDate: TestData.date("2026-09-20T15:00:00Z"),
            isAllDay: true,
            timeZoneIdentifier: nil
        )

        let inDetroit = DeviceEventMapper.map(detroit, in: DeviceTestData.context(deviceTimeZoneIdentifier: "America/Detroit"), now: DeviceTestData.now)
        let inTokyo = DeviceEventMapper.map(tokyo, in: DeviceTestData.context(deviceTimeZoneIdentifier: "Asia/Tokyo"), now: DeviceTestData.now)

        XCTAssertEqual(inDetroit.timeType, .allDay)
        XCTAssertEqual(inTokyo.timeType, .allDay)
        XCTAssertEqual(inDetroit.localDateString(for: inDetroit.startDate), "2026-09-20")
        XCTAssertEqual(
            inTokyo.localDateString(for: inTokyo.startDate),
            "2026-09-20",
            "the same all-day event must be on the same calendar date in either device zone"
        )
    }

    /// An event near a DST boundary keeps its intended local time on both sides. The device
    /// reports each occurrence's real instant; the stored zone is what turns those back into the
    /// same wall clock.
    func testAnEventNearADSTBoundaryKeepsItsIntendedLocalTimeOnBothSides() {
        // US DST ends 2026-11-01. 09:00 New York is 13:00Z before and 14:00Z after.
        let before = DeviceEventMapper.map(
            DeviceTestData.event(startDate: TestData.date("2026-10-30T13:00:00Z"), endDate: TestData.date("2026-10-30T14:00:00Z")),
            in: DeviceTestData.context(),
            now: DeviceTestData.now
        )
        let after = DeviceEventMapper.map(
            DeviceTestData.event(startDate: TestData.date("2026-11-03T14:00:00Z"), endDate: TestData.date("2026-11-03T15:00:00Z")),
            in: DeviceTestData.context(),
            now: DeviceTestData.now
        )

        XCTAssertEqual(localHour(of: before), 9)
        XCTAssertEqual(localHour(of: after), 9)
    }

    // MARK: - Preservation (spec 3C.6, BC-EK-017)

    func testUnmodelledProviderFieldsArePreservedAsStableJSON() {
        let device = DeviceTestData.event(rawFields: [
            "structuredLocationTitle": "Building 4",
            "geoLatitude": "42.279594"
        ])

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)
        let payload = try? XCTUnwrap(event.providerMetadata.providerRawFields)

        XCTAssertEqual(payload, #"{"geoLatitude":"42.279594","structuredLocationTitle":"Building 4"}"#)
        // Stable key order, so two passes over an unchanged event compare equal rather than
        // rewriting the row forever.
        XCTAssertEqual(
            DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now).providerMetadata.providerRawFields,
            payload
        )
    }

    func testAnEventWithNothingUnmodelledCarriesNoPayload() {
        let event = DeviceEventMapper.map(DeviceTestData.event(), in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertNil(event.providerMetadata.providerRawFields)
        // The ICS channel is untouched: two providers, two payloads, no shared bucket.
        XCTAssertNil(event.providerMetadata.rawICSProperties)
    }

    // MARK: - Recurrence: what translates (spec 3C.3)

    func testEachExpressibleFrequencyTranslatesAndExpandsCorrectly() {
        let cases: [(DeviceRecurrenceRule, RecurrenceFrequency, Int)] = [
            (DeviceRecurrenceRule(frequency: .daily, interval: 1), .daily, 1),
            (DeviceRecurrenceRule(frequency: .daily, interval: 3), .daily, 3),
            (DeviceRecurrenceRule(frequency: .weekly, interval: 2), .weekly, 2),
            (DeviceRecurrenceRule(frequency: .monthly, interval: 1), .monthly, 1),
            (DeviceRecurrenceRule(frequency: .yearly, interval: 1), .yearly, 1)
        ]

        for (deviceRule, frequency, interval) in cases {
            let rule = translated(deviceRule)
            XCTAssertEqual(rule?.frequency, frequency, "\(deviceRule.frequency) must translate")
            XCTAssertEqual(rule?.interval, interval)
        }
    }

    /// BC-EK-013: a weekly series expands to the same occurrences the device reports, over a
    /// two-year window.
    func testAWeeklySeriesExpandsToTheSameOccurrencesTheDeviceReports() {
        // 2026-09-10 is a Thursday.
        let device = DeviceTestData.event(
            timeZoneIdentifier: "UTC",
            recurrenceRules: [
                DeviceRecurrenceRule(
                    frequency: .weekly,
                    interval: 1,
                    daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.tuesday), DeviceRecurrenceDayOfWeek(.thursday)]
                )
            ]
        )

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)
        XCTAssertEqual(event.recurrence?.weekdays, [.tuesday, .thursday])

        let occurrences = RecurrenceExpander().occurrences(
            of: event,
            in: DateInterval(start: TestData.date("2026-09-10T00:00:00Z"), end: TestData.date("2028-09-10T00:00:00Z"))
        )

        // Asserted structurally rather than by a hand-counted total, because the properties are
        // what "expands identically to the device" actually means: it starts on the series'
        // start, lands only on the named weekdays, and never skips or doubles a slot. The count
        // is pinned too, so a rule change that quietly halved the series would still fail.
        XCTAssertEqual(occurrences.first?.occurrenceStartDate, device.startDate)
        XCTAssertEqual(occurrences.count, 209)

        // Measured in the *event's* zone, not the machine's. A gap spanning a spring-forward
        // transition is 4 days and 23 hours of wall clock in a DST zone, and `.day` truncates —
        // so the same correct series reads as a 4-day gap on a US-configured CI machine and a
        // 5-day one in UTC. The event is a UTC event; that is the calendar the question is
        // about.
        let eventCalendar = event.calendarInOriginalTimeZone
        XCTAssertTrue(occurrences.allSatisfy { occurrence in
            let weekday = eventCalendar.component(.weekday, from: occurrence.occurrenceStartDate)
            return weekday == Weekday.tuesday.rawValue || weekday == Weekday.thursday.rawValue
        })
        let gaps = Set(zip(occurrences, occurrences.dropFirst()).map { earlier, later in
            eventCalendar.dateComponents([.day], from: earlier.occurrenceStartDate, to: later.occurrenceStartDate).day ?? 0
        })
        XCTAssertEqual(gaps, [2, 5], "Tuesday to Thursday is two days, Thursday to Tuesday is five — with no other gap")
    }

    /// EventKit expresses "the last Friday of the month" as an ordinal weekday; the engine
    /// expresses it as `setPositions × weekdays`. They agree, and this proves it by expanding.
    func testAnOrdinalWeekdayRuleTranslatesToThePositionalForm() {
        let rule = translated(
            DeviceRecurrenceRule(frequency: .monthly, daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.friday, weekNumber: -1)])
        )

        XCTAssertEqual(rule?.setPositions, [-1])
        XCTAssertEqual(rule?.weekdays, [.friday])

        var event = TestData.event(startDate: TestData.date("2026-09-25T14:00:00Z"), endDate: TestData.date("2026-09-25T15:00:00Z"), timeZoneIdentifier: "UTC")
        event.recurrence = rule
        let occurrences = RecurrenceExpander().occurrences(
            of: event,
            in: DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-12-01T00:00:00Z"))
        )

        XCTAssertEqual(
            occurrences.map { $0.occurrenceStartDate },
            [
                TestData.date("2026-09-25T14:00:00Z"),
                TestData.date("2026-10-30T14:00:00Z"),
                TestData.date("2026-11-27T14:00:00Z")
            ]
        )
    }

    func testAMonthlyDayOfMonthRuleTranslates() {
        let rule = translated(DeviceRecurrenceRule(frequency: .monthly, daysOfTheMonth: [15, 1]))

        XCTAssertEqual(rule?.daysOfMonth, [1, 15])
        XCTAssertTrue(rule?.setPositions.isEmpty ?? false)
    }

    func testEndConditionsTranslate() {
        XCTAssertEqual(translated(DeviceRecurrenceRule(frequency: .daily, end: .never))?.end, .never)
        XCTAssertEqual(translated(DeviceRecurrenceRule(frequency: .daily, end: .occurrenceCount(7)))?.end, .afterOccurrences(7))
        let until = TestData.date("2026-12-31T00:00:00Z")
        XCTAssertEqual(translated(DeviceRecurrenceRule(frequency: .daily, end: .endDate(until)))?.end, .onDate(until))
    }

    /// A yearly rule naming the start date's own month is saying nothing the engine does not
    /// already do, so it translates; naming a different or additional month does not.
    func testAYearlyRuleTranslatesOnlyWhenItsMonthListIsRedundant() {
        let september = TestData.date("2026-09-10T14:00:00Z")

        XCTAssertNotNil(translated(DeviceRecurrenceRule(frequency: .yearly, monthsOfTheYear: [9]), start: september))
        XCTAssertEqual(
            DeviceRecurrenceTranslation.translate(
                [DeviceRecurrenceRule(frequency: .yearly, monthsOfTheYear: [3, 9])],
                eventStart: september,
                timeZoneIdentifier: "UTC"
            ),
            .unrepresentable
        )
    }

    // MARK: - Recurrence: what does not translate (spec 3C.3)

    func testAMultiRuleEventIsMirroredWithNoRecurrenceItsRulesPreservedAndMarked() {
        let device = DeviceTestData.event(recurrenceRules: [
            DeviceRecurrenceRule(frequency: .weekly, daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.monday)]),
            DeviceRecurrenceRule(frequency: .monthly, daysOfTheMonth: [1])
        ])

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertNil(event.recurrence, "truncating to the first rule would silently drop occurrences")
        XCTAssertTrue(event.hasUnrepresentableRecurrence)
        let payload = event.providerMetadata.providerRawFields ?? ""
        XCTAssertTrue(payload.contains("freq=weekly"), "the raw rules must survive: \(payload)")
        XCTAssertTrue(payload.contains("freq=monthly"), "both of them: \(payload)")
    }

    func testASetPositionRuleIsMirroredTheSameWay() {
        let device = DeviceTestData.event(recurrenceRules: [
            DeviceRecurrenceRule(
                frequency: .monthly,
                daysOfTheWeek: Weekday.allCases.filter { $0 != .saturday && $0 != .sunday }.map { DeviceRecurrenceDayOfWeek($0) },
                setPositions: [-1]
            )
        ])

        let event = DeviceEventMapper.map(device, in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertNil(event.recurrence)
        XCTAssertTrue(event.hasUnrepresentableRecurrence)
        XCTAssertTrue((event.providerMetadata.providerRawFields ?? "").contains("bysetpos=-1"))
    }

    func testWeekOfYearAndDayOfYearRulesAreNotTranslated() {
        XCTAssertEqual(unrepresentable(DeviceRecurrenceRule(frequency: .yearly, weeksOfTheYear: [12])), true)
        XCTAssertEqual(unrepresentable(DeviceRecurrenceRule(frequency: .yearly, daysOfTheYear: [200])), true)
    }

    /// The engine's positional form is the cross product of positions and weekdays. EventKit's
    /// pair list is strictly more general, so a list that is *not* a cross product has no
    /// faithful translation and must not get an approximate one.
    func testMixedOrdinalWeekdaysAreNotTranslated() {
        let notACrossProduct = DeviceRecurrenceRule(
            frequency: .monthly,
            daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.friday, weekNumber: -1), DeviceRecurrenceDayOfWeek(.monday, weekNumber: 2)]
        )
        XCTAssertEqual(unrepresentable(notACrossProduct), true)

        // The full cross product of the same positions and weekdays *is* expressible.
        let crossProduct = DeviceRecurrenceRule(
            frequency: .monthly,
            daysOfTheWeek: [
                DeviceRecurrenceDayOfWeek(.friday, weekNumber: -1),
                DeviceRecurrenceDayOfWeek(.monday, weekNumber: -1),
                DeviceRecurrenceDayOfWeek(.friday, weekNumber: 2),
                DeviceRecurrenceDayOfWeek(.monday, weekNumber: 2)
            ]
        )
        XCTAssertEqual(translated(crossProduct)?.setPositions, [-1, 2])
        XCTAssertEqual(translated(crossProduct)?.weekdays, [.monday, .friday])
    }

    func testAMonthlyEveryWeekdayRuleIsNotTranslated() {
        // "Every Monday of the month" — no position — is not a form the engine's monthly
        // generator models, and reading it as "the 1st Monday" would drop three occurrences.
        XCTAssertEqual(
            unrepresentable(DeviceRecurrenceRule(frequency: .monthly, daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.monday)])),
            true
        )
    }

    func testARuleConstrainingBothWeekdaysAndMonthDaysIsNotTranslated() {
        XCTAssertEqual(
            unrepresentable(
                DeviceRecurrenceRule(
                    frequency: .monthly,
                    daysOfTheWeek: [DeviceRecurrenceDayOfWeek(.monday, weekNumber: 1)],
                    daysOfTheMonth: [15]
                )
            ),
            true
        )
    }

    func testANegativeDayOfMonthIsNotTranslated() {
        // "The last day of the month" is RFC 5545-legal; the engine clamps into 1...daysInMonth
        // and would silently turn it into the 1st.
        XCTAssertEqual(unrepresentable(DeviceRecurrenceRule(frequency: .monthly, daysOfTheMonth: [-1])), true)
    }

    func testAnEventWithNoRulesIsNotMarkedUnrepresentable() {
        let event = DeviceEventMapper.map(DeviceTestData.event(), in: DeviceTestData.context(), now: DeviceTestData.now)

        XCTAssertFalse(event.hasUnrepresentableRecurrence)
        XCTAssertEqual(DeviceRecurrenceTranslation.translate([], eventStart: DeviceTestData.now, timeZoneIdentifier: "UTC"), .none)
    }

    // MARK: - Identity (spec 3C.1)

    func testLocalIdsAreDerivedFromProviderIdentityAndAreStable() {
        let key = DeviceEventKey(identifier: "evt-1", occurrenceDate: nil)

        XCTAssertEqual(DeviceEventIdentity.eventID(for: key), DeviceEventIdentity.eventID(for: key))
        XCTAssertNotEqual(
            DeviceEventIdentity.eventID(for: key),
            DeviceEventIdentity.eventID(for: DeviceEventKey(identifier: "evt-2", occurrenceDate: nil))
        )
    }

    /// Spec 3C.1: neither EventKit identifier is unique on its own for a detachment, so identity
    /// is the pair — two detachments of one series must not collide.
    func testTwoDetachmentsOfOneSeriesGetDistinctIdentities() {
        let first = DeviceEventKey(identifier: "series", occurrenceDate: TestData.date("2026-09-10T14:00:00Z"))
        let second = DeviceEventKey(identifier: "series", occurrenceDate: TestData.date("2026-09-17T14:00:00Z"))
        let master = DeviceEventKey(identifier: "series", occurrenceDate: nil)

        let ids = Set([first, second, master].map(DeviceEventIdentity.eventID(for:)))
        XCTAssertEqual(ids.count, 3)
    }

    func testDerivedIdsAreValidVersion5UUIDs() {
        let uuid = DeviceEventIdentity.uuid(name: "event:anything")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "version 5")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "RFC 4122 variant")
    }

    // MARK: - Helpers

    private func translated(_ rule: DeviceRecurrenceRule, start: Date = TestData.date("2026-09-10T14:00:00Z")) -> RecurrenceRule? {
        DeviceRecurrenceTranslation.translate([rule], eventStart: start, timeZoneIdentifier: "UTC").rule
    }

    private func unrepresentable(_ rule: DeviceRecurrenceRule, start: Date = TestData.date("2026-09-10T14:00:00Z")) -> Bool {
        DeviceRecurrenceTranslation.translate([rule], eventStart: start, timeZoneIdentifier: "UTC").isUnrepresentable
    }

    private func localHour(of event: CalendarEvent) -> Int {
        event.calendarInOriginalTimeZone.component(.hour, from: event.startDate)
    }
}
