import Foundation

/// Spec 2.6 (BC-ENG-003): a sorted-interval structure over `[startInstant, endInstant)` for
/// `availability == .busy` events, so a conflict check never needs a full table scan.
///
/// Two events conflict when their intervals overlap and both are `.busy`. Timed events are
/// compared as UTC instants; all-day events are compared as `LocalCalendarDate` ranges against
/// other all-day events only — an all-day event never conflicts with a timed one (CLAUDE.md:
/// all-day compares local calendar dates, never UTC instants, and this default is deliberately
/// narrow rather than assumed — see spec 2.6).
///
/// Kept in `Domain/`, unlike `OccurrenceCache`: this type *is* the conflict rule (business
/// logic), not a memoisation layer in front of an already-pure function elsewhere.
final class ConflictIndex {
    private struct TimedEntry {
        var eventID: UUID
        var start: Date
        var end: Date
    }

    private struct AllDayEntry {
        var eventID: UUID
        var start: LocalCalendarDate
        var end: LocalCalendarDate
    }

    /// Sorted ascending by `start`, so a query can binary-search to its first possibly-overlapping
    /// entry and stop scanning the moment an entry's `start` reaches the query's end — no entry
    /// beyond that point can overlap a half-open interval.
    private var timedEntries: [TimedEntry] = []
    private var allDayEntries: [AllDayEntry] = []
    /// Which array (and at what index, kept valid by every insert/remove going through the two
    /// helpers below) each currently-indexed busy event lives in, so `reindex`/`remove` don't need
    /// to guess an event's shape from data the caller may no longer have.
    private var kindByID: [UUID: Bool] = [:] // true = all-day

    init() {}

    convenience init(events: [CalendarEvent]) {
        self.init()
        for event in events {
            insert(event)
        }
    }

    /// Every event id currently indexed as conflicting with `eventID` — i.e. overlapping and
    /// both `.busy`. Empty (rather than the event's own id) when the event isn't indexed as busy.
    func conflicts(for eventID: UUID) -> Set<UUID> {
        guard let isAllDay = kindByID[eventID] else { return [] }
        if isAllDay {
            guard let entry = allDayEntries.first(where: { $0.eventID == eventID }) else { return [] }
            return Set(overlappingAllDayIDs(start: entry.start, end: entry.end, excluding: eventID))
        } else {
            guard let entry = timedEntries.first(where: { $0.eventID == eventID }) else { return [] }
            return Set(overlappingTimedIDs(start: entry.start, end: entry.end, excluding: eventID))
        }
    }

    /// Removes `previous` from the index (if it was indexed) and inserts `next` (if given),
    /// returning every *other* event id whose conflict status may have changed as a result —
    /// every event that overlapped `previous`'s old range, overlaps `next`'s new range, or both.
    /// The caller re-derives conflicts only for that set rather than the whole calendar (spec
    /// 2.19); the moved event's own fresh conflicts are `conflicts(for: next.id)`, since
    /// `conflicts(for:)` always excludes the event being queried for from its own result.
    @discardableResult
    func reindex(movedFrom previous: CalendarEvent?, to next: CalendarEvent?) -> Set<UUID> {
        var affected: Set<UUID> = []

        if let previous {
            affected.formUnion(conflicts(for: previous.id))
            remove(previous.id)
        }
        if let next {
            insert(next)
            affected.formUnion(conflicts(for: next.id))
        }

        return affected
    }

    /// Rebuilds the entire index from scratch — used only where a full replacement already
    /// happened elsewhere (initial load, bulk import), never from an incremental mutation path.
    func rebuild(from events: [CalendarEvent]) {
        timedEntries.removeAll()
        allDayEntries.removeAll()
        kindByID.removeAll()
        for event in events {
            insert(event)
        }
    }

    // MARK: - Mutation

    private func insert(_ event: CalendarEvent) {
        guard event.availability == .busy else { return }

        if event.isAllDay {
            let calendar = event.calendarInOriginalTimeZone
            let entry = AllDayEntry(
                eventID: event.id,
                start: LocalCalendarDate(date: event.startDate, calendar: calendar),
                end: LocalCalendarDate(date: event.endDate, calendar: calendar)
            )
            let index = allDayEntries.firstIndex { entry.start < $0.start } ?? allDayEntries.count
            allDayEntries.insert(entry, at: index)
            kindByID[event.id] = true
        } else {
            let entry = TimedEntry(eventID: event.id, start: event.startDate, end: event.endDate)
            let index = timedEntries.firstIndex { entry.start < $0.start } ?? timedEntries.count
            timedEntries.insert(entry, at: index)
            kindByID[event.id] = false
        }
    }

    private func remove(_ eventID: UUID) {
        guard let isAllDay = kindByID.removeValue(forKey: eventID) else { return }
        if isAllDay {
            allDayEntries.removeAll { $0.eventID == eventID }
        } else {
            timedEntries.removeAll { $0.eventID == eventID }
        }
    }

    // MARK: - Queries

    private func overlappingTimedIDs(start: Date, end: Date, excluding excludedID: UUID) -> [UUID] {
        // Sorted by start: no entry at or past `end` can overlap `[start, end)`, so scanning stops
        // the moment that boundary is crossed rather than walking the rest of the array.
        var result: [UUID] = []
        for entry in timedEntries {
            if entry.start >= end { break }
            if entry.eventID == excludedID { continue }
            if entry.end > start {
                result.append(entry.eventID)
            }
        }
        return result
    }

    private func overlappingAllDayIDs(start: LocalCalendarDate, end: LocalCalendarDate, excluding excludedID: UUID) -> [UUID] {
        var result: [UUID] = []
        for entry in allDayEntries {
            if !(entry.start < end) { break }
            if entry.eventID == excludedID { continue }
            if entry.end > start {
                result.append(entry.eventID)
            }
        }
        return result
    }
}
