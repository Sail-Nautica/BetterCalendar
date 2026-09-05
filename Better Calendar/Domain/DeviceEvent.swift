import Foundation

/// Spec 3C.2: what EventKit reports about an *event*, in Better Calendar's own value types —
/// the counterpart of `DeviceCalendar`, and subject to the same rule.
///
/// Nothing in this file imports EventKit. `EventKitDeviceStore` translates `EKEvent` into these
/// and stops; the mapping, the recurrence translation and the mirror pass that consume them are
/// pure, and therefore run in CI with no device, no account and no event store (BC-EK-024).

/// One device event, as the adapter hands it over.
///
/// ### What the adapter has already resolved
///
/// A windowed EventKit fetch returns one `EKEvent` **per occurrence**, every occurrence of a
/// series sharing that series' `eventIdentifier`. Mirroring those directly would write one row
/// per occurrence and lose the rule — precisely what spec 3C.1 forbids, since the local engine
/// stores a master plus exceptions and expands through `RecurrenceExpander`.
///
/// So the adapter collapses them before this type is reached: a series intersecting the window
/// arrives as **one** `DeviceEvent` for the master (carrying the series' own start date and its
/// recurrence rules) plus **one per detached occurrence** in the window. That work needs
/// `EKEventStore`, so it belongs on the EventKit side of the seam; everything after it is pure.
struct DeviceEvent: Hashable, Identifiable {
    /// `EKEvent.eventIdentifier`. Shared by every occurrence and detachment of one series, which
    /// is why it is not identity on its own — see `DeviceEventKey`.
    var identifier: String
    /// `EKEvent.calendarItemExternalIdentifier`: what recognises the same event on another
    /// device or after a restore. Also shared across a series' detachments.
    var externalIdentifier: String?
    /// `EKCalendar.calendarIdentifier`. Resolved to a local `calendarID` through the mirrored
    /// `BetterCalendar`; an event whose calendar is not mirrored is skipped, never orphaned.
    var calendarIdentifier: String
    /// Empty titles are legal and routine in EventKit. Stored as-is; `displayTitle` supplies
    /// "(No title)" at every rendering surface (spec 3.12).
    var title: String
    var notes: String?
    var location: String?
    var urlString: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    /// `nil` means the device event has **no** time zone, which is a floating event — not an
    /// event pinned to whatever zone the device happens to be in right now (spec 3C.4).
    var timeZoneIdentifier: String?
    var availability: DeviceEventAvailability
    var status: DeviceEventStatus
    /// Display state only. The system delivers these alerts for a device calendar, so
    /// `LocalNotificationPlanner` schedules nothing for a mirrored event (spec 3C.7).
    var alarms: [DeviceEventAlarm]
    /// EventKit permits more than one rule per event. Better Calendar models one — see
    /// `DeviceRecurrenceTranslation`.
    var recurrenceRules: [DeviceRecurrenceRule]
    var attendees: [DeviceEventAttendee]
    /// `EKEvent.lastModifiedDate`. The change detector in 3C; the optimistic-concurrency check
    /// in 3D (spec 3.22).
    var lastModified: Date?
    /// `EKEvent.isDetached`: this event is one occurrence that was edited away from its series.
    var isDetached: Bool
    /// `EKEvent.occurrenceDate` — the slot in the master's expansion this detachment came from,
    /// which is the half of its identity `identifier` cannot supply.
    var occurrenceDate: Date?
    /// Spec 3.17 (BC-EK-017): everything Better Calendar does not model — structured location,
    /// conference and video-call data, geolocation, per-account custom properties — captured so
    /// a local edit cannot silently strip it. A dictionary rather than pre-serialised JSON so
    /// the mapper controls key order and the payload stays byte-stable between passes.
    var rawFields: [String: String]

    var id: String { identifier }

    init(
        identifier: String,
        externalIdentifier: String? = nil,
        calendarIdentifier: String,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        urlString: String? = nil,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        availability: DeviceEventAvailability = .busy,
        status: DeviceEventStatus = .confirmed,
        alarms: [DeviceEventAlarm] = [],
        recurrenceRules: [DeviceRecurrenceRule] = [],
        attendees: [DeviceEventAttendee] = [],
        lastModified: Date? = nil,
        isDetached: Bool = false,
        occurrenceDate: Date? = nil,
        rawFields: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.notes = notes
        self.location = location
        self.urlString = urlString
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.availability = availability
        self.status = status
        self.alarms = alarms
        self.recurrenceRules = recurrenceRules
        self.attendees = attendees
        self.lastModified = lastModified
        self.isDetached = isDetached
        self.occurrenceDate = occurrenceDate
        self.rawFields = rawFields
    }

