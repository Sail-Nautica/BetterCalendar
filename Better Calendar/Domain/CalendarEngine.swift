import Foundation

struct CalendarOccurrence: Identifiable, Hashable {
    let event: CalendarEvent
    let occurrenceStartDate: Date
    let occurrenceEndDate: Date
    let originalStartDate: Date
    let occurrenceIndex: Int

    init(event: CalendarEvent, occurrenceStartDate: Date, occurrenceEndDate: Date, originalStartDate: Date, occurrenceIndex: Int) {
        self.event = event
        self.occurrenceStartDate = occurrenceStartDate
        self.occurrenceEndDate = occurrenceEndDate
        self.originalStartDate = originalStartDate
        self.occurrenceIndex = occurrenceIndex
    }

    init(event: CalendarEvent) {
        self.init(
            event: event,
            occurrenceStartDate: event.startDate,
            occurrenceEndDate: event.endDate,
            originalStartDate: event.startDate,
            occurrenceIndex: 0
        )
    }

    var id: String {
        "\(event.id.uuidString)-\(occurrenceKey)"
    }

    var occurrenceKey: String {
        if event.isAllDay {
            return event.localDateString(for: occurrenceStartDate)
        }

        return String(Int(occurrenceStartDate.timeIntervalSinceReferenceDate.rounded()))
    }

    var isRecurringOccurrence: Bool {
        event.recurrence != nil
    }

    var duration: TimeInterval {
        occurrenceEndDate.timeIntervalSince(occurrenceStartDate)
    }

    var displayEvent: CalendarEvent {
        var displayEvent = event
        displayEvent.startDate = occurrenceStartDate
        displayEvent.endDate = occurrenceEndDate
        return displayEvent
    }

    func occurs(on date: Date, displayCalendar: Calendar = .current) -> Bool {
        if event.isAllDay {
            let selectedDate = LocalCalendarDate(date: date, calendar: displayCalendar)
            let startDate = LocalCalendarDate(date: occurrenceStartDate, calendar: event.calendarInOriginalTimeZone)
            let endDate = LocalCalendarDate(date: occurrenceEndDate, calendar: event.calendarInOriginalTimeZone)
            return startDate <= selectedDate && selectedDate < endDate
        }

        guard let dayInterval = displayCalendar.dateInterval(of: .day, for: date) else {
            return false
        }

        return occurrenceStartDate < dayInterval.end && occurrenceEndDate > dayInterval.start
    }

    func moved(to newStartDate: Date) -> CalendarOccurrence {
        CalendarOccurrence(
            event: event,
            occurrenceStartDate: newStartDate,
            occurrenceEndDate: newStartDate.addingTimeInterval(max(duration, 15 * 60)),
            originalStartDate: originalStartDate,
            occurrenceIndex: occurrenceIndex
        )
    }
}

struct RecurrenceExpander {
    static let defaultMaximumGeneratedOccurrences = 5_000

    var maximumGeneratedOccurrences = Self.defaultMaximumGeneratedOccurrences

    /// - Parameter exceptions: this event's `RecurrenceException`s (BC-REC-010). A cancelled or
    ///   modified occurrence is skipped here — a modified occurrence's replacement is an
    ///   ordinary standalone `CalendarEvent` that already flows through the caller's own
    ///   non-recurring pass, so nothing else needs to happen for it in this function. Exceptions
    ///   never affect `occurrenceIndex`/COUNT bookkeeping, matching how EXDATE doesn't reduce an
    ///   RRULE's COUNT in RFC 5545.
    func occurrences(of event: CalendarEvent, in visibleRange: DateInterval, exceptions: [RecurrenceException] = []) -> [CalendarOccurrence] {
        guard let recurrence = event.recurrence, recurrence.frequency != .never else {
            return event.intersects(visibleRange)
                ? [CalendarOccurrence(event: event, occurrenceStartDate: event.startDate, occurrenceEndDate: event.endDate, originalStartDate: event.startDate, occurrenceIndex: 0)]
                : []
        }

        let calendar = event.calendarInOriginalTimeZone
        let durationComponents = event.durationComponents(in: calendar)
        var generated: [CalendarOccurrence] = []
        var totalOccurrenceIndex = 0

        for occurrenceStart in recurrenceStartDates(for: event, recurrence: recurrence, calendar: calendar) {
            guard totalOccurrenceIndex < maximumGeneratedOccurrences else { break }
            defer { totalOccurrenceIndex += 1 }

            if !recurrence.includes(occurrenceStart, occurrenceIndex: totalOccurrenceIndex, event: event, calendar: calendar) {
                break
            }

            guard let occurrenceEnd = calendar.date(byAdding: durationComponents, to: occurrenceStart) else {
                continue
            }

            if occurrenceStart >= visibleRange.end {
                break
            }

            if exceptions.contains(where: { $0.matches(occurrenceStart: occurrenceStart, event: event) }) {
                continue
            }

            let occurrence = CalendarOccurrence(
                event: event,
                occurrenceStartDate: occurrenceStart,
                occurrenceEndDate: occurrenceEnd,
                originalStartDate: event.startDate,
                occurrenceIndex: totalOccurrenceIndex
            )

            if occurrenceStart < visibleRange.end && occurrenceEnd > visibleRange.start {
                generated.append(occurrence)
            }
        }

        return generated
    }

