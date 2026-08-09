import Foundation

struct LocalCalendarDatabase: Equatable {
    var schemaVersion: Int
    var calendars: [BetterCalendar]
    var events: [CalendarEvent]
    var pendingMutations: [PendingMutation]
    var deletedEventTombstones: [DeletedEventTombstone]
    var settings: AppSettings = .defaultSettings
    var recurrenceExceptions: [RecurrenceException] = []

    static let currentSchemaVersion = 1
}

extension LocalCalendarDatabase: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, calendars, events, pendingMutations, deletedEventTombstones, settings, recurrenceExceptions
    }

    /// Decodes tolerantly so databases written before `settings`/`recurrenceExceptions`
    /// existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        calendars = try container.decode([BetterCalendar].self, forKey: .calendars)
        events = try container.decode([CalendarEvent].self, forKey: .events)
        pendingMutations = try container.decode([PendingMutation].self, forKey: .pendingMutations)
        deletedEventTombstones = try container.decode([DeletedEventTombstone].self, forKey: .deletedEventTombstones)
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .defaultSettings
        recurrenceExceptions = try container.decodeIfPresent([RecurrenceException].self, forKey: .recurrenceExceptions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(calendars, forKey: .calendars)
        try container.encode(events, forKey: .events)
        try container.encode(pendingMutations, forKey: .pendingMutations)
        try container.encode(deletedEventTombstones, forKey: .deletedEventTombstones)
        try container.encode(settings, forKey: .settings)
        try container.encode(recurrenceExceptions, forKey: .recurrenceExceptions)
    }
}

struct BetterCalendar: Identifiable, Hashable {
    var id: UUID
    var name: String
    var colorName: CalendarColorName
    var isVisible: Bool
    var isDefault: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    static func localDefault(now: Date = .now) -> BetterCalendar {
        BetterCalendar(
            id: UUID(),
            name: "School",
            colorName: .betterBlue,
            isVisible: true,
            isDefault: true,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension BetterCalendar: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, colorName, isVisible, isDefault, sortOrder, createdAt, updatedAt
    }

    /// Decodes tolerantly so calendars written before `sortOrder` existed still load,
    /// defaulting to 0 (matches the previous array-index-derived ordering).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorName = try container.decode(CalendarColorName.self, forKey: .colorName)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(colorName, forKey: .colorName)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum BetterCalendarTab: String, Hashable, Codable {
    case calendar
    case agenda
    case search
}

enum CalendarViewMode: String, CaseIterable, Identifiable, Codable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

enum TimeFormatPreference: String, CaseIterable, Identifiable, Codable {
    case system
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .twelveHour: "12-Hour"
        case .twentyFourHour: "24-Hour"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Spec 1.20 calendar settings, plus the last-view-state fields spec 1.2 requires survive
/// relaunch (BC-VIEW-010) and the onboarding flag spec 1.1 requires (BC-ONB-001). Persisted as
/// individual `application_settings` rows, one key per field — see `SQLiteCalendarRepository`.
struct AppSettings: Codable, Equatable {
    var defaultEventDurationMinutes: Int
    var defaultReminderOffset: ReminderOffset?
    var firstWeekday: Weekday?
    var showWeekends: Bool
    var timeFormat: TimeFormatPreference
    var defaultCalendarView: CalendarViewMode
    var allDayReminderHour: Int
    var snapIntervalMinutes: Int
    var appearance: AppearancePreference
    var reduceCalendarAnimation: Bool
    var hasCompletedOnboarding: Bool
    var lastSelectedTab: BetterCalendarTab?
    var lastSelectedDate: Date?
    var secondaryTimeZoneIdentifier: String?

