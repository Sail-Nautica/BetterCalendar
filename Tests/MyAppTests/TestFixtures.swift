import Foundation
@testable import Better_Calendar

enum TestData {
    static let calendarID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let secondCalendarID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let eventID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            preconditionFailure("Invalid test date: \(value)")
        }
        return date
    }

    static func calendar(
        id: UUID = calendarID,
        name: String = "School",
        isDefault: Bool = true,
        sortOrder: Int = 0
    ) -> BetterCalendar {
        BetterCalendar(
            id: id,
            name: name,
            colorName: .betterBlue,
            isVisible: true,
            isDefault: isDefault,
            sortOrder: sortOrder,
            createdAt: date("2026-09-01T12:00:00Z"),
            updatedAt: date("2026-09-01T12:00:00Z")
        )
    }

    static func event(
        id: UUID = eventID,
        calendarID: UUID = calendarID,
        title: String = "Calculus Lecture",
        startDate: Date = date("2026-09-02T14:00:00Z"),
        endDate: Date = date("2026-09-02T15:00:00Z"),
        isAllDay: Bool = false,
        timeType: EventTimeType? = nil,
        timeZoneIdentifier: String = "UTC",
        location: String? = nil,
        urlString: String? = nil,
        notes: String? = nil,
        recurrence: RecurrenceRule? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            // `timeType` wins when supplied; otherwise fall back to the boolean so every
            // existing call site keeps its previous meaning.
            timeType: timeType ?? (isAllDay ? .allDay : .timed),
            timeZoneIdentifier: timeZoneIdentifier,
            location: location,
            urlString: urlString,
            notes: notes,
            reminders: [],
            recurrence: recurrence,
            providerMetadata: .local,
            createdAt: date("2026-09-01T12:00:00Z"),
            updatedAt: date("2026-09-01T12:00:00Z")
        )
    }

    static func database(
        calendars: [BetterCalendar] = [calendar()],
        events: [CalendarEvent] = [event()],
        pendingMutations: [PendingMutation] = [],
        deletedEventTombstones: [DeletedEventTombstone] = []
    ) -> LocalCalendarDatabase {
        LocalCalendarDatabase(
            schemaVersion: LocalCalendarDatabase.currentSchemaVersion,
            calendars: calendars,
            events: events,
            pendingMutations: pendingMutations,
            deletedEventTombstones: deletedEventTombstones
        )
    }

    /// Spec 2.19's 10,000-event performance fixture: a production-shaped mix of plain timed
    /// events (7 in 10), all-day events (1 in 10), and recurring series (2 in 10, a twentieth of
    /// which carry a cancelled-occurrence exception too) spread across `calendarCount` calendars
    /// and a two-year date range — so a range-scoped query and a full-table operation alike have
    /// realistic work to do, per M1's migration-fixture guidance ("fixtures must carry recurrence
    /// rules, exceptions... not just plain timed events").
    ///
    /// The event *mix and dates* are a deterministic function of `count` alone (index arithmetic,
    /// never `Date.now`/`.random`), so a failing perf assertion reproduces identically across
    /// runs and machines; individual event/exception ids are still fresh `UUID()`s, same as every
    /// other fixture in this file — nothing compares ids across two calls to this function.
    static func largeEventSet(count: Int = 10_000, calendarCount: Int = 5) -> (calendars: [BetterCalendar], events: [CalendarEvent], exceptions: [RecurrenceException]) {
        let calendars = (0..<calendarCount).map { index in
            calendar(id: UUID(), name: "Calendar \(index)", isDefault: index == 0, sortOrder: index)
        }
        let baseDate = date("2026-01-01T00:00:00Z")

        var events: [CalendarEvent] = []
        var exceptions: [RecurrenceException] = []
        events.reserveCapacity(count)

        for index in 0..<count {
            let calendarID = calendars[index % calendarCount].id
            // Spread across ~2 years, 12 possible times of day, so events cluster realistically
            // rather than landing on one instant.
            let start = baseDate.addingTimeInterval(TimeInterval(index % 730) * 86_400 + TimeInterval(index % 12) * 3600)

            switch index % 10 {
            case 0:
                events.append(event(id: UUID(), calendarID: calendarID, title: "All-day \(index)", startDate: start, endDate: start.addingTimeInterval(86_400), isAllDay: true))
            case 1, 2:
                let masterID = UUID()
                events.append(event(
                    id: masterID,
                    calendarID: calendarID,
                    title: "Recurring \(index)",
                    startDate: start,
                    endDate: start.addingTimeInterval(3600),
                    recurrence: RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [.monday], end: .afterOccurrences(10))
                ))
                if index % 20 == 1 {
                    exceptions.append(RecurrenceException(
                        id: UUID(),
                        masterEventID: masterID,
                        originalOccurrenceStart: start.addingTimeInterval(7 * 86_400),
                        originalOccurrenceLocalDate: nil,
                        exceptionType: .cancelled,
                        replacementEventID: nil
                    ))
                }
            default:
                events.append(event(id: UUID(), calendarID: calendarID, title: "Event \(index)", startDate: start, endDate: start.addingTimeInterval(1800)))
            }
        }

        return (calendars, events, exceptions)
    }

    /// Spec 2.16's three-zone travel scenario: three meetings, each created while the user was
    /// physically in a different zone, so a dual-time display over the trip is exercised against
    /// real distinct offsets (US Eastern, UK, Japan) rather than one hand-picked pair. Matches
    /// CLAUDE.md's storage model: each event carries a UTC instant plus the IANA zone it was
    /// created in, never a raw offset.
    static func threeZoneTravelEvents() -> [CalendarEvent] {
        [
            event(id: UUID(), title: "New York kickoff", startDate: date("2026-09-02T14:00:00Z"), endDate: date("2026-09-02T15:00:00Z"), timeZoneIdentifier: "America/New_York"),
            event(id: UUID(), title: "London sync", startDate: date("2026-09-04T14:00:00Z"), endDate: date("2026-09-04T15:00:00Z"), timeZoneIdentifier: "Europe/London"),
            event(id: UUID(), title: "Tokyo review", startDate: date("2026-09-06T14:00:00Z"), endDate: date("2026-09-06T15:00:00Z"), timeZoneIdentifier: "Asia/Tokyo")
        ]
    }
}

