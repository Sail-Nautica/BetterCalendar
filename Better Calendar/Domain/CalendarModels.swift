import Foundation

struct LocalCalendarDatabase: Equatable {
    var schemaVersion: Int
    var calendars: [BetterCalendar]
    var events: [CalendarEvent]
    var pendingMutations: [PendingMutation]
    var deletedEventTombstones: [DeletedEventTombstone]
    var settings: AppSettings = .defaultSettings
    var recurrenceExceptions: [RecurrenceException] = []

    /// The version of *this snapshot format* — the JSON envelope `JSONCalendarRepository`
    /// writes and `LocalCalendarDatabase.init(from:)` decodes tolerantly.
    ///
    /// This is deliberately **not** the SQLite schema version. The two numbers count
    /// different things and have drifted apart by design: the relational schema is versioned
    /// by `SQLiteCalendarRepository.migrationIdentifiers`, whose count (16 as of Phase 2 M1)
    /// is what gets stamped into the `schema_metadata` table and checksummed per spec 2.17.
    /// The snapshot format is versioned here, and has needed no incompatible change since
    /// Phase 0 because every field added since has been decoded with `decodeIfPresent`.
    ///
    /// `SQLiteCalendarRepository.load()` stamps this value onto the databases it returns for
    /// exactly that reason: it is describing the in-memory value it just built, not the
    /// migration state of the file it read.
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
    /// Spec 2.14: local optimistic-concurrency counter, mirroring `CalendarEvent.versionNumber`.
    var versionNumber: Int = 1

    // MARK: - Provider identity (spec 3.6)
    //
    // Every field below is appended after `versionNumber` and defaulted, so the memberwise
    // initializer keeps working unchanged at all four existing construction sites. The
    // `calendars` table has carried `provider`, `provider_account_id`, `provider_calendar_id`,
    // `is_read_only`, and `time_zone_id` since `v001` — `SQLiteCalendarRepository` simply
    // hardcoded them. These are what let it stop.

    /// Who owns the data (spec 0.6's ownership model). Orthogonal to `connectionMethod`: a
    /// Google calendar is `.google` whether we reach it through the device or, from Phase 5,
    /// through the Google API directly. See ADR 0004.
    var provider: EventProvider = .betterCalendar
    /// How Better Calendar reaches this calendar. See ADR 0004.
    var connectionMethod: ConnectionMethod = .local
    /// `EKSource` identifier, once a device calendar is mirrored.
    var providerAccountID: String?
    /// `EKCalendar.calendarIdentifier`. For a local calendar this stays the local `id`, matching
    /// what the repository has always written.
    var providerCalendarID: String?
    /// `EKSource.title` ("iCloud", "Gmail", …), for the attribution required by BC-EK-018.
    var accountName: String?
    /// Set only when the calendar's color is not one of the six design tokens — device calendars
    /// carry arbitrary RGB. `nil` means "render `colorName`." See ADR 0004.
    var colorHex: String?
    /// Spec 3.10: enforced at the model layer by `EventMutationUseCases`, not merely in the UI.
    var isReadOnly: Bool = false
    var timeZoneIdentifier: String?
    var capabilities: CalendarCapabilities = .localDefaults

    // MARK: - Availability (spec 3B.4)

    /// Spec 3.8: a calendar that disappears from EventKit — account removed, calendar deleted
    /// elsewhere — is *marked* rather than purged, so its local-only state (`isVisible`,
    /// `isDefault`, `sortOrder`) is still there to restore if it comes back.
    var isUnavailable: Bool = false
    /// When the mirror last failed to find it. Unused in Phase 3B: spec 3.26 requires a
    /// retention limit for hidden mirror rows, and that limit is a Phase 3E decision with an ADR
    /// of its own. The column exists now so 3E writes a policy rather than a migration.
    var unavailableSince: Date?

    /// The single question every mutation path actually asks. Read-only is the coarse switch the
    /// user sees; `capabilities` is the fine-grained truth a provider reports.
    var allowsEventEditing: Bool {
        !isReadOnly && capabilities.allowsContentModifications
    }

    var allowsEventCreation: Bool {
        !isReadOnly && capabilities.allowsEventCreation
    }

