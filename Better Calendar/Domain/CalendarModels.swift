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

/// How an event's stored dates should be interpreted (specification 0.9).
///
/// - `timed`: real instants. The clock time shifts when the viewing time zone changes.
/// - `allDay`: calendar dates. The date never shifts when the viewing time zone changes.
/// - `floating`: the same wall-clock time everywhere ("take medication at 8:00 PM wherever
///   I am"). The clock time is preserved and re-anchored into whatever zone is displaying it.
enum EventTimeType: String, Codable, CaseIterable, Identifiable, Hashable {
    case timed
    case allDay
    case floating

    var id: String { rawValue }
}

struct CalendarEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var calendarID: BetterCalendar.ID
    var title: String
    var startDate: Date
    var endDate: Date
    var timeType: EventTimeType
    var timeZoneIdentifier: String
    var location: String?
    var urlString: String?
    var notes: String?
    var reminders: [EventReminder]
    var recurrence: RecurrenceRule?
    var providerMetadata: ProviderMetadata
    var createdAt: Date
    var updatedAt: Date

    /// Compatibility accessor over `timeType`, so the many existing call sites that think in
    /// terms of a boolean keep working.
    ///
    /// The setter deliberately does **not** collapse to `newValue ? .allDay : .timed`: that
    /// would silently destroy `.floating` on any code path that assigns `false`, converting a
    /// floating event into a timed one without anyone asking. Assigning `false` to an event
    /// that is already floating leaves it floating.
    var isAllDay: Bool {
        get { timeType == .allDay }
        set {
            if newValue {
                timeType = .allDay
            } else if timeType == .allDay {
                timeType = .timed
            }
        }
    }

    var isFloating: Bool {
        timeType == .floating
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, calendarID, title, startDate, endDate, timeType, isAllDay
        case timeZoneIdentifier, location, urlString, notes, reminders
        case recurrence, providerMetadata, createdAt, updatedAt
    }

    /// Decodes tolerantly so databases written before `timeType` existed still load.
    ///
    /// Legacy payloads carry `isAllDay` and no `timeType`. Without this fallback the decode
    /// throws, `JSONCalendarRepository.load()` fails, and the store quietly falls back to seed
    /// data — presenting sample events as if the user's calendar were empty. That is a silent
    /// data-loss path, so the legacy key is honoured rather than merely tolerated.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        calendarID = try container.decode(BetterCalendar.ID.self, forKey: .calendarID)
        title = try container.decode(String.self, forKey: .title)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        reminders = try container.decode([EventReminder].self, forKey: .reminders)
        recurrence = try container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        providerMetadata = try container.decode(ProviderMetadata.self, forKey: .providerMetadata)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        if let decodedTimeType = try container.decodeIfPresent(EventTimeType.self, forKey: .timeType) {
            timeType = decodedTimeType
        } else if try container.decodeIfPresent(Bool.self, forKey: .isAllDay) == true {
            timeType = .allDay
        } else {
            timeType = .timed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(calendarID, forKey: .calendarID)
        try container.encode(title, forKey: .title)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(timeType, forKey: .timeType)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(urlString, forKey: .urlString)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(reminders, forKey: .reminders)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encode(providerMetadata, forKey: .providerMetadata)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Boolean-shaped initializer preserving the pre-`timeType` signature.
    ///
    /// Declared in an extension on purpose: adding an initializer to the struct body would
    /// suppress the synthesized memberwise initializer, and every construction site that now
    /// passes `timeType:` would stop compiling.
    init(
        id: UUID,
        calendarID: BetterCalendar.ID,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        timeZoneIdentifier: String,
        location: String?,
        urlString: String?,
        notes: String?,
        reminders: [EventReminder],
        recurrence: RecurrenceRule?,
        providerMetadata: ProviderMetadata,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.init(
            id: id,
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            timeType: isAllDay ? .allDay : .timed,
            timeZoneIdentifier: timeZoneIdentifier,
            location: location,
            urlString: urlString,
            notes: notes,
            reminders: reminders,
            recurrence: recurrence,
            providerMetadata: providerMetadata,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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
        case .none:
            "None"
        case .atStart:
            "At time of event"
        case .minutesBefore(let minutes) where minutes % 60 == 0:
            minutes / 60 == 1 ? "1 hour before" : "\(minutes / 60) hours before"
        case .minutesBefore(let minutes):
            "\(minutes) minutes before"
        case .daysBefore(let days) where days % 7 == 0:
            days / 7 == 1 ? "1 week before" : "\(days / 7) weeks before"
        case .daysBefore(let days):
            days == 1 ? "1 day before" : "\(days) days before"
        }
    }

    /// Preset offsets per spec 1.12, in ascending "how soon before the event" order.
    static var allCases: [ReminderOffset] {
        [.none, .atStart, .minutesBefore(5), .minutesBefore(10), .minutesBefore(15), .minutesBefore(30), .minutesBefore(60), .minutesBefore(120), .daysBefore(1), .daysBefore(7)]
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
    var reminderOffsets: [ReminderOffset]
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
        reminderOffsets = event.reminders.map(\.offset).orderPreservingUniqued()
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
        reminderOffsets = []
        recurrence = .never
    }

    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a title before saving."
        }

        if title.count > EventFieldLimits.titleCharacters {
            return "Title must be \(EventFieldLimits.titleCharacters) characters or fewer."
        }

        if !isAllDay && endDate <= startDate {
            return "End time must be after start time."
        }

        if location.count > EventFieldLimits.locationCharacters {
            return "Location must be \(EventFieldLimits.locationCharacters) characters or fewer."
        }

        if notes.count > EventFieldLimits.notesCharacters {
            return "Notes must be \(EventFieldLimits.notesCharacters) characters or fewer."
        }

        return nil
    }
}

/// Field length ceilings from specification 0.8. Over-long input is rejected with an
/// inline error rather than silently truncated, so the user never loses text they typed.
/// Counts are grapheme clusters (`String.count`), matching what a user perceives as a character.
enum EventFieldLimits {
    static let titleCharacters = 500
    static let locationCharacters = 1_000
    static let notesCharacters = 50_000
}

extension Array where Element: Hashable {
    /// Removes duplicate elements while preserving first-seen order.
    func orderPreservingUniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
