import Foundation

/// Spec 2.7 (BC-ENG-004): free/busy computation over a date range. Unlike `ConflictIndex`, this
/// is a stateless query, not a maintained structure — free/busy is always asked over some
/// caller-chosen range, so there is no meaningful "incremental" shape to maintain between calls.
///
/// No `Features/` consumer exists in Phase 2 (spec 2.7: "this API has no UI ... it exists so
/// Phase 11 (scheduling pages) and Phase 12 (intelligence) can be built without touching the
/// event engine again").
enum FreeBusy {
    struct Query {
        var rangeStart: Date
        var rangeEnd: Date
        /// `nil` means every calendar.
        var calendarIDs: Set<UUID>?
        /// Whether an event the user is only tentatively committed to contributes busy time.
        ///
        /// A no-op through Phase 2, which had no attendee model and no event status to read
        /// (ADR 0002). Phase 3C supplies both, so this now does what its name says: when `false`,
        /// an event whose *status* is tentative, or on which the current user answered "maybe",
        /// stops occupying time. Cancelled and declined events are excluded either way — those
        /// are not tentative commitments, they are not commitments.
        var includeTentative: Bool = true

        init(rangeStart: Date, rangeEnd: Date, calendarIDs: Set<UUID>? = nil, includeTentative: Bool = true) {
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
            self.calendarIDs = calendarIDs
            self.includeTentative = includeTentative
        }
    }

    /// Merged busy intervals within `query.rangeStart..<query.rangeEnd`, collapsing overlapping
    /// *and adjacent* runs into as few intervals as possible.
    ///
    /// Recurring events are expanded via `RecurrenceExpander` over the query range — free/busy
    /// has to answer "is next Monday at 2pm busy" correctly for a weekly series with no exception
    /// anywhere near that date, so (unlike `ConflictIndex`, see its own doc comment) this cannot
    /// operate on masters' own stored `startDate`/`endDate` alone.
    ///
    /// `.cancelled` and `.modified`-without-a-still-busy-replacement occurrences are excluded
    /// automatically: `RecurrenceExpander` already skips any slot with an exception (both
    /// `.cancelled` and `.modified` are excluded from the master's own expansion — see
    /// `RecurrenceSplitter`'s doc comment on the point), and a `.modified` occurrence's
    /// standalone replacement event is walked in its own right as a plain (non-recurring) event,
    /// so it contributes exactly when *it* is `.busy`.
    static func query(_ query: Query, events: [CalendarEvent], exceptions: [RecurrenceException]) -> [DateInterval] {
        guard query.rangeStart < query.rangeEnd else { return [] }
        let range = DateInterval(start: query.rangeStart, end: query.rangeEnd)
        let expander = RecurrenceExpander()

        // Spec 3C.5: `occupiesTime` folds three questions into one — is this event marked busy,
        // is it still on, and did the user actually say yes. A cancelled meeting and one the user
        // declined are both information, not commitments, and neither makes them unavailable.
        let relevantEvents = events.filter { event in
            event.occupiesTime(includeTentative: query.includeTentative)
                && (query.calendarIDs?.contains(event.calendarID) ?? true)
        }

        var intervals: [DateInterval] = []
        for event in relevantEvents {
            guard couldIntersect(event, range: range) else { continue }
            let eventExceptions = exceptions.filter { $0.masterEventID == event.id }
            for occurrence in expander.occurrences(of: event, in: range, exceptions: eventExceptions) {
                let start = max(occurrence.occurrenceStartDate, range.start)
                let end = min(occurrence.occurrenceEndDate, range.end)
                guard start < end else { continue }
                intervals.append(DateInterval(start: start, end: end))
            }
        }

        return merge(intervals)
    }

    /// Spec 2.19: a cheap, conservative pre-filter so a query over a narrow range doesn't pay
    /// `RecurrenceExpander`'s full per-occurrence `Calendar` arithmetic for a series that cannot
    /// possibly land in `range` — a long-lived calendar accumulates plenty of finished
    /// short-lived series (an old 10-occurrence standup rotation, say), and without this,
    /// *every* one of them gets walked occurrence-by-occurrence from its own start regardless of
    /// how far that is from `range`.
    ///
    /// `latestPossibleOccurrenceEnd(of:)` always over-estimates (never under-estimates) a
    /// bounded series' true last occurrence, so this can only ever skip a series that provably
    /// cannot intersect `range` — it never skips one that might.
    private static func couldIntersect(_ event: CalendarEvent, range: DateInterval) -> Bool {
        guard event.startDate < range.end else { return false }
        guard let recurrence = event.recurrence, recurrence.frequency != .never else {
            return event.endDate > range.start
        }
        guard let latestEnd = latestPossibleOccurrenceEnd(of: event, recurrence: recurrence) else {
            return true // `.never`-ending: unbounded going forward, cannot be ruled out this way.
        }
        return latestEnd > range.start
    }

    /// `nil` means "unbounded" (`.never`). Otherwise a safe upper bound on the instant the
    /// series' last possible occurrence ends — computed from the loosest interpretation of the
    /// rule's own fields (see inline reasoning per case), never from actually expanding it.
    private static func latestPossibleOccurrenceEnd(of event: CalendarEvent, recurrence: RecurrenceRule) -> Date? {
        switch recurrence.end {
        case .never:
            return nil
        case .onDate(let endDate):
            return endDate.addingTimeInterval(event.duration)
        case .afterOccurrences(let count):
            // An upper bound on the spacing between the 1st and Nth occurrence, using the
            // longest each frequency's own step can possibly span (a 31-day month, a 366-day
            // leap year) — multiple weekdays/month-days per step only make the true series
            // *shorter* than this, never longer, so this always over-, never under-, estimates.
            let stepSeconds: TimeInterval
            switch recurrence.frequency {
            case .never: return event.startDate.addingTimeInterval(event.duration)
            case .daily: stepSeconds = 86_400
            case .weekly: stepSeconds = 7 * 86_400
            case .monthly: stepSeconds = 31 * 86_400
            case .yearly: stepSeconds = 366 * 86_400
            }
            let span = stepSeconds * Double(max(recurrence.interval, 1)) * Double(max(count - 1, 0))
            return event.startDate.addingTimeInterval(span + event.duration)
        }
    }

    private static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }

        var merged: [DateInterval] = [sorted[0]]
        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.start <= last.end {
                if interval.end > last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
