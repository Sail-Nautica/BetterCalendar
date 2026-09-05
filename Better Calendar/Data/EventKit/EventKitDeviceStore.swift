import EventKit
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Spec 3.2: **the only file in the codebase that imports EventKit.** Domain code stays free of
/// it exactly as it stays free of SwiftUI and GRDB, and no view ever sees an EventKit type.
///
/// Named `EventKitCalendarAuthorization` in Phase 3A, when authorization was all it did. It grew
/// into the `EventKitStore` seam in Phase 3B rather than gaining a sibling, so that spec 3.2's
/// "only file" rule stays literally true.
///
/// Holds no long-lived `EKEventStore`. The status read is static, and the instance a request or
/// a discovery pass needs is created inside it and released with it — so launch instantiates
/// nothing from EventKit, which is spec 3.18's "launch must not block on EventKit" applied
/// early. Phase 3C, which fetches events on every reconciliation pass, is where a long-lived
/// store earns its keep; here it would only make launch heavier (ADR 0006).
///
/// EventKit, the status read, `requestFullAccessToEvents()` and calendar enumeration all exist on
/// macOS 14 and iOS 17 — the project's deployment targets — so this compiles unguarded on both.
struct EventKitDeviceStore: EventKitStore {
    var authorizationStatus: CalendarAccessStatus {
        CalendarAccessStatus(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus {
        guard level == .full else {
            // Spec 3A.2 rule 1 / 3A.6: Better Calendar never requests write-only access and so
            // does not declare `NSCalendarsWriteOnlyAccessUsageDescription`. Requesting a level
            // whose usage description is missing terminates the app — so this returns the
            // current status instead of asking. If a later phase needs write-only, the string
            // and this call arrive in the same change.
            return authorizationStatus
        }

        let eventStore = EKEventStore()
        do {
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {
            // A thrown request is not a distinct product state: the status read below is the
            // authoritative answer either way. The error itself carries no user content, but
            // `PrivacyLog.debug` takes a `StaticString` regardless (spec 0.13), so nothing from
            // it can reach a log line.
            PrivacyLog.debug("Calendar access request finished with an error")
        }

        return authorizationStatus
    }

    /// Spec 3B.3. Returns nothing at all below full access rather than an empty list of
    /// calendars that happen not to be readable: BC-EK-003's rule is that write-only must never
    /// look like an empty device, and the caller decides what to say about a state it can see.
    func discoverCalendars() throws -> DeviceCalendarSnapshot {
        guard authorizationStatus.canReadDeviceEvents else {
            return .empty
        }

        let eventStore = EKEventStore()
        return DeviceCalendarSnapshot(
            calendars: eventStore.calendars(for: .event).map(DeviceCalendar.init(_:)),
            defaultCalendarIdentifierForNewEvents: eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        )
    }

    /// Spec 3C.8 step 2. Returns nothing below full access for the same reason `discoverCalendars`
    /// does: BC-EK-003's rule is that write-only must never look like an empty device.
    ///
    /// ### Collapsing occurrences back into a series
    ///
    /// `events(matching:)` expands recurrence — a weekly series over a month-long window comes
    /// back as four or five `EKEvent`s that all share one `eventIdentifier`. Mirroring those
    /// directly would write one row per occurrence and throw the rule away, so this collapses
    /// them: each distinct identifier is fetched once via `event(withIdentifier:)`, which returns
    /// the **series master** carrying its own start date and its recurrence rules, and every
    /// detached occurrence in the window is kept alongside it as its own `DeviceEvent`.
    ///
    /// That is why the collapsing lives here rather than in the pure layer: it needs the event
    /// store, and only this file is allowed to have one (spec 3.2).
    func events(in range: DateInterval, calendarIdentifiers: Set<String>) async throws -> [DeviceEvent] {
        guard authorizationStatus.canReadDeviceEvents, !calendarIdentifiers.isEmpty else { return [] }

        // Spec 3.27: fetches and diffs run off the main thread, and rendering never blocks on
        // reconciliation. `fetch` is `static` so this closure captures only the two `Sendable`
        // arguments — no event store, no `self` — and `[DeviceEvent]` is a tree of value types,
        // so nothing from EventKit crosses back.
        return await Task.detached(priority: .userInitiated) {
            Self.fetch(in: range, calendarIdentifiers: calendarIdentifiers)
        }.value
    }

    private static func fetch(in range: DateInterval, calendarIdentifiers: Set<String>) -> [DeviceEvent] {
        let eventStore = EKEventStore()
        let calendars = eventStore.calendars(for: .event).filter { calendarIdentifiers.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        let occurrences = eventStore.events(matching: predicate)

        var results: [DeviceEvent] = []
        var seenSeriesIdentifiers: Set<String> = []

        for occurrence in occurrences {
            guard let identifier = occurrence.eventIdentifier else { continue }

            // A detached occurrence is its own row, keyed by the slot it came from — the pair
            // spec 3C.1 requires, because every detachment of one series shares the identifier.
            if occurrence.isDetached {
                results.append(DeviceEvent(occurrence, calendarIdentifier: occurrence.calendar?.calendarIdentifier))
                continue
            }

            guard seenSeriesIdentifiers.insert(identifier).inserted else { continue }

            // For a repeating event this returns the master, not the occurrence that matched the
            // window, which is exactly what the mirror needs. For a single event it returns the
            // event itself, so there is no special case.
            guard let master = eventStore.event(withIdentifier: identifier) else {
                // Vanished between the query and the fetch. Skipping it means this pass simply
                // does not mention it — and a row is only ever *deleted* for an event that was
                // inside the window and absent from the fetch, so the next pass decides. Better
                // than mirroring the expanded occurrence and losing the rule.
                continue
            }
            results.append(DeviceEvent(master, calendarIdentifier: master.calendar?.calendarIdentifier))
        }

        // Spec 3C.3: a series' master must be mirrored before its detachments, or a detachment
        // has no master to point at. The mirror pass orders its own output too; ordering here as
        // well means the adapter's contract does not depend on that.
        return results.sorted { lhs, rhs in
            lhs.isDetached == rhs.isDetached ? lhs.startDate < rhs.startDate : !lhs.isDetached
        }
    }

    func event(withIdentifier identifier: String) async throws -> DeviceEvent? {
        guard authorizationStatus.canReadDeviceEvents else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let eventStore = EKEventStore()
            guard let event = eventStore.event(withIdentifier: identifier) else { return nil }
            return DeviceEvent(event, calendarIdentifier: event.calendar?.calendarIdentifier)
        }.value
    }

    /// Spec 3.19/3.17. Two rules are enforced here rather than left to the caller, because this
    /// is the only place they *can* be enforced:
    ///
    /// * An update **fetches the live event and patches it**. It never constructs a fresh
    ///   `EKEvent` from our model and saves that, which would write back every field we do not
    ///   model as absent — the failure that strips a video-call link off a meeting.
    /// * Only `write.fields` is applied. A field the planner did not name is not written, even
    ///   though `write.event` carries a value for it.
    func save(_ write: DeviceEventWrite) async throws -> DeviceWriteReceipt {
        guard authorizationStatus.canCreateDeviceEvents else { throw DeviceWriteFailure.permission }

        return try await Task.detached(priority: .userInitiated) {
            let eventStore = EKEventStore()

            let event: EKEvent
            if let identifier = write.identifier {
                guard let existing = eventStore.event(withIdentifier: identifier) else {
                    // Gone from the device between the plan and the write. Not retryable: there
                    // is nothing left to update.
                    throw DeviceWriteFailure.permanent
                }
                event = existing
            } else {
                guard let calendar = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == write.calendarIdentifier }) else {
                    throw DeviceWriteFailure.permanent
                }
                guard calendar.allowsContentModifications else { throw DeviceWriteFailure.permission }
                event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
            }

            event.apply(write.event, fields: write.fields)

            do {
                try eventStore.save(event, span: write.span.ekSpan, commit: true)
            } catch {
                throw DeviceWriteFailure(error)
            }

            return DeviceWriteReceipt(
                identifier: event.eventIdentifier ?? "",
                externalIdentifier: event.calendarItemExternalIdentifier,
                lastModified: event.lastModifiedDate
            )
        }.value
    }

    func remove(identifier: String, span: DeviceEventSpan) async throws {
        guard authorizationStatus.canCreateDeviceEvents else { throw DeviceWriteFailure.permission }

        try await Task.detached(priority: .userInitiated) {
            let eventStore = EKEventStore()
            guard let event = eventStore.event(withIdentifier: identifier) else {
                // Already gone. Spec 3D.11: a delete for an event the device no longer has is a
                // success, not a failure — the effect this mutation wanted already exists.
                return
            }
            do {
                try eventStore.remove(event, span: span.ekSpan, commit: true)
            } catch {
                throw DeviceWriteFailure(error)
            }
        }.value
    }
}

// MARK: - Translation

private extension CalendarAccessStatus {
    /// The translation that keeps `EKAuthorizationStatus` out of the domain layer.
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .fullAccess:
            self = .fullAccess
        case .writeOnly:
            self = .writeOnly
        @unknown default:
            // A status this build does not understand is treated as "not yet answered" rather
            // than as access: the failure mode of guessing high is displaying a calendar we
            // cannot actually read.
            self = .notDetermined
        }
    }
}

