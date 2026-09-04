import CryptoKit
import Foundation

/// Spec 3.12/3C.2: the device event → `CalendarEvent` mapping, as a pure function.
///
/// No EventKit import, no clock it does not own, no `UUID()` it does not derive — so every rule
/// below is a deterministic unit test with no device (BC-EK-024), and running the mirror twice
/// over an unchanged device produces byte-identical rows, which is what makes spec 3C.8's
/// idempotence requirement structural rather than hopeful.
enum DeviceEventMapper {

    /// Everything the mapper needs about the surroundings of one event, so none of it is read
    /// from ambient state inside a pure function.
    struct Context {
        /// The mirrored `BetterCalendar` this event belongs to.
        var calendarID: UUID
        /// That calendar's provider, for `providerMetadata.provider`. The event carries no
        /// account or calendar identifier of its own (spec 3C.1) — its calendar already holds
        /// both, and duplicating them would create two places for one fact to live.
        var provider: EventProvider
        /// The zone the device's own dates were computed in.
        ///
        /// EventKit hands back instants, not wall-clock components. For an event that carries
        /// its own zone that is unambiguous, but an **all-day** or **floating** event's instant
        /// only means what it means when read back in the zone it was produced in — so that zone
        /// is what `CalendarEvent.timeZoneIdentifier` stores for those two, and
        /// `floatingAnchoredDate`/`LocalCalendarDate` decode through it.
        ///
        /// Passed in rather than read from `TimeZone.current` here so a test can pin it, and so
        /// spec 3C.4's "must not shift by a day when the device time zone changes" is a
        /// deterministic assertion instead of an observation about the machine running CI.
        var deviceTimeZoneIdentifier: String
        /// The local row id this device event already has, or a freshly derived one. Both come
        /// from `DeviceEventIdentity`, so this is stable across passes and across a database
        /// rebuild — spec 3C.1's "reconstructible" property.
        var localID: UUID
        /// Preserved from the existing row on an update; `now` for an insert.
        var createdAt: Date
    }

    // MARK: - Events

    static func map(_ device: DeviceEvent, in context: Context, now: Date) -> CalendarEvent {
        let timeZoneIdentifier = resolvedTimeZoneIdentifier(for: device, in: context)
        // Translated once and reused, so the `hasUnrepresentableRecurrence` flag and the raw
        // payload that preserves the rules can never disagree about whether this event's pattern
        // was expressible.
        let recurrence = DeviceRecurrenceTranslation.translate(
            device.recurrenceRules,
            eventStart: device.startDate,
            timeZoneIdentifier: timeZoneIdentifier
        )

        return CalendarEvent(
            id: context.localID,
            calendarID: context.calendarID,
            title: device.title,
            startDate: device.startDate,
            endDate: device.endDate,
            timeType: timeType(for: device),
            timeZoneIdentifier: timeZoneIdentifier,
            location: device.location,
            urlString: device.urlString,
            notes: device.notes,
            reminders: reminders(for: device, localID: context.localID),
            recurrence: recurrence.rule,
            providerMetadata: ProviderMetadata(
                provider: context.provider,
                providerAccountID: nil,
                providerCalendarID: nil,
                providerObjectID: device.identifier,
                providerVersion: device.lastModified.map(providerVersionString),
                syncStatus: .synced,
                deletedAt: nil,
                rawICSProperties: nil,
                providerExternalID: device.externalIdentifier,
                providerRawFields: rawFieldsJSON(for: device, recurrence: recurrence),
                status: status(for: device.status),
                hasUnrepresentableRecurrence: recurrence.isUnrepresentable
            ),
            attendees: attendees(for: device, localID: context.localID),
            createdAt: context.createdAt,
            updatedAt: now,
            availability: availability(for: device.availability),
            recurrenceMasterID: nil,
            recurrenceOriginalStart: nil
        )
    }

    /// The detachment half of spec 3C.3: a device occurrence edited away from its series becomes
    /// Phase 2's replacement event, pointing at the mirrored master by the same
    /// `(recurrenceMasterID, originalStart)` identity §2.3 established.
    static func mapDetachment(
        _ device: DeviceEvent,
        master: CalendarEvent,
        in context: Context,
        now: Date
    ) -> CalendarEvent {
        var replacement = map(device, in: context, now: now)
        replacement.recurrenceMasterID = master.id
        replacement.recurrenceOriginalStart = device.occurrenceDate ?? device.startDate
        // A detachment is one occurrence, never a series of its own. EventKit reports the
        // *series'* rules on a detached event, and carrying them over would expand the same
        // series twice — once from the master and once from every detachment.
        replacement.recurrence = nil
        return replacement
    }