    /// Spec 3B.5: a calendar the user may be *offered* as a destination — writable, and actually
    /// present on the device. Distinct from `allowsEventCreation`, which asks only what the
    /// calendar permits: an available read-only calendar and an unavailable writable one are
    /// both unusable destinations, for different reasons and with different copy.
    var isWritableDestination: Bool {
        !isUnavailable && allowsEventCreation
    }

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
        case id, name, colorName, isVisible, isDefault, sortOrder, createdAt, updatedAt, versionNumber
        case provider, connectionMethod, providerAccountID, providerCalendarID, accountName
        case colorHex, isReadOnly, timeZoneIdentifier, capabilities
        case isUnavailable, unavailableSince
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
        versionNumber = try container.decodeIfPresent(Int.self, forKey: .versionNumber) ?? 1
        // Spec 3.6: a calendar written before provider identity existed decodes as exactly what
        // it was — a local, writable, Better Calendar-owned calendar. Same tolerance the
        // `sortOrder` and `versionNumber` additions above already established.
        provider = try container.decodeIfPresent(EventProvider.self, forKey: .provider) ?? .betterCalendar
        connectionMethod = try container.decodeIfPresent(ConnectionMethod.self, forKey: .connectionMethod) ?? .local
        providerAccountID = try container.decodeIfPresent(String.self, forKey: .providerAccountID)
        providerCalendarID = try container.decodeIfPresent(String.self, forKey: .providerCalendarID)
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        capabilities = try container.decodeIfPresent(CalendarCapabilities.self, forKey: .capabilities) ?? .localDefaults
        // Spec 3B.4: a calendar written before availability existed decodes as available, which
        // is what it was — the same tolerance every field above already establishes.
        isUnavailable = try container.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
        unavailableSince = try container.decodeIfPresent(Date.self, forKey: .unavailableSince)
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
        try container.encode(versionNumber, forKey: .versionNumber)
        try container.encode(provider, forKey: .provider)
        try container.encode(connectionMethod, forKey: .connectionMethod)
        try container.encodeIfPresent(providerAccountID, forKey: .providerAccountID)
        try container.encodeIfPresent(providerCalendarID, forKey: .providerCalendarID)
        try container.encodeIfPresent(accountName, forKey: .accountName)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(isUnavailable, forKey: .isUnavailable)
        try container.encodeIfPresent(unavailableSince, forKey: .unavailableSince)
    }
}

/// Spec 3.7: how Better Calendar reaches a calendar, kept deliberately orthogonal to
/// `EventProvider` (who owns the data). Conflating the two is what produces the duplicate
/// connection the roadmap warns about — the same Google account reached through the device and
/// through the Google API is one provider and two connection methods, not two providers.
/// See ADR 0004.
enum ConnectionMethod: String, Codable, Hashable, CaseIterable, Identifiable {
    /// A Better Calendar-owned calendar; no provider round trip.
    case local
    /// Reached through EventKit (Phase 3).
    case device
    /// Reached through a provider API. Defined here so Phase 5 inherits the column rather than
    /// migrating it, exactly as Phase 0 reserved `ProviderMetadata` before any provider existed.
    /// Nothing in Phase 3 ever produces this value.
    case direct

    var id: String { rawValue }
}

/// Spec 3.10: what a calendar actually permits, as its provider reports it. Distinct from
/// `isReadOnly`, which is the single coarse flag the UI shows: a calendar can be writable in
/// general yet refuse a specific availability value, and Phase 3's EventKit adapter will report
/// exactly that.
///
/// Defaults are the permissive local-calendar answers, so every pre-Phase-3 calendar — and every
/// calendar the user creates in this app — behaves precisely as it did before this type existed.
struct CalendarCapabilities: Codable, Hashable {
    var allowsContentModifications: Bool
    var allowsEventCreation: Bool
    var allowedAvailabilities: [EventAvailability]
    var supportsRecurrence: Bool
    var supportsReminders: Bool
    var isSubscribed: Bool
    var isImmutable: Bool

    static let localDefaults = CalendarCapabilities(
        allowsContentModifications: true,
        allowsEventCreation: true,
        allowedAvailabilities: EventAvailability.allCases,
        supportsRecurrence: true,
        supportsReminders: true,
        isSubscribed: false,
        isImmutable: false
    )

