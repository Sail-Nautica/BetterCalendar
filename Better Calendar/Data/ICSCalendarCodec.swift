import Foundation

enum ICSCalendarCodec {
    static func export(events: [CalendarEvent], calendars: [BetterCalendar]) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Better Calendar//Local MVP//EN"
        ]

        for event in events.sorted(by: { $0.startDate < $1.startDate }) {
            let calendarName = calendars.first(where: { $0.id == event.calendarID })?.name ?? "Better Calendar"
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id.uuidString)")
            lines.append("SUMMARY:\(escape(event.title))")
            lines.append("DTSTART:\(icsDate(event.startDate, isAllDay: event.isAllDay))")
            lines.append("DTEND:\(icsDate(event.endDate, isAllDay: event.isAllDay))")
            lines.append("CATEGORIES:\(escape(calendarName))")

            if let location = event.location {
                lines.append("LOCATION:\(escape(location))")
            }

            if let notes = event.notes {
                lines.append("DESCRIPTION:\(escape(notes))")
            }

            if let recurrence = event.recurrence, recurrence.frequency != .never {
                lines.append("RRULE:\(rrule(for: recurrence))")
            }

            lines.append("END:VEVENT")
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    static func importEvents(from text: String, defaultCalendarID: UUID?) -> ImportSummary {
        guard let defaultCalendarID else {
            return ImportSummary(importedCount: 0, skippedCount: 0, failedCount: 1, events: [])
        }

        let blocks = text.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        var imported: [CalendarEvent] = []
        var failedCount = 0
        let now = Date.now

        for block in blocks {
            let eventText = block.components(separatedBy: "END:VEVENT").first ?? block
            let fields = dictionary(from: eventText)

            guard let summary = fields["SUMMARY"], let startText = fields["DTSTART"] else {
                failedCount += 1
                continue
            }

            let isAllDay = startText.count == 8
            guard let startDate = parseDate(startText, isAllDay: isAllDay) else {
                failedCount += 1
                continue
            }

            let endDate = fields["DTEND"].flatMap { parseDate($0, isAllDay: isAllDay) } ?? startDate.addingTimeInterval(60 * 60)

            imported.append(
                CalendarEvent(
                    id: UUID(),
                    calendarID: defaultCalendarID,
                    title: unescape(summary),
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: isAllDay,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    location: fields["LOCATION"].map(unescape),
                    urlString: nil,
                    notes: fields["DESCRIPTION"].map(unescape),
                    reminders: [],
                    recurrence: nil,
                    providerMetadata: .local,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        return ImportSummary(importedCount: imported.count, skippedCount: 0, failedCount: failedCount, events: imported)
    }

    private static func dictionary(from eventText: String) -> [String: String] {
        var result: [String: String] = [:]

        for line in eventText.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let rawKey = String(line[..<separator])
            let key = rawKey.components(separatedBy: ";").first ?? rawKey
            let value = String(line[line.index(after: separator)...])
            result[key] = value
        }

        return result
    }

    private static func icsDate(_ date: Date, isAllDay: Bool) -> String {
        if isAllDay {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    nonisolated private static func parseDate(_ value: String, isAllDay: Bool) -> Date? {
        if isAllDay {
            return parseAllDayDate(value)
        }

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.calendar = Calendar(identifier: .gregorian)
        dateTimeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateTimeFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        return dateTimeFormatter.date(from: value)
    }

    nonisolated private static func parseAllDayDate(_ value: String) -> Date? {
        guard value.count == 8,
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func rrule(for recurrence: RecurrenceRule) -> String {
        var parts = ["FREQ=\(recurrence.frequency.rawValue.uppercased())"]
        if recurrence.interval > 1 {
            parts.append("INTERVAL=\(recurrence.interval)")
        }
        if !recurrence.weekdays.isEmpty {
            parts.append("BYDAY=\(recurrence.weekdays.sorted().map(icsWeekday).joined(separator: ","))")
        }
        return parts.joined(separator: ";")
    }

    nonisolated private static func icsWeekday(_ weekday: Weekday) -> String {
        switch weekday {
        case .sunday: "SU"
        case .monday: "MO"
        case .tuesday: "TU"
        case .wednesday: "WE"
        case .thursday: "TH"
        case .friday: "FR"
        case .saturday: "SA"
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    nonisolated private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