    static let defaultSettings = AppSettings(
        defaultEventDurationMinutes: 60,
        defaultReminderOffset: nil,
        firstWeekday: nil,
        showWeekends: true,
        timeFormat: .system,
        defaultCalendarView: .day,
        allDayReminderHour: 9,
        snapIntervalMinutes: 15,
        appearance: .system,
        reduceCalendarAnimation: false,
        hasCompletedOnboarding: false,
        lastSelectedTab: nil,
        lastSelectedDate: nil,
        secondaryTimeZoneIdentifier: nil
    )
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
    /// Set only on a standalone replacement event created for a single recurring occurrence
    /// (BC-REC-010, "This Event" edit scope, spec 1.11) — the master series' id.
    var recurrenceMasterID: UUID?
    /// Paired with `recurrenceMasterID`: the occurrence's original start, used both to find an
    /// existing replacement when re-editing the same occurrence and to match the
    /// `RecurrenceException` that hides the master's slot at that date.
    var recurrenceOriginalStart: Date?

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
        case recurrenceMasterID, recurrenceOriginalStart
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
        recurrenceMasterID = try container.decodeIfPresent(UUID.self, forKey: .recurrenceMasterID)
        recurrenceOriginalStart = try container.decodeIfPresent(Date.self, forKey: .recurrenceOriginalStart)

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
        try container.encodeIfPresent(recurrenceMasterID, forKey: .recurrenceMasterID)
        try container.encodeIfPresent(recurrenceOriginalStart, forKey: .recurrenceOriginalStart)
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
        updatedAt: Date,
        recurrenceMasterID: UUID? = nil,
        recurrenceOriginalStart: Date? = nil
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
            updatedAt: updatedAt,
            recurrenceMasterID: recurrenceMasterID,
            recurrenceOriginalStart: recurrenceOriginalStart
        )
    }
}

extension CalendarEvent {
    /// Serializes the full event to JSON for durable tombstone storage (spec 0.12): a deleted
    /// event must survive a force-quit before Undo is tapped, not live only in an in-memory
    /// `UndoAction` closure.
    func encodedSnapshotJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(snapshotJSON: String) {
        guard let data = snapshotJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(CalendarEvent.self, from: data) else { return nil }
        self = decoded
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

struct RecurrenceRule: Hashable {
    var frequency: RecurrenceFrequency
    var interval: Int
    var weekdays: Set<Weekday>
    /// Explicit days of the month (1-31, clamped to the month's actual length). Empty unless
    /// the user picks specific dates in the custom recurrence editor (BC-REC-011).
    var daysOfMonth: [Int] = []
    /// Positional rule ("last Friday of the month" = `[-1]` combined with `weekdays = [.friday]`;
    /// "2nd Tuesday" = `[2]`). Empty unless the user picks a positional rule (BC-REC-011).
    var setPositions: [Int] = []
    var end: RecurrenceEnd

    var summary: String {
        guard frequency != .never else { return "Never" }

        let cadence = interval == 1 ? frequency.label : "Every \(interval) \(frequency.pluralLabel)"
        let dayText = summaryDayText
        return cadence + dayText + end.label
    }

    private var summaryDayText: String {
        if !setPositions.isEmpty, !weekdays.isEmpty {
            let positions = setPositions.map(\.ordinalLabel).joined(separator: ", ")
            let days = weekdays.sorted().map(\.shortLabel).joined(separator: ", ")
            return " on the \(positions) \(days)"
        }

        if !daysOfMonth.isEmpty {
            let days = daysOfMonth.sorted().map { $0.ordinalLabel }.joined(separator: ", ")
            return " on the \(days)"
        }

        return weekdays.isEmpty ? "" : " on " + weekdays.sorted().map(\.shortLabel).joined(separator: ", ")
    }

    nonisolated static let never = RecurrenceRule(frequency: .never, interval: 1, weekdays: [], end: .never)
}

extension RecurrenceRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case frequency, interval, weekdays, daysOfMonth, setPositions, end
    }