    /// The capability set for a calendar Better Calendar may read but never write — a subscribed
    /// feed, a birthday calendar, or a shared calendar the user only has read access to.
    static let readOnly = CalendarCapabilities(
        allowsContentModifications: false,
        allowsEventCreation: false,
        allowedAvailabilities: EventAvailability.allCases,
        supportsRecurrence: true,
        supportsReminders: false,
        isSubscribed: false,
        isImmutable: true
    )

    /// Decodes tolerantly for the same reason `BetterCalendar` does — a capabilities blob written
    /// by an older build, or by a provider that reported fewer fields, still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalendarCapabilities.localDefaults
        allowsContentModifications = try container.decodeIfPresent(Bool.self, forKey: .allowsContentModifications) ?? defaults.allowsContentModifications
        allowsEventCreation = try container.decodeIfPresent(Bool.self, forKey: .allowsEventCreation) ?? defaults.allowsEventCreation
        allowedAvailabilities = try container.decodeIfPresent([EventAvailability].self, forKey: .allowedAvailabilities) ?? defaults.allowedAvailabilities
        supportsRecurrence = try container.decodeIfPresent(Bool.self, forKey: .supportsRecurrence) ?? defaults.supportsRecurrence
        supportsReminders = try container.decodeIfPresent(Bool.self, forKey: .supportsReminders) ?? defaults.supportsReminders
        isSubscribed = try container.decodeIfPresent(Bool.self, forKey: .isSubscribed) ?? defaults.isSubscribed
        isImmutable = try container.decodeIfPresent(Bool.self, forKey: .isImmutable) ?? defaults.isImmutable
    }

    init(
        allowsContentModifications: Bool,
        allowsEventCreation: Bool,
        allowedAvailabilities: [EventAvailability],
        supportsRecurrence: Bool,
        supportsReminders: Bool,
        isSubscribed: Bool,
        isImmutable: Bool
    ) {
        self.allowsContentModifications = allowsContentModifications
        self.allowsEventCreation = allowsEventCreation
        self.allowedAvailabilities = allowedAvailabilities
        self.supportsRecurrence = supportsRecurrence
        self.supportsReminders = supportsReminders
        self.isSubscribed = isSubscribed
        self.isImmutable = isImmutable
    }
}

/// Spec 3.10: why a mutation was refused before it was ever written locally. Carries the
/// calendar's name because the only useful thing to tell the user is *which* calendar said no —
/// on a device with several accounts, the identifier alone explains nothing.
struct CapabilityViolation: Equatable, Hashable {
    var calendarID: UUID
    var calendarName: String
    var reason: Reason

    enum Reason: String, Equatable, Hashable {
        /// The calendar does not permit modifying existing events.
        case readOnly
        /// The calendar does not permit adding new events.
        case creationNotAllowed
        /// Spec 3B.4: the calendar is mirrored but no longer present on the device — the
        /// account was removed, or the calendar was deleted elsewhere. Distinct from `readOnly`
        /// because the calendar has not refused anything; it is simply not there to write to.
        case unavailable
    }