    private func recurrenceStartDates(for event: CalendarEvent, recurrence: RecurrenceRule, calendar: Calendar) -> AnySequence<Date> {
        switch recurrence.frequency {
        case .never:
            return AnySequence(EmptyCollection<Date>())
        case .daily:
            return AnySequence(dailyDates(startingAt: event.startDate, interval: max(recurrence.interval, 1), calendar: calendar))
        case .weekly:
            return AnySequence(weeklyDates(startingAt: event.startDate, recurrence: recurrence, calendar: calendar))
        case .monthly:
            return AnySequence(monthlyDates(startingAt: event.startDate, recurrence: recurrence, calendar: calendar))
        case .yearly:
            return AnySequence(yearlyDates(startingAt: event.startDate, recurrence: recurrence, calendar: calendar))
        }
    }

    private func dailyDates(startingAt startDate: Date, interval: Int, calendar: Calendar) -> AnySequence<Date> {
        AnySequence(sequence(state: 0) { offset in
            defer { offset += interval }
            return calendar.date(byAdding: .day, value: offset, to: startDate)
        })
    }

    private func weeklyDates(startingAt startDate: Date, recurrence: RecurrenceRule, calendar: Calendar) -> AnySequence<Date> {
        let interval = max(recurrence.interval, 1)
        let weekdays = recurrence.weekdays.isEmpty
            ? [Weekday(rawValue: calendar.component(.weekday, from: startDate))].compactMap { $0 }
            : recurrence.weekdays.sorted()
        let timeComponents = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: startDate)
        let startWeek = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start ?? startDate