    /// Spec 3C.1: identity is the provider's. `identifier` alone for an ordinary event or a
    /// series master; the pair `(identifier, occurrenceDate)` for a detachment, because every
    /// detachment of one series shares the identifier.
    var key: DeviceEventKey {
        DeviceEventKey(identifier: identifier, occurrenceDate: isDetached ? occurrenceDate : nil)
    }

    /// A master is a device event that carries a repeat rule and is not itself a detachment.
    var isSeriesMaster: Bool {
        !recurrenceRules.isEmpty && !isDetached
    }
}

/// The `OccurrenceKey`-shaped identity spec 3C.1 requires: neither EventKit identifier is unique
/// on its own for anything detached, so identity for a detachment is the pair.
struct DeviceEventKey: Hashable {
    var identifier: String
    /// `nil` for an ordinary event or a series master.
    var occurrenceDate: Date?
}

/// EventKit's four availability values, before they are mapped **down** onto Better Calendar's
/// two (spec 3.12). Kept whole on this side of the seam so the mapping is a visible, tested step
/// rather than something the adapter did silently.
enum DeviceEventAvailability: String, Hashable, CaseIterable {
    case busy
    case free
    case tentative
    case unavailable
    /// `EKEventAvailabilityNotSupported` — the calendar does not model availability at all.
    case notSupported
}

/// `EKEventStatus`.
enum DeviceEventStatus: String, Hashable, CaseIterable {
    case none
    case confirmed
    case tentative
    case cancelled
}

/// One `EKAlarm`, reduced to the relative offset Better Calendar models. An alarm this app
/// cannot express — an absolute date, a location trigger — has no offset and is dropped from
/// `reminders` rather than approximated; the raw payload still preserves the fact of it.
struct DeviceEventAlarm: Hashable {
    /// Seconds relative to the event's start. Negative means before, which is EventKit's own
    /// convention and matches `ReminderOffset.notificationOffsetSeconds`.
    var relativeOffset: TimeInterval

    init(relativeOffset: TimeInterval) {
        self.relativeOffset = relativeOffset
    }
}

/// One `EKParticipant`, plus the organizer flag EventKit exposes separately.
///
/// Read-only, always: EventKit offers no API to add an attendee, so Better Calendar never
/// presents an "add guest" affordance in Phase 3 (invitations are Phase 11).
struct DeviceEventAttendee: Hashable {
    var name: String?
    var email: String?
    var participationStatus: DeviceEventParticipationStatus
    var role: DeviceEventAttendeeRole
    var isOrganizer: Bool
    var isCurrentUser: Bool

    init(
        name: String? = nil,
        email: String? = nil,
        participationStatus: DeviceEventParticipationStatus = .unknown,
        role: DeviceEventAttendeeRole = .unknown,
        isOrganizer: Bool = false,
        isCurrentUser: Bool = false
    ) {
        self.name = name
        self.email = email
        self.participationStatus = participationStatus
        self.role = role
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }
}

/// `EKParticipantStatus`, narrowed to the answers Better Calendar renders. EventKit's
/// `.completed` and `.inProcess` are reminder-only states and map to `.unknown` here.
enum DeviceEventParticipationStatus: String, Hashable, CaseIterable {
    case unknown
    case pending
    case accepted
    case declined
    case tentative
    case delegated
}

/// `EKParticipantRole`.
enum DeviceEventAttendeeRole: String, Hashable, CaseIterable {
    case unknown
    case required
    case optional
    case chair
    case nonParticipant
}

// MARK: - Recurrence

/// One `EKRecurrenceRule`, whole. Every field EventKit can populate is carried across the seam
/// even where Better Calendar cannot express it, because the *decision* about what is
/// expressible is spec 3C.3's and belongs in a tested pure function, not in the adapter.
struct DeviceRecurrenceRule: Hashable {
    var frequency: DeviceRecurrenceFrequency
    var interval: Int
    var daysOfTheWeek: [DeviceRecurrenceDayOfWeek]
    var daysOfTheMonth: [Int]
    var monthsOfTheYear: [Int]
    var weeksOfTheYear: [Int]
    var daysOfTheYear: [Int]
    var setPositions: [Int]
    var end: DeviceRecurrenceEnd