    /// Decodes tolerantly so recurrence rules written before `daysOfMonth`/`setPositions`
    /// existed still load, defaulting both to empty (matches previous behavior exactly).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(RecurrenceFrequency.self, forKey: .frequency)
        interval = try container.decode(Int.self, forKey: .interval)
        weekdays = try container.decode(Set<Weekday>.self, forKey: .weekdays)
        daysOfMonth = try container.decodeIfPresent([Int].self, forKey: .daysOfMonth) ?? []
        setPositions = try container.decodeIfPresent([Int].self, forKey: .setPositions) ?? []
        end = try container.decode(RecurrenceEnd.self, forKey: .end)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(interval, forKey: .interval)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encode(daysOfMonth, forKey: .daysOfMonth)
        try container.encode(setPositions, forKey: .setPositions)
        try container.encode(end, forKey: .end)
    }
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

    /// Monday through Friday — the "Every Weekday" recurrence preset (spec 1.11).
    static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
}

extension Int {
    /// "1st"/"2nd"/"3rd"/"4th"/"last" for set-position values (`-1` means "last", following the
    /// RFC 5545 `BYSETPOS` convention) and "1st".."31st" for explicit days-of-month.
    var ordinalLabel: String {
        if self == -1 { return "last" }

        let suffix: String
        switch (self % 100, self % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(self)\(suffix)"
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

/// A single recurring occurrence that no longer follows its master's rule unmodified
/// (BC-REC-010, spec 0.10/1.11): either cancelled ("This Event" delete) or modified, in which
/// case `replacementEventID` points to a standalone `CalendarEvent` carrying the edits.
///
/// Exactly one of `originalOccurrenceStart` (timed/floating) or `originalOccurrenceLocalDate`
/// (all-day) is set, mirroring how `CalendarEvent` itself splits instant vs. local-date storage.
struct RecurrenceException: Identifiable, Codable, Hashable {
    var id: UUID
    var masterEventID: UUID
    var originalOccurrenceStart: Date?
    var originalOccurrenceLocalDate: String?
    var exceptionType: RecurrenceExceptionType
    var replacementEventID: UUID?
}

enum RecurrenceExceptionType: String, Codable, Hashable {
    case modified
    case cancelled
}

struct DeletedEventTombstone: Identifiable, Codable, Hashable {
    var id: UUID
    var eventID: UUID
    var title: String
    var deletedAt: Date
    /// Full JSON snapshot of the deleted event, enough to reconstruct it (spec 0.12). Optional
    /// so tombstones written before this field existed still decode.
    var eventSnapshotJSON: String?
    var deletionSyncedAt: Date?
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
    /// Carried through unchanged from the seed/existing event so `saveEvent(from:)` can tell a
    /// "This Event" occurrence edit apart from an ordinary event edit (BC-REC-010).
    var recurrenceMasterID: UUID?
    var recurrenceOriginalStart: Date?

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
        recurrenceMasterID = event.recurrenceMasterID
        recurrenceOriginalStart = event.recurrenceOriginalStart
    }

    /// - Parameter roundingMinutes: rounds `startDate` up to the next boundary of this many
    ///   minutes. Spec 1.4 calls for "the next sensible time boundary, such as the next
    ///   30-minute mark" — the default matches that; callers with a configured snap interval
    ///   (BC-SET-001) should pass `store.settings.snapIntervalMinutes` instead.
    init(calendarID: UUID, startDate: Date = .now, duration: TimeInterval = 60 * 60, roundingMinutes: Int = 30) {
        let roundedStart = Self.roundedUp(startDate, toNearestMinutes: roundingMinutes)
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
        recurrenceMasterID = nil
        recurrenceOriginalStart = nil
    }

    private static func roundedUp(_ date: Date, toNearestMinutes minutes: Int, calendar: Calendar = .current) -> Date {
        guard minutes > 0 else { return date }

        let referenceDate = calendar.startOfDay(for: date)
        let intervalSeconds = TimeInterval(minutes * 60)
        let secondsSinceReference = date.timeIntervalSince(referenceDate)
        let roundedSeconds = (secondsSinceReference / intervalSeconds).rounded(.up) * intervalSeconds
        return referenceDate.addingTimeInterval(roundedSeconds)
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
