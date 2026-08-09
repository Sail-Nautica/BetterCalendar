import Foundation

/// RFC 5545 import/export (BC-ICS-001/002, spec 1.18/1.19). Independent of the store — the
/// store owns persistence, deduplication, and destination-calendar assignment; this type only
/// translates between `CalendarEvent`/`RecurrenceRule`/`RecurrenceException` and ICS text.
enum ICSCalendarCodec {
    // MARK: - Export

    static func export(events: [CalendarEvent], calendars: [BetterCalendar], recurrenceExceptions: [RecurrenceException] = []) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Better Calendar//Local MVP//EN"
        ]

        // Standalone per-occurrence replacement events (BC-REC-010) are emitted alongside
        // their master below, as a RECURRENCE-ID VEVENT sharing the master's UID — never as
        // their own independent top-level entry.
        for event in events.sorted(by: { $0.startDate < $1.startDate }) where event.recurrenceMasterID == nil {
            let cancelledDateStrings = recurrenceExceptions
                .filter { $0.masterEventID == event.id && $0.exceptionType == .cancelled }
                .compactMap { icsExceptionDateString(for: $0, isAllDay: event.isAllDay) }

            lines.append(contentsOf: veventLines(for: event, calendars: calendars, exceptionDateStrings: cancelledDateStrings))

            let modifiedExceptions = recurrenceExceptions.filter { $0.masterEventID == event.id && $0.exceptionType == .modified }
            for exception in modifiedExceptions {
                guard let replacementID = exception.replacementEventID,
                      let replacement = events.first(where: { $0.id == replacementID }),
                      let recurrenceIDString = icsExceptionDateString(for: exception, isAllDay: event.isAllDay) else {
                    continue
                }
                lines.append(contentsOf: veventLines(for: replacement, calendars: calendars, uidOverride: event.id.uuidString, recurrenceIDDateString: recurrenceIDString))
            }
        }

        lines.append("END:VCALENDAR")
        return foldLines(lines.joined(separator: "\r\n"))
    }

    private static func veventLines(
        for event: CalendarEvent,
        calendars: [BetterCalendar],
        uidOverride: String? = nil,
        recurrenceIDDateString: String? = nil,
        exceptionDateStrings: [String] = []
    ) -> [String] {
        let calendarName = calendars.first(where: { $0.id == event.calendarID })?.name ?? "Better Calendar"
        var lines = ["BEGIN:VEVENT"]
        lines.append("UID:\(uidOverride ?? event.id.uuidString)")
        lines.append("SUMMARY:\(escape(event.title))")

        if event.isFloating {
            // No trailing Z, no TZID param: RFC 5545's "floating time" is exactly Better
            // Calendar's floating semantic (same wall-clock time regardless of viewer zone).
            lines.append("DTSTART:\(floatingICSDate(event.startDate, timeZoneIdentifier: event.timeZoneIdentifier))")
            lines.append("DTEND:\(floatingICSDate(event.endDate, timeZoneIdentifier: event.timeZoneIdentifier))")
        } else {
            lines.append("DTSTART:\(icsDate(event.startDate, isAllDay: event.isAllDay))")
            lines.append("DTEND:\(icsDate(event.endDate, isAllDay: event.isAllDay))")
        }

        if let recurrenceIDDateString {
            lines.append("RECURRENCE-ID:\(recurrenceIDDateString)")
        }

        lines.append("CATEGORIES:\(escape(calendarName))")

        if let location = event.location {
            lines.append("LOCATION:\(escape(location))")
        }
        if let notes = event.notes {
            lines.append("DESCRIPTION:\(escape(notes))")
        }
        if let urlString = event.urlString {
            lines.append("URL:\(escape(urlString))")
        }

        if let recurrence = event.recurrence, recurrence.frequency != .never {
            lines.append("RRULE:\(rrule(for: recurrence, event: event))")
        }

        for dateString in exceptionDateStrings {
            lines.append("EXDATE:\(dateString)")
        }

        lines.append(contentsOf: valarmLines(for: event.reminders))
        lines.append("END:VEVENT")
        return lines
    }

    private static func valarmLines(for reminders: [EventReminder]) -> [String] {
        reminders.compactMap { reminder -> [String]? in
            guard let trigger = icsTriggerDuration(for: reminder.offset) else { return nil }
            return ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:\(trigger)", "END:VALARM"]
        }.flatMap { $0 }
    }

    /// RFC 5545 §3.1: lines SHOULD be folded at 75 octets by inserting a CRLF + single space
    /// before the excess portion, repeated as needed. Character-boundary-safe: a multi-byte
    /// UTF-8 character is never split across a fold.
    static func foldLines(_ text: String) -> String {
        text.components(separatedBy: "\r\n").map(foldLine).joined(separator: "\r\n")
    }

    private static func foldLine(_ line: String) -> String {
        let maxOctets = 75
        var result = ""
        var lineOctets = 0

        for character in line {
            let characterOctets = String(character).utf8.count
            if lineOctets + characterOctets > maxOctets {
                result += "\r\n "
                lineOctets = 1
            }
            result.append(character)
            lineOctets += characterOctets
        }
        return result
    }

    // MARK: - Import

    static func importEvents(from text: String, defaultCalendarID: UUID?) -> ImportSummary {
        guard let defaultCalendarID else {
            return ImportSummary(importedCount: 0, skippedCount: 0, failedCount: 1, events: [])
        }

        let blocks = extractBlocks(from: unfoldLines(text), beginTag: "BEGIN:VEVENT", endTag: "END:VEVENT")
        let now = Date.now

        var masterBlocks: [(properties: [ICSProperty], valarms: [[ICSProperty]])] = []
        var overrideBlocks: [(properties: [ICSProperty], valarms: [[ICSProperty]])] = []

        for block in blocks {
            let properties = self.properties(from: block, excludingNestedComponents: true)
            let valarms = extractBlocks(from: block, beginTag: "BEGIN:VALARM", endTag: "END:VALARM")
                .map { self.properties(from: $0, excludingNestedComponents: true) }

            if properties.contains(where: { $0.name == "RECURRENCE-ID" }) {
                overrideBlocks.append((properties, valarms))
            } else {
                masterBlocks.append((properties, valarms))
            }
        }

        var failedCount = 0
        var masters: [UUID: CalendarEvent] = [:]
        var mastersByUID: [String: UUID] = [:]
        var events: [CalendarEvent] = []
        var exceptions: [RecurrenceException] = []

        for (properties, valarms) in masterBlocks {
            guard let event = buildEvent(id: UUID(), calendarID: defaultCalendarID, properties: properties, valarms: valarms, now: now) else {
                failedCount += 1
                continue
            }
            masters[event.id] = event
            if let uid = properties.first(where: { $0.name == "UID" })?.value {
                mastersByUID[uid] = event.id
            }
            events.append(event)

            // EXDATE can repeat and/or carry comma-separated values in a single property.
            for exdateProperty in properties.filter({ $0.name == "EXDATE" }) {
                for token in exdateProperty.value.components(separatedBy: ",") {
                    let trimmedToken = token.trimmingCharacters(in: .whitespaces)
                    let isAllDay = trimmedToken.count == 8
                    guard let date = parseDate(trimmedToken, isAllDay: isAllDay) else { continue }
                    exceptions.append(
                        RecurrenceException(
                            id: UUID(),
                            masterEventID: event.id,
                            originalOccurrenceStart: isAllDay ? nil : date,
                            originalOccurrenceLocalDate: isAllDay ? localDateString(date) : nil,
                            exceptionType: .cancelled,
                            replacementEventID: nil
                        )
                    )
                }
            }
        }

        for (properties, valarms) in overrideBlocks {
            guard let uid = properties.first(where: { $0.name == "UID" })?.value,
                  let masterID = mastersByUID[uid],
                  masters[masterID] != nil,
                  let recurrenceIDProperty = properties.first(where: { $0.name == "RECURRENCE-ID" }) else {
                failedCount += 1
                continue
            }

            let isAllDay = recurrenceIDProperty.value.count == 8
            guard let originalStart = parseDate(recurrenceIDProperty.value, isAllDay: isAllDay),
                  var replacement = buildEvent(id: UUID(), calendarID: defaultCalendarID, properties: properties, valarms: valarms, now: now) else {
                failedCount += 1
                continue
            }

            replacement.recurrence = nil
            replacement.recurrenceMasterID = masterID
            replacement.recurrenceOriginalStart = originalStart

            events.append(replacement)
            exceptions.append(
                RecurrenceException(
                    id: UUID(),
                    masterEventID: masterID,
                    originalOccurrenceStart: isAllDay ? nil : originalStart,
                    originalOccurrenceLocalDate: isAllDay ? localDateString(originalStart) : nil,
                    exceptionType: .modified,
                    replacementEventID: replacement.id
                )
            )
        }

        return ImportSummary(importedCount: events.count, skippedCount: 0, failedCount: failedCount, events: events, recurrenceExceptions: exceptions)
    }

    private static func buildEvent(id: UUID, calendarID: UUID, properties: [ICSProperty], valarms: [[ICSProperty]], now: Date) -> CalendarEvent? {
        guard let summary = properties.first(where: { $0.name == "SUMMARY" }),
              let startProperty = properties.first(where: { $0.name == "DTSTART" }) else {
            return nil
        }

        let isAllDay = startProperty.value.count == 8
        guard let startDate = parseDate(startProperty.value, isAllDay: isAllDay) else { return nil }

        // Honor an explicit TZID when it resolves to a known zone; an unresolvable or absent
        // TZID falls back to the device's current zone rather than failing the whole import.
        let timeZoneIdentifier = startProperty.params["TZID"].flatMap { TimeZone(identifier: $0)?.identifier } ?? TimeZone.current.identifier

        let endDate: Date
        if let endProperty = properties.first(where: { $0.name == "DTEND" }), let parsedEnd = parseDate(endProperty.value, isAllDay: isAllDay) {
            endDate = parsedEnd
        } else if let durationProperty = properties.first(where: { $0.name == "DURATION" }), let seconds = parseISO8601Duration(durationProperty.value) {
            endDate = startDate.addingTimeInterval(seconds)
        } else {
            endDate = startDate.addingTimeInterval(60 * 60)
        }

        let recurrence = properties.first(where: { $0.name == "RRULE" }).flatMap { parseRRule($0.value) }

        let reminders: [EventReminder] = valarms.compactMap { alarmProperties in
            guard let trigger = alarmProperties.first(where: { $0.name == "TRIGGER" }),
                  let seconds = parseISO8601Duration(trigger.value) else { return nil }
            return EventReminder(id: UUID(), offset: reminderOffset(fromTriggerSeconds: Int(seconds.rounded())))
        }

        var provider = ProviderMetadata.local
        provider.providerObjectID = properties.first(where: { $0.name == "UID" })?.value
        provider.rawICSProperties = rawText(for: properties)

        return CalendarEvent(
            id: id,
            calendarID: calendarID,
            title: unescape(summary.value),
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            location: properties.first(where: { $0.name == "LOCATION" }).map { unescape($0.value) },
            urlString: properties.first(where: { $0.name == "URL" }).map { unescape($0.value) },
            notes: properties.first(where: { $0.name == "DESCRIPTION" }).map { unescape($0.value) },
            reminders: reminders,
            recurrence: recurrence,
            providerMetadata: provider,
            createdAt: now,
            updatedAt: now
        )
    }

    // This block doesn't carry its own nested VALARM sub-blocks (those were dropped by
    // `properties(from:excludingNestedComponents:)`), so unrecognized-property preservation is
    // a best-effort reconstruction of the top-level property lines, not a byte-exact original.
    private static func rawText(for properties: [ICSProperty]) -> String {
        properties.map { property in
            let paramText = property.params.isEmpty ? "" : ";" + property.params.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            return "\(property.name)\(paramText):\(property.value)"
        }.joined(separator: "\n")
    }

    // MARK: - Line unfolding

    /// RFC 5545 §3.1: a folded continuation line starts with a single space or tab immediately
    /// after the line break. Handles both CRLF and bare-LF inputs leniently, since not every
    /// real-world producer folds strictly per spec.
    static func unfoldLines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
    }

    // MARK: - Block/property parsing

    private struct ICSProperty {
        let name: String
        let params: [String: String]
        let value: String
    }

    /// Every `BEGIN:tag`…`END:tag` block in `text`, matched sequentially (so nested blocks
    /// using a different tag, like VALARM inside VEVENT, don't confuse the search).
    private static func extractBlocks(from text: String, beginTag: String, endTag: String) -> [String] {
        var blocks: [String] = []
        var searchStart = text.startIndex

        while let beginRange = text.range(of: beginTag, range: searchStart..<text.endIndex) {
            guard let endRange = text.range(of: endTag, range: beginRange.upperBound..<text.endIndex) else { break }
            blocks.append(String(text[beginRange.upperBound..<endRange.lowerBound]))
            searchStart = endRange.upperBound
        }
        return blocks
    }

    private static func properties(from block: String, excludingNestedComponents: Bool) -> [ICSProperty] {
        var result: [ICSProperty] = []
        var nestingDepth = 0

        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if excludingNestedComponents {
                if line.hasPrefix("BEGIN:") {
                    nestingDepth += 1
                    continue
                }
                if line.hasPrefix("END:") {
                    nestingDepth -= 1
                    continue
                }
                guard nestingDepth == 0 else { continue }
            }

            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let namePart = String(line[..<colonIndex])
            let value = String(line[line.index(after: colonIndex)...])

            let nameComponents = namePart.components(separatedBy: ";")
            let name = (nameComponents.first ?? namePart).uppercased()
            var params: [String: String] = [:]
            for paramString in nameComponents.dropFirst() {
                let paramParts = paramString.split(separator: "=", maxSplits: 1).map(String.init)
                if paramParts.count == 2 {
                    params[paramParts[0].uppercased()] = paramParts[1]
                }
            }
            result.append(ICSProperty(name: name, params: params, value: value))
        }
        return result
    }

    // MARK: - Dates

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

    private static func floatingICSDate(_ date: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private static func icsExceptionDateString(for exception: RecurrenceException, isAllDay: Bool) -> String? {
        if isAllDay, let localDate = exception.originalOccurrenceLocalDate {
            return localDate.replacingOccurrences(of: "-", with: "")
        }
        if let instant = exception.originalOccurrenceStart {
            return icsDate(instant, isAllDay: false)
        }
        return nil
    }

    nonisolated private static func parseDate(_ value: String, isAllDay: Bool) -> Date? {
        if isAllDay {
            return parseAllDayDate(value)
        }

        // Accept both a trailing 'Z' (UTC) and a bare local-time DATE-TIME (floating time, no
        // designator) — the latter is what this codec's own floating-event export produces.
        let utcFormatter = DateFormatter()
        utcFormatter.calendar = Calendar(identifier: .gregorian)
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        if let date = utcFormatter.date(from: value) {
            return date
        }

        let floatingFormatter = DateFormatter()
        floatingFormatter.calendar = Calendar(identifier: .gregorian)
        floatingFormatter.timeZone = .current
        floatingFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return floatingFormatter.date(from: value)
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

    private static func localDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }

    // MARK: - RRULE

    private static func rrule(for recurrence: RecurrenceRule, event: CalendarEvent) -> String {
        var parts = ["FREQ=\(recurrence.frequency.rawValue.uppercased())"]
        if recurrence.interval > 1 {
            parts.append("INTERVAL=\(recurrence.interval)")
        }

        if !recurrence.setPositions.isEmpty, !recurrence.weekdays.isEmpty {
            // Positional rule: fold the position into each BYDAY token (RFC 5545 §3.3.10),
            // e.g. "the last Friday" = BYDAY=-1FR.
            let byDayTokens = recurrence.setPositions.flatMap { position in
                recurrence.weekdays.sorted().map { "\(position)\(icsWeekday($0))" }
            }
            parts.append("BYDAY=\(byDayTokens.joined(separator: ","))")
        } else if !recurrence.daysOfMonth.isEmpty {
            parts.append("BYMONTHDAY=\(recurrence.daysOfMonth.sorted().map(String.init).joined(separator: ","))")
        } else if !recurrence.weekdays.isEmpty {
            parts.append("BYDAY=\(recurrence.weekdays.sorted().map(icsWeekday).joined(separator: ","))")
        }

        switch recurrence.end {
        case .never:
            break
        case .afterOccurrences(let count):
            parts.append("COUNT=\(count)")
        case .onDate(let date):
            parts.append("UNTIL=\(icsDate(date, isAllDay: event.isAllDay))")
        }

        return parts.joined(separator: ";")
    }

    private static func parseRRule(_ value: String) -> RecurrenceRule? {
        var frequency: RecurrenceFrequency?
        var interval = 1
        var weekdays: Set<Weekday> = []
        var daysOfMonth: [Int] = []
        var setPositions: [Int] = []
        var end: RecurrenceEnd = .never

        for pair in value.components(separatedBy: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].uppercased()
            let rawValue = parts[1]

            switch key {
            case "FREQ":
                frequency = RecurrenceFrequency(rawValue: rawValue.lowercased())
            case "INTERVAL":
                interval = Int(rawValue) ?? 1
            case "BYDAY":
                for token in rawValue.components(separatedBy: ",") {
                    let (ordinal, code) = splitOrdinalWeekday(token)
                    if let weekday = Weekday(icsCode: code) {
                        weekdays.insert(weekday)
                    }
                    if let ordinal, !setPositions.contains(ordinal) {
                        setPositions.append(ordinal)
                    }
                }
            case "BYMONTHDAY":
                daysOfMonth = rawValue.components(separatedBy: ",").compactMap { Int($0) }
            case "BYSETPOS":
                setPositions = rawValue.components(separatedBy: ",").compactMap { Int($0) }
            case "COUNT":
                if let count = Int(rawValue) { end = .afterOccurrences(count) }
            case "UNTIL":
                let isAllDayUntil = rawValue.count == 8
                if let date = parseDate(rawValue, isAllDay: isAllDayUntil) {
                    end = .onDate(date)
                }
            default:
                break
            }
        }

        guard let frequency, frequency != .never else { return nil }
        return RecurrenceRule(frequency: frequency, interval: max(interval, 1), weekdays: weekdays, daysOfMonth: daysOfMonth, setPositions: setPositions, end: end)
    }

    private static func splitOrdinalWeekday(_ token: String) -> (ordinal: Int?, code: String) {
        var chars = Substring(token)
        var sign = 1
        if chars.hasPrefix("-") {
            sign = -1
            chars = chars.dropFirst()
        } else if chars.hasPrefix("+") {
            chars = chars.dropFirst()
        }

        var digits = ""
        while let first = chars.first, first.isNumber {
            digits.append(first)
            chars = chars.dropFirst()
        }
        let code = String(chars)
        guard let number = Int(digits) else { return (nil, code) }
        return (number * sign, code)
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

    // MARK: - Durations (VALARM TRIGGER, DTEND fallback)

    /// A permissive subset of ISO 8601 durations as used by RFC 5545 (e.g. `-PT10M`, `P1D`,
    /// `PT0S`). `M` means minutes after `T` and months before it — VALARM/DURATION values in
    /// practice are always day/hour/minute/second, so the month case is a rough approximation.
    private static func parseISO8601Duration(_ value: String) -> TimeInterval? {
        var remaining = Substring(value)
        var sign: Double = 1
        if remaining.hasPrefix("-") {
            sign = -1
            remaining = remaining.dropFirst()
        } else if remaining.hasPrefix("+") {
            remaining = remaining.dropFirst()
        }
        guard remaining.hasPrefix("P") else { return nil }
        remaining = remaining.dropFirst()

        var totalSeconds: Double = 0
        var inTimePart = false
        var numberBuffer = ""

        for character in remaining {
            if character == "T" {
                inTimePart = true
                continue
            }
            if character.isNumber {
                numberBuffer.append(character)
                continue
            }
            guard let number = Double(numberBuffer) else { return nil }
            numberBuffer = ""
            switch character {
            case "W": totalSeconds += number * 7 * 24 * 60 * 60
            case "D": totalSeconds += number * 24 * 60 * 60
            case "H": totalSeconds += number * 60 * 60
            case "M": totalSeconds += inTimePart ? number * 60 : number * 30 * 24 * 60 * 60
            case "S": totalSeconds += number
            default: return nil
            }
        }

        return sign * totalSeconds
    }

    private static func reminderOffset(fromTriggerSeconds seconds: Int) -> ReminderOffset {
        switch seconds {
        case 0:
            return .atStart
        case let s where s < 0 && s % (24 * 60 * 60) == 0:
            return .daysBefore(abs(s) / (24 * 60 * 60))
        case let s where s < 0 && s % 60 == 0:
            return .minutesBefore(abs(s) / 60)
        default:
            let minutes = max(Int((-Double(seconds) / 60).rounded()), 0)
            return minutes == 0 ? .atStart : .minutesBefore(minutes)
        }
    }

    private static func icsTriggerDuration(for offset: ReminderOffset) -> String? {
        switch offset {
        case .none: nil
        case .atStart: "PT0S"
        case .minutesBefore(let minutes): "-PT\(minutes)M"
        case .daysBefore(let days): "-P\(days)D"
        }
    }

    // MARK: - Escaping

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

private extension Weekday {
    init?(icsCode: String) {
        switch icsCode.uppercased() {
        case "SU": self = .sunday
        case "MO": self = .monday
        case "TU": self = .tuesday
        case "WE": self = .wednesday
        case "TH": self = .thursday
        case "FR": self = .friday
        case "SA": self = .saturday
        default: return nil
        }
    }
}