final class StubCalendarRepository: LocalCalendarRepository {
    var loadResult: Result<LocalCalendarDatabase, Error>
    var saveError: Error?
    private(set) var savedDatabases: [LocalCalendarDatabase] = []
    /// Transactions passed to `apply`, in order, so a test can assert on the *shape* of a
    /// mutation (spec 2.2) and not only on the database that came out the other end.
    private(set) var appliedTransactions: [EngineTransaction] = []

    init(loadResult: Result<LocalCalendarDatabase, Error> = .success(TestData.database()), saveError: Error? = nil) {
        self.loadResult = loadResult
        self.saveError = saveError
    }

    func load() throws -> LocalCalendarDatabase {
        try loadResult.get()
    }

    func save(_ database: LocalCalendarDatabase) throws {
        if let saveError {
            throw saveError
        }
        savedDatabases.append(database)
    }

    /// Folds the transaction into the stub's own state so a later `load()` observes it, which
    /// is what makes the stub behave like a real repository across a save/reload cycle.
    func apply(_ transaction: EngineTransaction) throws {
        if let saveError {
            throw saveError
        }
        let updated = try loadResult.get().applying(transaction)
        appliedTransactions.append(transaction)
        savedDatabases.append(updated)
        loadResult = .success(updated)
    }

    func searchEventIDs(matching query: String) throws -> [UUID] {
        let database = try loadResult.get()
        let lowercasedQuery = query.lowercased()
        let calendarNamesByID = Dictionary(uniqueKeysWithValues: database.calendars.map { ($0.id, $0.name) })

        return database.events
            .filter { event in
                event.title.lowercased().contains(lowercasedQuery)
                    || (event.notes?.lowercased().contains(lowercasedQuery) ?? false)
                    || (event.location?.lowercased().contains(lowercasedQuery) ?? false)
                    || (calendarNamesByID[event.calendarID]?.lowercased().contains(lowercasedQuery) ?? false)
                    || (event.urlString.flatMap { URL(string: $0)?.host }?.lowercased().contains(lowercasedQuery) ?? false)
            }
            .map(\.id)
    }

    func diagnostics() throws -> RepositoryDiagnostics {
        .unavailable
    }
}

enum TestRepositoryError: Error {
    case loadFailed
    case saveFailed
}

/// Spec 3.36/3C.11: the device side of Phase 3C's fixtures — a two-account device, its mirrored
/// calendar rows, and a builder for the events on them.
///
/// Shared across `DeviceEventMappingTests`, `DeviceEventMirrorTests` and `DeviceEventStoreTests`
/// so all three describe the same device, and a test that disagrees with another about what the
/// fixture *is* cannot happen.
enum DeviceTestData {
    static let now = TestData.date("2026-09-04T09:00:00Z")

    static let icloudSource = DeviceCalendarSource(identifier: "source-icloud", title: "iCloud", type: .mobileMe)
    static let exchangeSource = DeviceCalendarSource(identifier: "source-exchange", title: "Work Exchange", type: .exchange)

    static let personalCalendar = DeviceCalendar(
        identifier: "cal-personal",
        source: icloudSource,
        title: "Personal",
        type: .calDAV,
        colorHex: "#2B6CE8"
    )
    static let workCalendar = DeviceCalendar(
        identifier: "cal-work",
        source: exchangeSource,
        title: "Work",
        type: .exchange,
        colorHex: "#7B2D8E"
    )
    static let holidaysCalendar = DeviceCalendar(
        identifier: "cal-holidays",
        source: icloudSource,
        title: "US Holidays",
        type: .calDAV,
        isSubscribed: true,
        allowsContentModifications: false
    )

    static let devices = [personalCalendar, workCalendar, holidaysCalendar]

    static func snapshot(defaultCalendarIdentifier: String? = "cal-personal") -> DeviceCalendarSnapshot {
        DeviceCalendarSnapshot(calendars: devices, defaultCalendarIdentifierForNewEvents: defaultCalendarIdentifier)
    }