        return AnySequence(sequence(state: (weekOffset: 0, weekdayIndex: 0)) { state in
            while true {
                guard let weekStart = calendar.date(byAdding: .weekOfYear, value: state.weekOffset, to: startWeek) else {
                    return nil
                }

                let weekday = weekdays[state.weekdayIndex]
                state.weekdayIndex += 1
                if state.weekdayIndex >= weekdays.count {
                    state.weekdayIndex = 0
                    state.weekOffset += interval
                }

                var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
                components.weekday = weekday.rawValue
                components.hour = timeComponents.hour
                components.minute = timeComponents.minute
                components.second = timeComponents.second
                components.nanosecond = timeComponents.nanosecond

                guard let candidate = calendar.date(from: components) else { continue }
                if candidate >= startDate {
                    return candidate
                }
            }
        })
    }

    /// - Note: when `recurrence.daysOfMonth`/`.setPositions` are both empty (the previous,
    ///   still-default shape), this produces byte-identical dates to the original single-day
    ///   implementation — existing persisted rules and tests are unaffected.
    private func monthlyDates(startingAt startDate: Date, recurrence: RecurrenceRule, calendar: Calendar) -> AnySequence<Date> {
        let interval = max(recurrence.interval, 1)
        let originalComponents = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: startDate)
        let day = originalComponents.day ?? 1
        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate

        return AnySequence(sequence(state: (monthOffset: 0, pending: [Date]())) { state in
            while true {
                if !state.pending.isEmpty {
                    return state.pending.removeFirst()
                }

                guard let targetMonthStart = calendar.date(byAdding: .month, value: state.monthOffset, to: monthStart) else {
                    return nil
                }
                state.monthOffset += interval

                state.pending = datesWithinMonth(
                    containing: targetMonthStart,
                    recurrence: recurrence,
                    fallbackDay: day,
                    timeComponents: originalComponents,
                    calendar: calendar
                )
            }
        })
    }

    /// See `monthlyDates` — same byte-identical-fallback guarantee applies here.
    private func yearlyDates(startingAt startDate: Date, recurrence: RecurrenceRule, calendar: Calendar) -> AnySequence<Date> {
        let interval = max(recurrence.interval, 1)
        let originalComponents = calendar.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: startDate)
        let month = originalComponents.month ?? 1
        let day = originalComponents.day ?? 1
        let year = calendar.component(.year, from: startDate)

        return AnySequence(sequence(state: (yearOffset: 0, pending: [Date]())) { state in
            while true {
                if !state.pending.isEmpty {
                    return state.pending.removeFirst()
                }

                var components = DateComponents()
                components.year = year + state.yearOffset
                components.month = month
                components.day = 1
                components.hour = originalComponents.hour
                components.minute = originalComponents.minute
                components.second = originalComponents.second
                components.nanosecond = originalComponents.nanosecond
                state.yearOffset += interval

                guard let monthStart = calendar.date(from: components) else {
                    return nil
                }

                state.pending = datesWithinMonth(
                    containing: monthStart,
                    recurrence: recurrence,
                    fallbackDay: day,
                    timeComponents: originalComponents,
                    calendar: calendar
                )
            }
        })
    }

    /// Every candidate date within the month containing `monthDate`, per the recurrence's
    /// positional/explicit/single-day configuration — the shared branch used by both
    /// `monthlyDates` and `yearlyDates` (spec 1.11 custom recurrence: day-of-month and
    /// "last Friday"-style positional rules, BC-REC-011).
    private func datesWithinMonth(containing monthDate: Date, recurrence: RecurrenceRule, fallbackDay: Int, timeComponents: DateComponents, calendar: Calendar) -> [Date] {
        if !recurrence.setPositions.isEmpty, !recurrence.weekdays.isEmpty {
            return nthWeekdayDates(
                inMonthContaining: monthDate,
                weekdays: recurrence.weekdays,
                setPositions: recurrence.setPositions,
                timeComponents: timeComponents,
                calendar: calendar
            ).sorted()
        }

        if !recurrence.daysOfMonth.isEmpty {
            return recurrence.daysOfMonth.sorted().compactMap { dayOfMonth in
                clampedDate(inMonthContaining: monthDate, day: dayOfMonth, timeComponents: timeComponents, calendar: calendar)
            }
        }

        return clampedDate(inMonthContaining: monthDate, day: fallbackDay, timeComponents: timeComponents, calendar: calendar).map { [$0] } ?? []
    }

    /// Resolves a positional rule ("2nd Tuesday" = `setPositions: [2]`; "last Friday" =
    /// `setPositions: [-1]`, following the RFC 5545 `BYSETPOS` convention where negative counts
    /// from the end of the month) against every weekday in `weekdays`, for the month containing
    /// `monthDate`. A position with no matching date that month (e.g. a "5th Monday" in a month
    /// with only four) is simply omitted, not clamped.
    private func nthWeekdayDates(inMonthContaining monthDate: Date, weekdays: Set<Weekday>, setPositions: [Int], timeComponents: DateComponents, calendar: Calendar) -> [Date] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthDate) else { return [] }
        let monthComponents = calendar.dateComponents([.year, .month], from: monthDate)

        var results: [Date] = []
        for weekday in weekdays {
            var matchingDays: [Int] = []
            for day in dayRange {
                var components = monthComponents
                components.day = day
                guard let date = calendar.date(from: components) else { continue }
                if calendar.component(.weekday, from: date) == weekday.rawValue {
                    matchingDays.append(day)
                }
            }

            for position in setPositions {
                let index = position > 0 ? position - 1 : matchingDays.count + position
                guard matchingDays.indices.contains(index) else { continue }

                var components = monthComponents
                components.day = matchingDays[index]
                components.hour = timeComponents.hour
                components.minute = timeComponents.minute
                components.second = timeComponents.second
                components.nanosecond = timeComponents.nanosecond
                if let date = calendar.date(from: components) {
                    results.append(date)
                }
            }
        }
        return results
    }

    private func clampedDate(inMonthContaining monthDate: Date, day: Int, timeComponents: DateComponents, calendar: Calendar) -> Date? {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthDate) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month], from: monthDate)
        components.day = min(max(day, 1), dayRange.count)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second
        components.nanosecond = timeComponents.nanosecond
        return calendar.date(from: components)
    }
}