    /// User-facing copy, per the UI/UX §9.2 rule that an error says what happened and why.
    var message: String {
        switch reason {
        case .readOnly:
            "\"\(calendarName)\" is read-only, so this event can't be changed here."
        case .creationNotAllowed:
            "\"\(calendarName)\" doesn't allow new events."
        case .unavailable:
            "\"\(calendarName)\" isn't available on this device right now, so this event can't be saved to it."
        }
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
    /// Spec 3.3 (BC-EK-001): whether `SRC-PERM-01` has been shown. The one piece of the device-
    /// calendar permission flow Better Calendar owns and therefore persists — the authorization
    /// status itself is the device's answer, read live and never stored (spec 3.4).
    var hasSeenCalendarAccessPrimer: Bool

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
        secondaryTimeZoneIdentifier: nil,
        hasSeenCalendarAccessPrimer: false
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
/// The design tokens' own hex values (UI/UX §6.2), in the domain rather than in the repository
/// that used to own them privately.
///
/// Spec 3B.3 is why they moved: `SQLiteCalendarRepository` normalises a stored hex that matches
/// a token back into that token with `colorHex == nil`, and the discovery planner has to apply
/// exactly the same normalisation. If it did not, a device calendar whose colour happened to
/// equal a token would compare unequal to its own stored row on every pass, and discovery would
/// rewrite it forever.
extension CalendarColorName {
    var hexValue: String {
        switch self {
        case .betterBlue: "#4F7DFF"
        case .success: "#2EA86B"
        case .warning: "#E68A2E"
        case .destructive: "#D94D4D"
        case .navy: "#17243D"
        case .gray: "#5C6678"
        }
    }

    init?(hexValue: String) {
        guard let match = CalendarColorName.allCases.first(where: { $0.hexValue == hexValue.uppercased() }) else {
            return nil
        }
        self = match
    }
}

enum EventTimeType: String, Codable, CaseIterable, Identifiable, Hashable {
    case timed
    case allDay
    case floating

    var id: String { rawValue }
}

enum EventAvailability: String, Codable, CaseIterable, Identifiable {
    case busy
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .busy: "Busy"
        case .free: "Free"
        }
    }
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
    /// BC-EVT-020, spec 1.5/1.10. The `events.availability` SQLite column already existed
    /// (hardcoded to `'busy'` on every write) — this is the first domain-level exposure of it.
    var availability: EventAvailability = .busy
    /// Set only on a standalone replacement event created for a single recurring occurrence
    /// (BC-REC-010, "This Event" edit scope, spec 1.11) — the master series' id.
    var recurrenceMasterID: UUID?
    /// Paired with `recurrenceMasterID`: the occurrence's original start, used both to find an
    /// existing replacement when re-editing the same occurrence and to match the
    /// `RecurrenceException` that hides the master's slot at that date.
    var recurrenceOriginalStart: Date?
    /// Spec 2.14: local optimistic-concurrency counter, independent of `providerVersion`. Every
    /// existing construction site gets `1` ("never edited") for free via the default; the
    /// mutation use cases in `Data/Engine/EventMutationUseCases.swift` are the only code that
    /// ever passes a different value.
    var versionNumber: Int = 1

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

    /// Spec 3.12. Phase 1's editor requires a title, so nothing this app creates is ever
    /// untitled — but an empty `SUMMARY` is legal in RFC 5545 and routine in EventKit, so both
    /// ICS import and the Phase 3 mirror can produce one. Every surface that renders a title
    /// goes through this rather than `title` directly, so an untitled event reads as an event
    /// rather than as a rendering bug.
    ///
    /// Deliberately not applied to `EventDraft`/the editor field, where an empty title must stay
    /// empty so the placeholder does not become real text the user has to delete.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.untitledPlaceholder : trimmed
    }

    static let untitledPlaceholder = "(No title)"
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, calendarID, title, startDate, endDate, timeType, isAllDay
        case timeZoneIdentifier, location, urlString, notes, reminders
        case recurrence, providerMetadata, createdAt, updatedAt
        case recurrenceMasterID, recurrenceOriginalStart
        case availability
        case versionNumber
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
        availability = try container.decodeIfPresent(EventAvailability.self, forKey: .availability) ?? .busy
        versionNumber = try container.decodeIfPresent(Int.self, forKey: .versionNumber) ?? 1

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
        try container.encode(availability, forKey: .availability)
        try container.encode(versionNumber, forKey: .versionNumber)
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
    /// BC-ICS-001, spec 1.18: unrecognized/original ICS properties from import, preserved so a
    /// later export is non-destructive. Best-effort reconstruction of the source properties,
    /// not a byte-exact copy of the original file.
    var rawICSProperties: String?

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
    /// iCloud, and Apple-provided calendars such as Birthdays.
    case apple = "Apple"
    case university = "U-M"
    // MARK: - Spec 3B.2
    //
    // The values spec 3.6's "…" left open. Without them an Exchange account or an "On My
    // iPhone" calendar has no honest answer to "who owns this data", and `provider` is the axis
    // Phase 3F's duplicate-connection rule matches on.
    case exchange = "Exchange"
    /// `EKSourceType.local` — the device's own calendar store. Deliberately *not*
    /// `betterCalendar`: this one is reached through EventKit and we do not own it, and
    /// collapsing the two would leave `connectionMethod` as the only thing telling a row we own
    /// from one we mirror.
    case deviceLocal = "On My Device"
    /// `EKSourceType.subscribed` — a read-only feed.
    case subscribed = "Subscribed"
    /// A CalDAV or other account we cannot attribute more precisely. The honest answer, and the
    /// safe one: see `DeviceCalendarSource.provider`.
    case otherAccount = "Other Account"

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

