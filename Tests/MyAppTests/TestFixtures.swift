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
            urlString: nil,
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
}

final class StubCalendarRepository: LocalCalendarRepository {
    var loadResult: Result<LocalCalendarDatabase, Error>
    var saveError: Error?
    private(set) var savedDatabases: [LocalCalendarDatabase] = []

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
}

enum TestRepositoryError: Error {
    case loadFailed
    case saveFailed
}