/// Spec 1.13 search filters (BC-SRCH-002): date range, calendar, past/future, all-day, and
/// recurring. Every field is independently optional/off by default, so an unfiltered search
/// (the common case) needs no special-casing at the call site.
struct SearchFilters: Equatable {
    enum Timeframe: Equatable {
        case all
        case futureOnly
        case pastOnly
    }

    var calendarID: UUID?
    var dateRange: DateInterval?
    var timeframe: Timeframe = .all
    var allDayOnly = false
    var recurringOnly = false

    func matches(_ event: CalendarEvent, now: Date) -> Bool {
        if let calendarID, event.calendarID != calendarID {
            return false
        }
        if let dateRange, !event.intersects(dateRange) {
            return false
        }
        switch timeframe {
        case .all:
            break
        case .futureOnly:
            if event.endDate < now { return false }
        case .pastOnly:
            if event.endDate >= now { return false }
        }
        if allDayOnly, !event.isAllDay {
            return false
        }
        if recurringOnly, event.recurrence == nil {
            return false
        }
        return true
    }
}

struct LocalCalendarDate: Comparable, Hashable {
    var year: Int
    var month: Int
    var day: Int

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    static func < (lhs: LocalCalendarDate, rhs: LocalCalendarDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

extension CalendarEvent {
    var calendarInOriginalTimeZone: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    var allDayLocalDateRangeText: String {
        guard isAllDay else { return timeRangeText() }

        let calendar = calendarInOriginalTimeZone
        let startText = formattedLocalDate(startDate, calendar: calendar)
        guard let inclusiveEndDate = calendar.date(byAdding: .day, value: -1, to: endDate) else {
            return startText
        }

        if calendar.isDate(startDate, inSameDayAs: inclusiveEndDate) {
            return startText
        }

        let endText = formattedLocalDate(inclusiveEndDate, calendar: calendar)
        return "\(startText) – \(endText)"
    }

    func localDateString(for date: Date) -> String {
        let components = calendarInOriginalTimeZone.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }

    func timeText(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    func timeRangeText() -> String {
        if isAllDay {
            return allDayLocalDateRangeText
        }

        return "\(timeText(for: startDate)) – \(timeText(for: endDate))"
    }

    func accessibilitySummary(calendarName: String) -> String {
        var parts = [title, calendarName, timeRangeText()]
        if let location {
            parts.append(location)
        }
        if recurrence != nil {
            parts.append("Repeats")
        }
        return parts.joined(separator: ", ")
    }

    /// BC-EVT-020 (spec 1.10 "Share as text"): a short, human-readable plain-text summary
    /// suitable for `ShareLink`/Messages/Mail — never event notes, matching spec 0.13 privacy
    /// guidance for anything that could leave the device via a general-purpose share sheet.
    func shareSummaryText(calendarName: String) -> String {
        var lines = [title, timeRangeText(), calendarName]
        if let location {
            lines.append(location)
        }
        if let urlString {
            lines.append(urlString)
        }
        if recurrence != nil {
            lines.append("Repeats")
        }
        return lines.joined(separator: "\n")
    }

    /// Start date as it should be displayed in `displayCalendar`'s time zone.
    ///
    /// Floating events re-anchor their stored wall-clock components into the viewing zone, so
    /// "8:00 PM" stays 8:00 PM after travelling (specification 0.9). Timed and all-day events
    /// return their stored date completely unchanged, so existing behaviour is byte-identical.
    func displayStartDate(in displayCalendar: Calendar = .current) -> Date {
        floatingAnchoredDate(startDate, in: displayCalendar)
    }

    /// End date as it should be displayed in `displayCalendar`'s time zone. See `displayStartDate`.
    func displayEndDate(in displayCalendar: Calendar = .current) -> Date {
        floatingAnchoredDate(endDate, in: displayCalendar)
    }

    private func floatingAnchoredDate(_ date: Date, in displayCalendar: Calendar) -> Date {
        guard timeType == .floating else { return date }

        let storedComponents = calendarInOriginalTimeZone
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return displayCalendar.date(from: storedComponents) ?? date
    }

    func intersects(_ interval: DateInterval) -> Bool {
        startDate < interval.end && endDate > interval.start
    }

    /// This event's start time as it would read in a different time zone (BC-TZ-001, spec
    /// 1.17 "dual-time display"). `nil` for all-day/floating events, where a secondary-zone
    /// reading doesn't apply — an all-day event has no clock time, and a floating event reads
    /// the same everywhere by definition.
    func startTime(displayedIn timeZoneIdentifier: String) -> String? {
        guard timeType == .timed, let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }

    /// This event's own time-of-day combined with a different calendar date — used when
    /// dragging an event to a different day in week view (BC-VIEW-012, spec 1.7), where only
    /// the date should change, never the time.
    func movedPreservingTimeOfDay(to newDate: Date, calendar: Calendar = .current) -> Date {
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: startDate)
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: newDate)
        targetComponents.hour = timeComponents.hour
        targetComponents.minute = timeComponents.minute
        targetComponents.second = timeComponents.second
        return calendar.date(from: targetComponents) ?? startDate
    }

    func durationComponents(in calendar: Calendar) -> DateComponents {
        if isAllDay {
            let start = calendar.startOfDay(for: startDate)
            let end = calendar.startOfDay(for: endDate)
            let dayCount = max(calendar.dateComponents([.day], from: start, to: end).day ?? 1, 1)
            return DateComponents(day: dayCount)
        }

        return calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: startDate, to: endDate)
    }