/// Spec 2.10's outbox row. `objectID`/`objectType`/`operation` are the Phase 0 fields every
/// call site already constructs; the rest are the Phase 2 additions layered on top.
struct PendingMutation: Identifiable, Hashable {
    var id: UUID
    var objectID: UUID
    var objectType: MutationObjectType
    var operation: MutationOperation
    var createdAt: Date
    /// JSON snapshot of the entity this mutation carries, for a future provider adapter to
    /// resend without re-reading the database. `nil` is a legal, common case in Phase 2: there
    /// is no provider yet to consume it.
    var payload: String?
    /// Spec 2.10/2.11: minted once when a mutation is first enqueued and never regenerated on
    /// retry — that stability is what makes "apply the same idempotency key twice" a no-op
    /// instead of a duplicate. Defaults to `id` so every existing construction site (which only
    /// ever calls this with one `id` per logical mutation) gets a key with the same stability
    /// property for free.
    var idempotencyKey: UUID
    var status: MutationStatus
    var attemptCount: Int
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    /// Spec 2.10: the journal entry this mutation was enqueued alongside. `nil` only for rows
    /// written before this column existed.
    var changeJournalEntryID: UUID?

    init(
        id: UUID,
        objectID: UUID,
        objectType: MutationObjectType,
        operation: MutationOperation,
        createdAt: Date,
        payload: String? = nil,
        idempotencyKey: UUID? = nil,
        status: MutationStatus = .pending,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextRetryAt: Date? = nil,
        changeJournalEntryID: UUID? = nil
    ) {
        self.id = id
        self.objectID = objectID
        self.objectType = objectType
        self.operation = operation
        self.createdAt = createdAt
        self.payload = payload
        self.idempotencyKey = idempotencyKey ?? id
        self.status = status
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.changeJournalEntryID = changeJournalEntryID
    }
}

extension PendingMutation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, objectID, objectType, operation, createdAt
        case payload, idempotencyKey, status, attemptCount, lastAttemptAt, nextRetryAt, changeJournalEntryID
    }

    /// Decodes tolerantly so mutations written before the Phase 2 columns existed still load —
    /// `idempotencyKey` falls back to `id`, matching what `init` does for a fresh value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        objectID = try container.decode(UUID.self, forKey: .objectID)
        objectType = try container.decode(MutationObjectType.self, forKey: .objectType)
        operation = try container.decode(MutationOperation.self, forKey: .operation)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        idempotencyKey = try container.decodeIfPresent(UUID.self, forKey: .idempotencyKey) ?? id
        status = try container.decodeIfPresent(MutationStatus.self, forKey: .status) ?? .pending
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        changeJournalEntryID = try container.decodeIfPresent(UUID.self, forKey: .changeJournalEntryID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(objectType, forKey: .objectType)
        try container.encode(operation, forKey: .operation)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(status, forKey: .status)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
        try container.encodeIfPresent(nextRetryAt, forKey: .nextRetryAt)
        try container.encodeIfPresent(changeJournalEntryID, forKey: .changeJournalEntryID)
    }
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

/// Spec 2.10's outbox status machine.
enum MutationStatus: String, Codable, Hashable, CaseIterable {
    case pending
    case inFlight
    case applied
    case failed
    case conflicted
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

/// Spec 2.13's generalized tombstone. Named `DeletedEventTombstone` through M1/M2 because only
/// events were ever tombstoned; M3 generalizes it to the full spec shape while keeping every
/// M1/M2 call site compiling unchanged — see the back-compat `eventID` accessor/initializer and
/// the `DeletedEventTombstone` typealias below.
struct DeletedObjectTombstone: Identifiable, Hashable {
    var id: UUID
    var entityType: EngineEntityType
    var entityID: UUID
    var title: String
    var deletedAt: Date
    /// Spec 2.13: why this object was deleted — what lets a later replay distinguish a
    /// mutation that *should* be suppressed (BC-ENG-006) from one that is merely late.
    var deletedBy: TombstoneCause
    /// Spec 2.13: the retention deadline, stored rather than computed on read so it agrees
    /// with `deleted_objects.purge_after` and can be indexed by a future purge job.
    var purgeAfter: Date
    /// Full JSON snapshot of the deleted event, enough to reconstruct it (spec 0.12). Optional
    /// so tombstones written before this field existed still decode.
    var eventSnapshotJSON: String?
    var deletionSyncedAt: Date?