private extension DeviceCalendar {
    init(_ calendar: EKCalendar) {
        self.init(
            identifier: calendar.calendarIdentifier,
            source: DeviceCalendarSource(calendar.source),
            title: calendar.title,
            type: DeviceCalendarType(calendar.type),
            colorHex: calendar.calendarColorHex,
            isImmutable: calendar.isImmutable,
            isSubscribed: calendar.isSubscribed,
            allowsContentModifications: calendar.allowsContentModifications,
            allowedAvailabilities: calendar.supportedEventAvailabilities.betterCalendarAvailabilities
        )
    }
}

private extension DeviceEventSpan {
    var ekSpan: EKSpan {
        switch self {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }
}

private extension EKEvent {
    /// The write half of spec 3C.2's table: exactly `fields`, onto a live `EKEvent`.
    ///
    /// Attendees are absent by construction — EventKit exposes no setter, and
    /// `DeviceEventField` has no case for them, so this cannot be asked to try.
    func apply(_ source: DeviceEvent, fields: Set<DeviceEventField>) {
        for field in fields {
            switch field {
            case .title: title = source.title
            case .notes: notes = source.notes
            case .location: location = source.location
            case .url: url = source.urlString.flatMap(URL.init(string:))
            case .startDate: startDate = source.startDate
            case .endDate: endDate = source.endDate
            case .isAllDay: isAllDay = source.isAllDay
            case .timeZone: timeZone = source.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            case .availability: availability = source.availability.ekAvailability
            case .alarms: alarms = source.alarms.map { EKAlarm(relativeOffset: $0.relativeOffset) }
            case .recurrence: recurrenceRules = source.recurrenceRules.map(EKRecurrenceRule.init(_:))
            }
        }
    }
}

private extension DeviceEventAvailability {
    var ekAvailability: EKEventAvailability {
        switch self {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .notSupported
        }
    }
}

private extension EKRecurrenceRule {
    convenience init(_ rule: DeviceRecurrenceRule) {
        self.init(
            recurrenceWith: rule.frequency.ekFrequency,
            interval: max(rule.interval, 1),
            daysOfTheWeek: rule.daysOfTheWeek.isEmpty ? nil : rule.daysOfTheWeek.map { EKRecurrenceDayOfWeek($0.weekday.ekWeekday, weekNumber: $0.weekNumber) },
            daysOfTheMonth: rule.daysOfTheMonth.isEmpty ? nil : rule.daysOfTheMonth.map(NSNumber.init(value:)),
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: rule.end.ekEnd
        )
    }
}

private extension DeviceRecurrenceFrequency {
    var ekFrequency: EKRecurrenceFrequency {
        switch self {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
    }
}

private extension Weekday {
    var ekWeekday: EKWeekday {
        // `EKWeekday` and `Weekday` share RFC 5545's Sunday-is-1 numbering.
        EKWeekday(rawValue: rawValue) ?? .sunday
    }
}

private extension DeviceRecurrenceEnd {
    var ekEnd: EKRecurrenceEnd? {
        switch self {
        case .never: nil
        case .occurrenceCount(let count): EKRecurrenceEnd(occurrenceCount: count)
        case .endDate(let date): EKRecurrenceEnd(end: date)
        }
    }
}

private extension DeviceWriteFailure {
    /// Spec 3.21: classify, rather than collapsing every `NSError` into "retry".
    ///
    /// EventKit's error domain is the only signal available, and it is coarse — so anything not
    /// positively recognised is treated as **transient**. That is the safe default here: a
    /// transient classification costs a retry, whereas a wrong `permanent` throws away the
    /// user's edit and a wrong `permission` parks it until they change a setting they never
    /// touched.
    init(_ error: Error) {
        if let failure = error as? DeviceWriteFailure {
            self = failure
            return
        }

        let nsError = error as NSError
        guard nsError.domain == EKErrorDomain, let code = EKError.Code(rawValue: nsError.code) else {
            self = .transient
            return
        }

        switch code {
        case .calendarReadOnly, .calendarIsImmutable, .sourceDoesNotAllowCalendarAddDelete, .calendarDoesNotAllowEvents:
            self = .permission
        case .eventNotMutable, .objectBelongsToDifferentStore, .invalidSpan, .calendarHasNoSource, .noCalendar, .noStartDate, .noEndDate, .datesInverted:
            self = .permanent
        default:
            self = .transient
        }
    }
}

private extension DeviceEvent {
    /// Spec 3C.2's table, applied to a real `EKEvent`.
    ///
    /// `calendarIdentifier` is passed in rather than read here because `EKEvent.calendar` is
    /// optional and an event with none cannot be attributed to a mirrored row at all; the mirror
    /// skips it rather than orphaning it.
    init(_ event: EKEvent, calendarIdentifier: String?) {
        self.init(
            identifier: event.eventIdentifier ?? "",
            externalIdentifier: event.calendarItemExternalIdentifier,
            calendarIdentifier: calendarIdentifier ?? "",
            title: event.title ?? "",
            notes: event.notes,
            location: event.location,
            urlString: event.url?.absoluteString,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZone?.identifier,
            availability: DeviceEventAvailability(event.availability),
            status: DeviceEventStatus(event.status),
            alarms: (event.alarms ?? []).compactMap(DeviceEventAlarm.init(_:)),
            recurrenceRules: (event.recurrenceRules ?? []).map(DeviceRecurrenceRule.init(_:)),
            attendees: DeviceEvent.attendees(of: event),
            lastModified: event.lastModifiedDate,
            isDetached: event.isDetached,
            occurrenceDate: event.occurrenceDate,
            rawFields: DeviceEvent.rawFields(of: event)
        )
    }