    /// The `.modified` exception that hides the master's own slot at the detached occurrence, so
    /// the replacement is shown instead of, not alongside, the generated occurrence.
    static func makeException(master: CalendarEvent, detachment: CalendarEvent) -> RecurrenceException {
        let originalStart = detachment.recurrenceOriginalStart ?? detachment.startDate
        return RecurrenceException(
            id: DeviceEventIdentity.exceptionID(masterID: master.id, originalStart: originalStart),
            masterEventID: master.id,
            // `RecurrenceException.matches` reads one or the other depending on the *master's*
            // time type, so both are written from the master's own calendar rather than the
            // detachment's — an all-day series compares local dates, a timed one instants.
            originalOccurrenceStart: master.isAllDay ? nil : originalStart,
            originalOccurrenceLocalDate: master.isAllDay ? master.localDateString(for: originalStart) : nil,
            exceptionType: .modified,
            replacementEventID: detachment.id
        )
    }

    // MARK: - Field mapping (spec 3C.2)

    /// Spec 3C.4's three cases. All-day wins over a zone — an all-day event with a zone attached
    /// is still an all-day event, compared on local calendar-date components.
    static func timeType(for device: DeviceEvent) -> EventTimeType {
        if device.isAllDay { return .allDay }
        return device.timeZoneIdentifier == nil ? .floating : .timed
    }

    /// A timed event keeps the device's own zone. All-day and floating events have none to keep,
    /// so they store the device zone their instants were computed in — see `Context`.
    static func resolvedTimeZoneIdentifier(for device: DeviceEvent, in context: Context) -> String {
        guard !device.isAllDay, let identifier = device.timeZoneIdentifier else {
            return context.deviceTimeZoneIdentifier
        }
        return identifier
    }

    /// Spec 3.12: EventKit's four availability values map onto our two, **downward**, and none is
    /// dropped. Anything that is not explicitly "free" occupies the slot — a tentative or
    /// unavailable block is time the user cannot offer to someone else.
    ///
    /// Whether it *counts* as busy is a separate question, answered by `occupiesTime` from the
    /// event's status and the user's own participation (spec 3C.5), not by this value.
    static func availability(for availability: DeviceEventAvailability) -> EventAvailability {
        switch availability {
        case .free:
            .free
        case .busy, .tentative, .unavailable:
            .busy
        case .notSupported:
            // The calendar does not model availability at all, so it cannot be asserting the
            // event is free. `.busy` is the schema's own default and the safer of the two.
            .busy
        }
    }

    static func status(for status: DeviceEventStatus) -> EventStatus {
        switch status {
        case .none: .none
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .cancelled: .cancelled
        }
    }

    /// Spec 3C.7: alarms are mirrored so the detail view can show what the user will be alerted
    /// about, and `LocalNotificationPlanner` schedules none of them — the system owns delivery
    /// for a device calendar.
    ///
    /// An alarm Better Calendar cannot express as an offset from the start (an absolute date, a
    /// location trigger) is dropped rather than approximated into the wrong time; the fact of it
    /// still survives in the preserved raw payload.
    static func reminders(for device: DeviceEvent, localID: UUID) -> [EventReminder] {
        device.alarms.compactMap { alarm in
            guard let offset = reminderOffset(forRelativeOffset: alarm.relativeOffset) else { return nil }
            return EventReminder(
                id: DeviceEventIdentity.reminderID(eventID: localID, relativeOffset: alarm.relativeOffset),
                offset: offset
            )
        }
    }

    /// EventKit's relative offset is seconds before the start, expressed negatively. Whole days
    /// are preferred over minutes so a "1 day before" alarm reads as one rather than as
    /// "1440 minutes before".
    static func reminderOffset(forRelativeOffset relativeOffset: TimeInterval) -> ReminderOffset? {
        guard relativeOffset <= 0 else {
            // An alarm *after* the start has no `ReminderOffset` case. Rather than silently
            // firing it early, it is left out.
            return nil
        }
        let secondsBefore = Int((-relativeOffset).rounded())
        if secondsBefore == 0 { return .atStart }
        guard secondsBefore % 60 == 0 else { return nil }

        let minutesBefore = secondsBefore / 60
        if minutesBefore % (24 * 60) == 0 {
            return .daysBefore(minutesBefore / (24 * 60))
        }
        return .minutesBefore(minutesBefore)
    }