    /// The spec 2.13 shape.
    init(
        id: UUID,
        entityType: EngineEntityType = .event,
        entityID: UUID,
        title: String,
        deletedAt: Date,
        deletedBy: TombstoneCause = .userEdit,
        purgeAfter: Date? = nil,
        eventSnapshotJSON: String? = nil,
        deletionSyncedAt: Date? = nil
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.title = title
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
        self.purgeAfter = purgeAfter ?? EngineRetentionPolicy.purgeDate(forTombstoneDeletedAt: deletedAt)
        self.eventSnapshotJSON = eventSnapshotJSON
        self.deletionSyncedAt = deletionSyncedAt
    }
}

extension DeletedObjectTombstone {
    /// The pre-M3 shape every M1/M2 call site uses: no `entityType`/`deletedBy`/`purgeAfter`,
    /// `eventID:` instead of `entityID:`. Declared in an extension so it doesn't suppress the
    /// designated initializer above.
    init(id: UUID, eventID: UUID, title: String, deletedAt: Date, eventSnapshotJSON: String?, deletionSyncedAt: Date?) {
        self.init(id: id, entityType: .event, entityID: eventID, title: title, deletedAt: deletedAt, eventSnapshotJSON: eventSnapshotJSON, deletionSyncedAt: deletionSyncedAt)
    }

    var eventID: UUID {
        get { entityID }
        set { entityID = newValue }
    }
}

extension DeletedObjectTombstone: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, entityType
        case entityID = "eventID"
        case title, deletedAt, deletedBy, purgeAfter, eventSnapshotJSON, deletionSyncedAt
    }

    /// Decodes tolerantly so tombstones written before `entityType`/`deletedBy`/`purgeAfter`
    /// existed still load, and keeps the JSON key `eventID` rather than renaming it to
    /// `entityID` — the persisted snapshot format survives the Swift-level rename.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        entityType = try container.decodeIfPresent(EngineEntityType.self, forKey: .entityType) ?? .event
        entityID = try container.decode(UUID.self, forKey: .entityID)
        title = try container.decode(String.self, forKey: .title)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        deletedBy = try container.decodeIfPresent(TombstoneCause.self, forKey: .deletedBy) ?? .userEdit
        purgeAfter = try container.decodeIfPresent(Date.self, forKey: .purgeAfter) ?? EngineRetentionPolicy.purgeDate(forTombstoneDeletedAt: deletedAt)
        eventSnapshotJSON = try container.decodeIfPresent(String.self, forKey: .eventSnapshotJSON)
        deletionSyncedAt = try container.decodeIfPresent(Date.self, forKey: .deletionSyncedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(title, forKey: .title)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(deletedBy, forKey: .deletedBy)
        try container.encode(purgeAfter, forKey: .purgeAfter)
        try container.encodeIfPresent(eventSnapshotJSON, forKey: .eventSnapshotJSON)
        try container.encodeIfPresent(deletionSyncedAt, forKey: .deletionSyncedAt)
    }
}

typealias DeletedEventTombstone = DeletedObjectTombstone

struct EventDraft: Equatable {
    var id: UUID?
    var calendarID: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    /// BC-TZ-001 (spec 1.17 "lock event to this time zone"): UI exposure of the `.floating`
    /// case BC-EVT-011 already modeled. Tracked as its own flag (not derived from `isAllDay`)
    /// so `EventDraft` can represent all three `EventTimeType` cases, not just two — without
    /// this, editing a floating event through the standard editor would silently collapse it
    /// to timed, since `CalendarEvent.isAllDay`'s getter reads `false` for `.floating` too.
    var isLockedToTimeZone: Bool
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
        isLockedToTimeZone = event.isFloating
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
        isLockedToTimeZone = false
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