    /// EventKit exposes the organizer separately from `attendees`, and usually *also* inside it.
    /// Merged here so the domain model has one list with the organizer flagged, rather than a
    /// list plus a field that may or may not duplicate one of its entries.
    static func attendees(of event: EKEvent) -> [DeviceEventAttendee] {
        var merged = (event.attendees ?? []).map { DeviceEventAttendee($0, isOrganizer: $0 === event.organizer) }
        if let organizer = event.organizer, !merged.contains(where: \.isOrganizer) {
            merged.insert(DeviceEventAttendee(organizer, isOrganizer: true), at: 0)
        }
        return merged
    }

    /// Spec 3.17 (BC-EK-017): the fields Better Calendar does not model, kept so a title-only
    /// edit cannot strip a video-call link off a meeting.
    ///
    /// Strings only, and only what EventKit actually exposes as one. `structuredLocation`'s geo
    /// coordinates and radius are rendered rather than archived, because the payload has to
    /// compare byte-equal between two passes over an unchanged event — an `NSKeyedArchiver` blob
    /// carries encoder state that does not.
    static func rawFields(of event: EKEvent) -> [String: String] {
        var fields: [String: String] = [:]

        if let structured = event.structuredLocation {
            if let title = structured.title, !title.isEmpty {
                fields["structuredLocationTitle"] = title
            }
            if let location = structured.geoLocation {
                fields["geoLatitude"] = String(format: "%.6f", location.coordinate.latitude)
                fields["geoLongitude"] = String(format: "%.6f", location.coordinate.longitude)
            }
            if structured.radius > 0 {
                fields["geoRadius"] = String(format: "%.1f", structured.radius)
            }
        }

        // Spec 3.17's headline example — "a title-only edit stripping the Google Meet link off a
        // meeting" — needs no entry here, and that is worth stating rather than leaving as an
        // apparent omission: EventKit exposes no conference property at all. A video-call link
        // reaches us in `url`, `notes`, or the structured location's title, all three of which
        // Better Calendar models and therefore round-trips through the mapping itself. The
        // preservation this bucket provides is for what the mapping *cannot* carry.
        if let birthdayContact = event.birthdayContactIdentifier {
            fields["birthdayContactIdentifier"] = birthdayContact
        }
        if event.hasNotes, let notes = event.notes, notes.count > 0 {
            // Not a copy of the notes — just the fact that the provider considers them set, so a
            // 3D patch can tell "notes cleared locally" from "notes never present". Length only:
            // event content never enters a preserved diagnostic payload (spec 0.13).
            fields["notesLength"] = String(notes.count)
        }

        return fields
    }
}

private extension DeviceEventAttendee {
    init(_ participant: EKParticipant, isOrganizer: Bool) {
        self.init(
            name: participant.name,
            // `EKParticipant.url` is a `mailto:` URL for an email participant, and EventKit
            // exposes no address property — this is the only one it gives us. A participant
            // whose URL is not `mailto:` (a room resource, say) has no address rather than a
            // URL masquerading as one.
            email: DeviceEventAttendee.emailAddress(from: participant.url),
            participationStatus: DeviceEventParticipationStatus(participant.participantStatus),
            role: DeviceEventAttendeeRole(participant.participantRole),
            isOrganizer: isOrganizer,
            isCurrentUser: participant.isCurrentUser
        )
    }