    /// Spec 3C.5. Ordered as the device reported them, with the organizer's flag folded in from
    /// EventKit's separate `organizer` property by the adapter before this point.
    static func attendees(for device: DeviceEvent, localID: UUID) -> [EventAttendee] {
        device.attendees.enumerated().map { index, attendee in
            EventAttendee(
                id: DeviceEventIdentity.attendeeID(eventID: localID, attendee: attendee, index: index),
                name: attendee.name,
                email: attendee.email,
                participationStatus: participationStatus(for: attendee.participationStatus),
                role: role(for: attendee.role),
                isOrganizer: attendee.isOrganizer,
                isCurrentUser: attendee.isCurrentUser,
                sortOrder: index
            )
        }
    }

    static func participationStatus(for status: DeviceEventParticipationStatus) -> EventParticipationStatus {
        switch status {
        case .unknown: .unknown
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .delegated: .delegated
        }
    }

    static func role(for role: DeviceEventAttendeeRole) -> EventAttendeeRole {
        switch role {
        case .unknown: .unknown
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        }
    }

    /// Spec 3.17/BC-EK-017: the payload that keeps a title-only edit from stripping the Google
    /// Meet link off a meeting. Serialised with sorted keys so two passes over an unchanged
    /// device produce the identical string and the row compares equal — an unstable encoding
    /// here would make every pass look like a change.
    ///
    /// Unrepresentable recurrence rules are folded in under their own key rather than kept
    /// somewhere separate: spec 3C.3 requires the raw rules be preserved, and this is the field
    /// spec 3.17 defines for "what we do not model".
    static func rawFieldsJSON(for device: DeviceEvent, recurrence: DeviceRecurrenceTranslation.Result) -> String? {
        var fields = device.rawFields
        if recurrence.isUnrepresentable {
            fields[unrepresentableRecurrenceRawKey] = describe(device.recurrenceRules)
        }

        guard !fields.isEmpty,
              JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The key spec 3C.3's raw rules are preserved under inside `providerRawFields`.
    static let unrepresentableRecurrenceRawKey = "recurrenceRules"

    /// A stable, human-readable rendering of rules the engine cannot express, so a support
    /// session or a Phase 3D write-back can see what the device actually said. Deliberately not
    /// a decodable format: nothing reads this back into a `RecurrenceRule`, because being unable
    /// to is the whole point.
    static func describe(_ rules: [DeviceRecurrenceRule]) -> String {
        rules.map(describe).joined(separator: "; ")
    }

    private static func describe(_ rule: DeviceRecurrenceRule) -> String {
        var parts = ["freq=\(rule.frequency.rawValue)", "interval=\(rule.interval)"]
        if !rule.daysOfTheWeek.isEmpty {
            parts.append("byday=" + rule.daysOfTheWeek.map { "\($0.weekNumber)\($0.weekday.rawValue)" }.joined(separator: ","))
        }
        if !rule.daysOfTheMonth.isEmpty { parts.append("bymonthday=" + rule.daysOfTheMonth.map(String.init).joined(separator: ",")) }
        if !rule.monthsOfTheYear.isEmpty { parts.append("bymonth=" + rule.monthsOfTheYear.map(String.init).joined(separator: ",")) }
        if !rule.weeksOfTheYear.isEmpty { parts.append("byweekno=" + rule.weeksOfTheYear.map(String.init).joined(separator: ",")) }
        if !rule.daysOfTheYear.isEmpty { parts.append("byyearday=" + rule.daysOfTheYear.map(String.init).joined(separator: ",")) }
        if !rule.setPositions.isEmpty { parts.append("bysetpos=" + rule.setPositions.map(String.init).joined(separator: ",")) }
        switch rule.end {
        case .never: break
        case .occurrenceCount(let count): parts.append("count=\(count)")
        case .endDate(let date): parts.append("until=\(providerVersionString(date))")
        }
        return parts.joined(separator: ";")
    }

    /// `providerVersion` is a `String` column, and the value it carries is a timestamp. Encoded
    /// as seconds since the reference date at millisecond precision rather than through a
    /// `DateFormatter`: this is compared for equality on every pass, so it has to round-trip
    /// byte-identically regardless of locale, calendar or device zone.
    static func providerVersionString(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSinceReferenceDate)
    }
}

// MARK: - Recurrence translation (spec 3C.3)

