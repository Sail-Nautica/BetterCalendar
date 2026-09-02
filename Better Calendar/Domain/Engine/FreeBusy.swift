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
        /// Reserved. Phase 2 has no attendee model (spec 2.0 explicitly excludes attendees and
        /// invitations) and `EventAvailability` is only `.busy`/`.free` — there is no tentative
        /// state to include or exclude yet, so this parameter is currently a no-op. Kept on the
        /// query shape now rather than added later, so Phase 3/4 (which do add attendees) don't
        /// have to change every call site — only this function's body.
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

        let relevantEvents = events.filter { event in
            event.availability == .busy && (query.calendarIDs?.contains(event.calendarID) ?? true)
        }

        var intervals: [DateInterval] = []
        for event in relevantEvents {
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
