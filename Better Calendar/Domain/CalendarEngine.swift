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

    func occurrences(of event: CalendarEvent, in visibleRange: DateInterval) -> [CalendarOccurrence] {
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
            return AnySequence(monthlyDates(startingAt: event.startDate, interval: max(recurrence.interval, 1), calendar: calendar))
        case .yearly:
            return AnySequence(yearlyDates(startingAt: event.startDate, interval: max(recurrence.interval, 1), calendar: calendar))
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

    private func monthlyDates(startingAt startDate: Date, interval: Int, calendar: Calendar) -> AnySequence<Date> {
        let originalComponents = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: startDate)
        let day = originalComponents.day ?? 1
        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate

        return AnySequence(sequence(state: 0) { monthOffset in
            defer { monthOffset += interval }
            guard let targetMonthStart = calendar.date(byAdding: .month, value: monthOffset, to: monthStart) else {
                return nil
            }

            return clampedDate(
                inMonthContaining: targetMonthStart,
                day: day,
                timeComponents: originalComponents,
                calendar: calendar
            )
        })
    }

    private func yearlyDates(startingAt startDate: Date, interval: Int, calendar: Calendar) -> AnySequence<Date> {
        let originalComponents = calendar.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: startDate)
        let month = originalComponents.month ?? 1
        let day = originalComponents.day ?? 1
        let year = calendar.component(.year, from: startDate)

        return AnySequence(sequence(state: 0) { yearOffset in
            defer { yearOffset += interval }

            var components = DateComponents()
            components.year = year + yearOffset
            components.month = month
            components.day = 1
            components.hour = originalComponents.hour
            components.minute = originalComponents.minute
            components.second = originalComponents.second
            components.nanosecond = originalComponents.nanosecond

            guard let monthStart = calendar.date(from: components) else {
                return nil
            }

            return clampedDate(
                inMonthContaining: monthStart,
                day: day,
                timeComponents: originalComponents,
                calendar: calendar
            )
        })
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

    func intersects(_ interval: DateInterval) -> Bool {
        startDate < interval.end && endDate > interval.start
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