    /// A mirrored `BetterCalendar` row for one of the fixture's device calendars, as
    /// `DeviceCalendarMirror` would have written it. Built directly rather than by running a
    /// discovery pass so a mapping test does not depend on the discovery planner.
    static func mirroredRow(
        for device: DeviceCalendar,
        id: UUID,
        isVisible: Bool = true,
        isUnavailable: Bool = false
    ) -> BetterCalendar {
        BetterCalendar(
            id: id,
            name: device.title,
            colorName: .betterBlue,
            isVisible: isVisible,
            isDefault: false,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            provider: device.source.provider,
            connectionMethod: .device,
            providerAccountID: device.source.identifier,
            providerCalendarID: device.identifier,
            accountName: device.source.title,
            colorHex: device.colorHex,
            isReadOnly: device.isReadOnly,
            capabilities: device.capabilities,
            isUnavailable: isUnavailable
        )
    }

    static let personalRowID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let workRowID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    static let holidaysRowID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!

    static var mirroredCalendars: [BetterCalendar] {
        [
            mirroredRow(for: personalCalendar, id: personalRowID),
            mirroredRow(for: workCalendar, id: workRowID),
            mirroredRow(for: holidaysCalendar, id: holidaysRowID)
        ]
    }

    static func event(
        identifier: String = "evt-1",
        externalIdentifier: String? = "ext-1",
        calendarIdentifier: String = "cal-personal",
        title: String = "Standup",
        notes: String? = nil,
        location: String? = nil,
        urlString: String? = nil,
        startDate: Date = TestData.date("2026-09-10T14:00:00Z"),
        endDate: Date = TestData.date("2026-09-10T14:30:00Z"),
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = "America/New_York",
        availability: DeviceEventAvailability = .busy,
        status: DeviceEventStatus = .confirmed,
        alarms: [DeviceEventAlarm] = [],
        recurrenceRules: [DeviceRecurrenceRule] = [],
        attendees: [DeviceEventAttendee] = [],
        lastModified: Date? = TestData.date("2026-09-01T08:00:00Z"),
        isDetached: Bool = false,
        occurrenceDate: Date? = nil,
        rawFields: [String: String] = [:]
    ) -> DeviceEvent {
        DeviceEvent(
            identifier: identifier,
            externalIdentifier: externalIdentifier,
            calendarIdentifier: calendarIdentifier,
            title: title,
            notes: notes,
            location: location,
            urlString: urlString,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            availability: availability,
            status: status,
            alarms: alarms,
            recurrenceRules: recurrenceRules,
            attendees: attendees,
            lastModified: lastModified,
            isDetached: isDetached,
            occurrenceDate: occurrenceDate,
            rawFields: rawFields
        )
    }

    static func context(
        calendarID: UUID = personalRowID,
        provider: EventProvider = .apple,
        deviceTimeZoneIdentifier: String = "America/New_York",
        localID: UUID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
        createdAt: Date = now
    ) -> DeviceEventMapper.Context {
        DeviceEventMapper.Context(
            calendarID: calendarID,
            provider: provider,
            deviceTimeZoneIdentifier: deviceTimeZoneIdentifier,
            localID: localID,
            createdAt: createdAt
        )
    }

    /// The window the mirror tests use unless they are specifically about window boundaries.
    static let window = DateInterval(
        start: TestData.date("2026-09-01T00:00:00Z"),
        end: TestData.date("2026-10-01T00:00:00Z")
    )

    static func input(
        devices: [DeviceEvent],
        window: DateInterval = window,
        fetchedCalendarIDs: Set<UUID> = [personalRowID, workRowID, holidaysRowID],
        calendars: [BetterCalendar]? = nil,
        existingEvents: [CalendarEvent] = [],
        existingExceptions: [RecurrenceException] = [],
        tombstones: [DeletedEventTombstone] = [],
        deviceTimeZoneIdentifier: String = "America/New_York"
    ) -> DeviceEventMirror.Input {
        DeviceEventMirror.Input(
            devices: devices,
            window: window,
            fetchedCalendarIDs: fetchedCalendarIDs,
            calendars: calendars ?? mirroredCalendars,
            existingEvents: existingEvents,
            existingExceptions: existingExceptions,
            tombstones: tombstones,
            deviceTimeZoneIdentifier: deviceTimeZoneIdentifier
        )
    }

    /// The events a plan would upsert, in emission order.
    static func upsertedEvents(_ plan: DeviceEventMirror.Plan) -> [CalendarEvent] {
        plan.changes.compactMap { change in
            guard case .upsertEvent(let event) = change else { return nil }
            return event
        }
    }

    static func deletedEventIDs(_ plan: DeviceEventMirror.Plan) -> [UUID] {
        plan.changes.compactMap { change in
            guard case .deleteEvent(let id) = change else { return nil }
            return id
        }
    }

    static func upsertedExceptions(_ plan: DeviceEventMirror.Plan) -> [RecurrenceException] {
        plan.changes.compactMap { change in
            guard case .upsertRecurrenceException(let exception) = change else { return nil }
            return exception
        }
    }
}
