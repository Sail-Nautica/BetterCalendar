import Foundation

struct LocalCalendarDatabase: Codable, Equatable {
    var schemaVersion: Int
    var calendars: [BetterCalendar]
    var events: [CalendarEvent]
    var pendingMutations: [PendingMutation]
    var deletedEventTombstones: [DeletedEventTombstone]

    static let currentSchemaVersion = 1
}

struct BetterCalendar: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var colorName: CalendarColorName
    var isVisible: Bool
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date

    static func localDefault(now: Date = .now) -> BetterCalendar {
        BetterCalendar(
            id: UUID(),
            name: "School",
            colorName: .betterBlue,
            isVisible: true,
            isDefault: true,
            createdAt: now,
            updatedAt: now
        )
    }
}

enum CalendarColorName: String, CaseIterable, Identifiable, Codable {
    case betterBlue = "Better Blue"
    case success = "Success"
    case warning = "Warning"
    case destructive = "Destructive"
    case navy = "Navy"
    case gray = "Gray"

    var id: String { rawValue }
}

struct CalendarEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var calendarID: BetterCalendar.ID
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var timeZoneIdentifier: String
    var location: String?
    var urlString: String?
    var notes: String?
    var reminders: [EventReminder]
    var recurrence: RecurrenceRule?
    var providerMetadata: ProviderMetadata
    var createdAt: Date
    var updatedAt: Date

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}

struct ProviderMetadata: Codable, Hashable {
    var provider: EventProvider
    var providerAccountID: String?
    var providerCalendarID: String?
    var providerObjectID: String?
    var providerVersion: String?
    var syncStatus: SyncStatus
    var deletedAt: Date?

    static let local = ProviderMetadata(
        provider: .betterCalendar,
        providerAccountID: nil,
        providerCalendarID: nil,
        providerObjectID: nil,
        providerVersion: nil,
        syncStatus: .synced,
        deletedAt: nil
    )
}

enum EventProvider: String, Codable, CaseIterable, Identifiable {
    case betterCalendar = "Better Calendar"
    case google = "Google"
    case apple = "Apple"
    case university = "U-M"

    var id: String { rawValue }
}

enum SyncStatus: String, Codable, CaseIterable, Identifiable {
    case synced = "Synced"
    case pendingCreate = "Pending Create"
    case pendingUpdate = "Pending Update"
    case pendingDelete = "Pending Delete"
    case failed = "Failed"

    var id: String { rawValue }
}

struct EventReminder: Identifiable, Codable, Hashable {
    var id: UUID
    var offset: ReminderOffset
}

enum ReminderOffset: Codable, Hashable, CaseIterable, Identifiable {
    case none
    case atStart
    case minutesBefore(Int)
    case daysBefore(Int)

    var id: String { label }

    var label: String {
        switch self {
        case .none: "None"
        case .atStart: "At time of event"
        case .minutesBefore(let minutes): "\(minutes) minutes before"
        case .daysBefore(let days): "\(days) days before"
        }
    }

    static var allCases: [ReminderOffset] {
        [.none, .atStart, .minutesBefore(5), .minutesBefore(10), .minutesBefore(15), .minutesBefore(30), .daysBefore(1), .daysBefore(7)]
    }
}

struct RecurrenceRule: Codable, Hashable {
    var frequency: RecurrenceFrequency
    var interval: Int
    var weekdays: Set<Weekday>
    var end: RecurrenceEnd

    var summary: String {
        guard frequency != .never else { return "Never" }

        let cadence = interval == 1 ? frequency.label : "Every \(interval) \(frequency.pluralLabel)"
        let dayText = weekdays.isEmpty ? "" : " on " + weekdays.sorted().map(\.shortLabel).joined(separator: ", ")
        return cadence + dayText + end.label
    }

    nonisolated static let never = RecurrenceRule(frequency: .never, interval: 1, weekdays: [], end: .never)
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case never
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    var pluralLabel: String {
        switch self {
        case .never: "events"
        case .daily: "days"
        case .weekly: "weeks"
        case .monthly: "months"
        case .yearly: "years"
        }
    }
}

enum Weekday: Int, Codable, CaseIterable, Comparable, Identifiable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RecurrenceEnd: Codable, Hashable {
    case never
    case afterOccurrences(Int)
    case onDate(Date)

    var label: String {
        switch self {
        case .never: ""
        case .afterOccurrences(let count): ", ends after \(count) occurrences"
        case .onDate(let date): ", ends \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

struct PendingMutation: Identifiable, Codable, Hashable {
    var id: UUID
    var objectID: UUID
    var objectType: MutationObjectType
    var operation: MutationOperation
    var createdAt: Date
}

enum MutationObjectType: String, Codable {
    case event
    case calendar
}

enum MutationOperation: String, Codable {
    case create
    case update
    case delete
}

struct DeletedEventTombstone: Identifiable, Codable, Hashable {
    var id: UUID
    var eventID: UUID
    var title: String
    var deletedAt: Date
}

struct EventDraft: Equatable {
    var id: UUID?
    var calendarID: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var timeZoneIdentifier: String
    var location: String
    var urlString: String
    var notes: String
    var reminderOffset: ReminderOffset
    var recurrence: RecurrenceRule

    nonisolated init(event: CalendarEvent) {
        id = event.id
        calendarID = event.calendarID
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        timeZoneIdentifier = event.timeZoneIdentifier
        location = event.location ?? ""
        urlString = event.urlString ?? ""
        notes = event.notes ?? ""
        reminderOffset = event.reminders.first?.offset ?? .none
        recurrence = event.recurrence ?? .never
    }

    init(calendarID: UUID, startDate: Date = .now, duration: TimeInterval = 60 * 60) {
        let roundedStart = Calendar.current.nextDate(after: startDate, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? startDate
        id = nil
        self.calendarID = calendarID
        title = ""
        self.startDate = roundedStart
        endDate = roundedStart.addingTimeInterval(duration)
        isAllDay = false
        timeZoneIdentifier = TimeZone.current.identifier
        location = ""
        urlString = ""
        notes = ""
        reminderOffset = .none
        recurrence = .never
    }

    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a title before saving."
        }

        if !isAllDay && endDate <= startDate {
            return "End time must be after start time."
        }

        return nil
    }
}