    private func formattedLocalDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

extension RecurrenceException {
    /// Whether this exception was recorded for the occurrence starting at `occurrenceStart`
    /// (BC-REC-010). Timed/floating events compare instants at whole-second granularity —
    /// the date was captured once when the exception was created and is now being compared
    /// against a freshly regenerated candidate; all-day events compare local calendar dates,
    /// matching how `CalendarEvent` itself splits instant vs. local-date storage.
    func matches(occurrenceStart: Date, event: CalendarEvent) -> Bool {
        if event.isAllDay {
            guard let originalOccurrenceLocalDate else { return false }
            return originalOccurrenceLocalDate == event.localDateString(for: occurrenceStart)
        }

        guard let originalOccurrenceStart else { return false }
        return abs(originalOccurrenceStart.timeIntervalSince(occurrenceStart)) < 1
    }
}

extension CalendarEvent {
    /// Builds a standalone "seed" event representing a single occurrence of this recurring
    /// series, ready to be handed to the editor and saved through the normal
    /// `saveEvent(from:)` path (BC-REC-010, "This Event" edit scope). Saving it either creates
    /// a new replacement (first edit of this occurrence) or updates the existing one (editing
    /// an already-modified occurrence again) — `saveEvent` looks the row up by `draft.id`, and
    /// the seed's freshly-minted id won't match any existing event the first time around.
    func seedForOccurrenceEdit(occurrenceStartDate: Date, occurrenceEndDate: Date) -> CalendarEvent {
        var seed = self
        seed.id = UUID()
        seed.startDate = occurrenceStartDate
        seed.endDate = occurrenceEndDate
        seed.recurrence = nil
        seed.recurrenceMasterID = id
        seed.recurrenceOriginalStart = occurrenceStartDate
        return seed
    }
}

extension RecurrenceRule {
    func includes(_ occurrenceStartDate: Date, occurrenceIndex: Int, event: CalendarEvent, calendar: Calendar) -> Bool {
        switch end {
        case .never:
            return true
        case .afterOccurrences(let count):
            return occurrenceIndex < count
        case .onDate(let endDate):
            if event.isAllDay {
                return LocalCalendarDate(date: occurrenceStartDate, calendar: calendar) <= LocalCalendarDate(date: endDate, calendar: calendar)
            }

            return occurrenceStartDate <= endDate
        }
    }
}

extension ReminderOffset {
    var notificationOffsetSeconds: TimeInterval? {
        switch self {
        case .none:
            nil
        case .atStart:
            0
        case .minutesBefore(let minutes):
            TimeInterval(-minutes * 60)
        case .daysBefore(let days):
            TimeInterval(-days * 24 * 60 * 60)
        }
    }
}