    static func emailAddress(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : String(address)
    }
}

private extension DeviceEventAlarm {
    /// An absolute-date or location-triggered alarm has no relative offset and is not mirrored —
    /// see `DeviceEventMapper.reminders`, which drops it rather than approximating it.
    init?(_ alarm: EKAlarm) {
        guard alarm.absoluteDate == nil, alarm.structuredLocation == nil else { return nil }
        self.init(relativeOffset: alarm.relativeOffset)
    }
}

private extension DeviceEventAvailability {
    init(_ availability: EKEventAvailability) {
        switch availability {
        case .busy: self = .busy
        case .free: self = .free
        case .tentative: self = .tentative
        case .unavailable: self = .unavailable
        case .notSupported: self = .notSupported
        @unknown default: self = .busy
        }
    }
}

private extension DeviceEventStatus {
    init(_ status: EKEventStatus) {
        switch status {
        case .none: self = .none
        case .confirmed: self = .confirmed
        case .tentative: self = .tentative
        case .canceled: self = .cancelled
        @unknown default: self = .none
        }
    }
}

private extension DeviceEventParticipationStatus {
    init(_ status: EKParticipantStatus) {
        switch status {
        case .unknown: self = .unknown
        case .pending: self = .pending
        case .accepted: self = .accepted
        case .declined: self = .declined
        case .tentative: self = .tentative
        case .delegated: self = .delegated
        // Reminder-only states; an event participant never reports them.
        case .completed, .inProcess: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

private extension DeviceEventAttendeeRole {
    init(_ role: EKParticipantRole) {
        switch role {
        case .unknown: self = .unknown
        case .required: self = .required
        case .optional: self = .optional
        case .chair: self = .chair
        case .nonParticipant: self = .nonParticipant
        @unknown default: self = .unknown
        }
    }
}

private extension DeviceRecurrenceRule {
    init(_ rule: EKRecurrenceRule) {
        self.init(
            frequency: DeviceRecurrenceFrequency(rule.frequency),
            interval: rule.interval,
            daysOfTheWeek: (rule.daysOfTheWeek ?? []).compactMap(DeviceRecurrenceDayOfWeek.init(_:)),
            daysOfTheMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfTheYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            weeksOfTheYear: (rule.weeksOfTheYear ?? []).map(\.intValue),
            daysOfTheYear: (rule.daysOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            end: DeviceRecurrenceEnd(rule.recurrenceEnd)
        )
    }
}

private extension DeviceRecurrenceFrequency {
    init(_ frequency: EKRecurrenceFrequency) {
        switch frequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        @unknown default: self = .daily
        }
    }
}

private extension DeviceRecurrenceDayOfWeek {
    /// `EKWeekday` and `Weekday` share RFC 5545's Sunday-is-1 numbering, so the raw value carries
    /// across — but it is validated rather than force-unwrapped, because a value this build does
    /// not understand must drop the *day*, which makes the rule fail the cross-product check and
    /// be preserved raw, rather than crash discovery.
    init?(_ day: EKRecurrenceDayOfWeek) {
        guard let weekday = Weekday(rawValue: day.dayOfTheWeek.rawValue) else { return nil }
        self.init(weekday, weekNumber: day.weekNumber)
    }
}

private extension DeviceRecurrenceEnd {
    init(_ end: EKRecurrenceEnd?) {
        guard let end else {
            self = .never
            return
        }
        if let endDate = end.endDate {
            self = .endDate(endDate)
        } else if end.occurrenceCount > 0 {
            self = .occurrenceCount(end.occurrenceCount)
        } else {
            self = .never
        }
    }
}

private extension DeviceCalendarSource {
    init(_ source: EKSource?) {
        // `EKCalendar.source` is `null_unspecified` in the header. A calendar with no source is
        // not a state EventKit is expected to produce, but it is expressible, and a crash on it
        // would be a crash in discovery — so it degrades to an unattributable local source.
        guard let source else {
            self.init(identifier: "", title: "Other", type: .local)
            return
        }
        self.init(
            identifier: source.sourceIdentifier,
            title: source.title,
            type: DeviceCalendarSourceType(source.sourceType)
        )
    }
}

private extension DeviceCalendarSourceType {
    init(_ type: EKSourceType) {
        switch type {
        case .local: self = .local
        case .exchange: self = .exchange
        case .calDAV: self = .calDAV
        case .mobileMe: self = .mobileMe
        case .subscribed: self = .subscribed
        case .birthdays: self = .birthdays
        @unknown default: self = .calDAV
        }
    }
}

private extension DeviceCalendarType {
    init(_ type: EKCalendarType) {
        switch type {
        case .local: self = .local
        case .calDAV: self = .calDAV
        case .exchange: self = .exchange
        case .subscription: self = .subscription
        case .birthday: self = .birthday
        @unknown default: self = .calDAV
        }
    }
}

private extension EKCalendarEventAvailabilityMask {
    /// The two availability values Better Calendar models, intersected with what the calendar
    /// accepts. `EKCalendarEventAvailabilityNone` means the calendar supports availability at
    /// all, and maps to an empty set rather than to a guess.
    var betterCalendarAvailabilities: [EventAvailability] {
        var availabilities: [EventAvailability] = []
        if contains(.busy) {
            availabilities.append(.busy)
        }
        if contains(.free) {
            availabilities.append(.free)
        }
        return availabilities
    }
}

private extension EKCalendar {
    /// Spec 3.6/ADR 0004: the provider's exact colour, as the `#RRGGBB` the `color_hex` column
    /// already stores. Converted through sRGB so a calendar in a wide-gamut or grayscale space
    /// does not read back as garbage components.
    var calendarColorHex: String? {
        guard let cgColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }

        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }

        return String(format: "#%02X%02X%02X", channel(components[0]), channel(components[1]), channel(components[2]))
    }
}