/// Which device repeat patterns `RecurrenceRule` can express, and — just as importantly — which
/// it cannot.
///
/// The asymmetry matters: translating a rule wrongly is worse than not translating it. An
/// untranslated series shows its first occurrence with a badge saying the pattern is not shown
/// here, which is visible incompleteness. A *mis*translated one shows a plausible, wrong set of
/// occurrences, and in Phase 3D writes that wrong set back over the user's real series.
enum DeviceRecurrenceTranslation {
    enum Result: Equatable {
        /// The device event does not repeat.
        case none
        case translated(RecurrenceRule)
        /// Spec 3C.3: preserved raw, marked, and refused by the mutation layer.
        case unrepresentable

        var rule: RecurrenceRule? {
            guard case .translated(let rule) = self else { return nil }
            return rule
        }

        var isUnrepresentable: Bool { self == .unrepresentable }
    }

    static func translate(_ rules: [DeviceRecurrenceRule], eventStart: Date, timeZoneIdentifier: String) -> Result {
        guard let rule = rules.first else { return .none }
        // Better Calendar models one rule. Flattening two into one would corrupt the user's
        // series on the first write-back; truncating to the first would silently drop
        // occurrences they can see in Apple Calendar.
        guard rules.count == 1 else { return .unrepresentable }

        // Set-positions, week-of-year and day-of-year have no counterpart in the engine at all.
        // (EventKit's *ordinal weekdays* — "the last Friday" — are a different field and do
        // translate; see `positionalRule`.)
        guard rule.setPositions.isEmpty, rule.weeksOfTheYear.isEmpty, rule.daysOfTheYear.isEmpty else {
            return .unrepresentable
        }

        let interval = max(rule.interval, 1)
        let end = translate(rule.end)

        switch rule.frequency {
        case .daily:
            // A daily rule qualified by weekdays or month-days is a form the engine's daily
            // generator does not model.
            guard rule.daysOfTheWeek.isEmpty, rule.daysOfTheMonth.isEmpty, rule.monthsOfTheYear.isEmpty else {
                return .unrepresentable
            }
            return .translated(RecurrenceRule(frequency: .daily, interval: interval, weekdays: [], end: end))

        case .weekly:
            guard rule.daysOfTheMonth.isEmpty, rule.monthsOfTheYear.isEmpty else { return .unrepresentable }
            // An ordinal inside a weekly rule ("the 2nd Tuesday of the week") is meaningless and
            // is not something the engine can express.
            guard rule.daysOfTheWeek.allSatisfy({ $0.weekNumber == 0 }) else { return .unrepresentable }
            return .translated(
                RecurrenceRule(
                    frequency: .weekly,
                    interval: interval,
                    weekdays: Set(rule.daysOfTheWeek.map(\.weekday)),
                    end: end
                )
            )

        case .monthly:
            guard rule.monthsOfTheYear.isEmpty else { return .unrepresentable }
            return monthlyOrYearly(rule, frequency: .monthly, interval: interval, end: end)

        case .yearly:
            // The engine's yearly generator always repeats in the start date's own month, so a
            // month list is expressible only when it says exactly that and nothing more.
            let startMonth = calendar(for: timeZoneIdentifier).component(.month, from: eventStart)
            guard rule.monthsOfTheYear.isEmpty || rule.monthsOfTheYear == [startMonth] else {
                return .unrepresentable
            }
            return monthlyOrYearly(rule, frequency: .yearly, interval: interval, end: end)
        }
    }

    /// Monthly and yearly share the engine's `datesWithinMonth` branch — positional weekdays, an
    /// explicit day-of-month list, or the start date's own day — so they share this translation.
    private static func monthlyOrYearly(
        _ rule: DeviceRecurrenceRule,
        frequency: RecurrenceFrequency,
        interval: Int,
        end: RecurrenceEnd
    ) -> Result {
        // The engine picks one branch or the other. A rule that constrains both would silently
        // lose whichever branch lost.
        guard rule.daysOfTheWeek.isEmpty || rule.daysOfTheMonth.isEmpty else { return .unrepresentable }

        if !rule.daysOfTheWeek.isEmpty {
            guard let positional = positionalRule(rule.daysOfTheWeek) else { return .unrepresentable }
            return .translated(
                RecurrenceRule(
                    frequency: frequency,
                    interval: interval,
                    weekdays: positional.weekdays,
                    setPositions: positional.setPositions,
                    end: end
                )
            )
        }

        if !rule.daysOfTheMonth.isEmpty {
            // A negative day-of-month ("the last day of the month") is RFC 5545-legal and the
            // engine's `clampedDate` cannot express it — it clamps into 1...daysInMonth.
            guard rule.daysOfTheMonth.allSatisfy({ $0 >= 1 }) else { return .unrepresentable }
            return .translated(
                RecurrenceRule(
                    frequency: frequency,
                    interval: interval,
                    weekdays: [],
                    daysOfMonth: rule.daysOfTheMonth.sorted(),
                    end: end
                )
            )
        }

        // No qualifier at all: repeats on the start date's own day of the month, which is the
        // engine's fallback branch and the overwhelmingly common case.
        return .translated(RecurrenceRule(frequency: frequency, interval: interval, weekdays: [], end: end))
    }