    init(
        frequency: DeviceRecurrenceFrequency,
        interval: Int = 1,
        daysOfTheWeek: [DeviceRecurrenceDayOfWeek] = [],
        daysOfTheMonth: [Int] = [],
        monthsOfTheYear: [Int] = [],
        weeksOfTheYear: [Int] = [],
        daysOfTheYear: [Int] = [],
        setPositions: [Int] = [],
        end: DeviceRecurrenceEnd = .never
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfTheWeek = daysOfTheWeek
        self.daysOfTheMonth = daysOfTheMonth
        self.monthsOfTheYear = monthsOfTheYear
        self.weeksOfTheYear = weeksOfTheYear
        self.daysOfTheYear = daysOfTheYear
        self.setPositions = setPositions
        self.end = end
    }
}

enum DeviceRecurrenceFrequency: String, Hashable, CaseIterable {
    case daily
    case weekly
    case monthly
    case yearly
}

/// `EKRecurrenceDayOfWeek`. `weekNumber == 0` means "every such weekday"; a non-zero value is
/// the ordinal EventKit uses for "the 2nd Tuesday" (`2`) or "the last Friday" (`-1`).
struct DeviceRecurrenceDayOfWeek: Hashable {
    var weekday: Weekday
    var weekNumber: Int

    init(_ weekday: Weekday, weekNumber: Int = 0) {
        self.weekday = weekday
        self.weekNumber = weekNumber
    }
}

/// `EKRecurrenceEnd`, plus the "runs forever" case EventKit models as a nil end.
enum DeviceRecurrenceEnd: Hashable {
    case never
    case occurrenceCount(Int)
    case endDate(Date)
}

/// Spec 3E.3: what a calendar's mirror has actually been reconciled over.
///
/// The reason this is *state* rather than a computation is the whole of 3E.3. Phase 3C's window
/// was a fixed span around now, and its deletion rule — a row is deleted only when its own start
/// lies inside the range that was fetched — was safe because that window never moved. A window
/// driven by what the user is looking at moves constantly: scroll to next March, fetch a window
/// around next March, and every mirrored event in this month is suddenly "absent from the fetch".
///
/// Recording the range makes that legible. It does **not** widen the permission to delete: that
/// stays pinned to the range a given pass actually asked for. What it buys is knowing whether a
/// range has ever been covered, so the next pass can fetch the union of what is newly visible and
/// what has not been seen.
struct CalendarReconciliationState: Equatable, Identifiable {
    var calendarID: UUID
    /// `nil` until the calendar's first pass.
    var windowStart: Date?
    var windowEnd: Date?
    var lastReconciledAt: Date?

    var id: UUID { calendarID }

    init(calendarID: UUID, windowStart: Date? = nil, windowEnd: Date? = nil, lastReconciledAt: Date? = nil) {
        self.calendarID = calendarID
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.lastReconciledAt = lastReconciledAt
    }

    var window: DateInterval? {
        guard let windowStart, let windowEnd, windowStart <= windowEnd else { return nil }
        return DateInterval(start: windowStart, end: windowEnd)
    }

    /// The stored window grown to include `newWindow`.
    ///
    /// A union rather than a replacement: a calendar reconciled over March and then over
    /// September has been reconciled over both, and forgetting the first would mean the next
    /// widening pass re-fetches a range it already holds.
    func unioned(with newWindow: DateInterval, at date: Date) -> CalendarReconciliationState {
        guard let existing = window else {
            return CalendarReconciliationState(calendarID: calendarID, windowStart: newWindow.start, windowEnd: newWindow.end, lastReconciledAt: date)
        }
        return CalendarReconciliationState(
            calendarID: calendarID,
            windowStart: min(existing.start, newWindow.start),
            windowEnd: max(existing.end, newWindow.end),
            lastReconciledAt: date
        )
    }

    /// Whether `range` is already inside what this calendar has been reconciled over — the
    /// question the visible-range trigger asks before deciding a pass is needed at all.
    func covers(_ range: DateInterval) -> Bool {
        guard let window else { return false }
        return window.start <= range.start && window.end >= range.end
    }
}