    /// `RecurrenceRule` expresses a positional rule as the **cross product** of `setPositions`
    /// and `weekdays` — `[-1] × {friday}` is "the last Friday". EventKit expresses it as a list
    /// of `(weekday, ordinal)` pairs, which is strictly more general: `[(friday, -1), (monday, 2)]`
    /// means "the last Friday *and* the 2nd Monday", and no cross product says that.
    ///
    /// So this translates exactly when the pairs *are* a full cross product, and refuses
    /// otherwise rather than producing a rule that generates dates the user never asked for.
    private static func positionalRule(_ days: [DeviceRecurrenceDayOfWeek]) -> (weekdays: Set<Weekday>, setPositions: [Int])? {
        let positions = Set(days.map(\.weekNumber))
        // All-zero means "every Monday of the month", which the engine's monthly generator does
        // not model — its weekday branch requires a position.
        guard !positions.contains(0) else { return nil }

        let weekdays = Set(days.map(\.weekday))
        // Full cross product, and no pair repeated: |pairs| == |positions| × |weekdays| holds
        // only when every combination is present exactly once.
        guard Set(days).count == days.count, days.count == positions.count * weekdays.count else { return nil }
        return (weekdays, positions.sorted())
    }

    private static func translate(_ end: DeviceRecurrenceEnd) -> RecurrenceEnd {
        switch end {
        case .never: .never
        case .occurrenceCount(let count): .afterOccurrences(count)
        case .endDate(let date): .onDate(date)
        }
    }

    private static func calendar(for timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }
}

// MARK: - Identity

/// Spec 3C.1: a mirrored row is found again by what the *device* calls it, never by title or
/// time — and here, never by a freshly minted `UUID()` either.
///
/// Local ids are **derived** from the provider's identity, which buys three things a random id
/// does not:
///
/// * **Idempotence.** Two passes over the same device event produce the same row id, so the
///   second pass has nothing to write (spec 3C.8).
/// * **Reconstructibility.** Deleting the entire local database and re-mirroring produces the
///   same calendar, which is spec 3C.1's second property and what makes the mirror safe to
///   discard.
/// * **A working resurrection guard.** A tombstone is keyed by the local id, so an event deleted
///   here is still recognisably the same event when the device reports it again (spec 3C.8).
enum DeviceEventIdentity {
    /// A fixed namespace, so ids are stable across builds. Never change this value: every
    /// mirrored row in every installed database is derived from it, and a new namespace would
    /// re-key the entire mirror and orphan every tombstone.
    static let namespace = UUID(uuidString: "8B0F9C2E-3D41-4E7A-9B2C-5A1D6E8F0C34")!

    static func eventID(for key: DeviceEventKey) -> UUID {
        guard let occurrenceDate = key.occurrenceDate else {
            return uuid(name: "event:\(key.identifier)")
        }
        // Spec 3C.1: every detachment of one series shares the identifier, so the occurrence it
        // came from is the other half of its name.
        return uuid(name: "event:\(key.identifier)@\(DeviceEventMapper.providerVersionString(occurrenceDate))")
    }

    static func exceptionID(masterID: UUID, originalStart: Date) -> UUID {
        uuid(name: "exception:\(masterID.uuidString)@\(DeviceEventMapper.providerVersionString(originalStart))")
    }

    static func reminderID(eventID: UUID, relativeOffset: TimeInterval) -> UUID {
        uuid(name: "alarm:\(eventID.uuidString)#\(Int(relativeOffset.rounded()))")
    }

    static func attendeeID(eventID: UUID, attendee: DeviceEventAttendee, index: Int) -> UUID {
        // Identified by address where there is one, so a guest keeps the same row id when
        // someone else is removed from the invitation above them.
        let name = attendee.email?.lowercased() ?? attendee.name ?? "index:\(index)"
        return uuid(name: "attendee:\(eventID.uuidString)#\(name)")
    }

    /// RFC 4122 version 5 (SHA-1, name-based). The standard construction for "a UUID that is a
    /// pure function of a name", so the derivation is recognisable rather than bespoke.
    static func uuid(name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))

        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
