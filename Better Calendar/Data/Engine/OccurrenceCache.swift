import Foundation

/// Spec 2.5: memoises `RecurrenceExpander` output per `(event id, visible range)`, so
/// `BetterCalendarStore.visibleOccurrences(in:)` doesn't re-run recurrence expansion for every
/// event on every call — today it does, from three `CalendarScreen` call sites and one
/// `AgendaScreen` call site, none of which store expanded occurrences themselves (spec 2.19).
///
/// Not `Domain/`: expansion itself is pure and lives in `RecurrenceExpander`; this only adds a
/// mutable cache in front of it, which is a `Data/`-layer concern (it holds transient state, not
/// business logic) even though it needs no GRDB or SwiftUI import.
final class OccurrenceCache {
    private struct RangeKey: Hashable {
        var start: Date
        var end: Date
    }

    /// Total cached range-entries across every event, as a cheap unbounded-growth guard. A
    /// calendar screen requests a new, slightly different padded range on essentially every
    /// scroll/navigation, so entries accumulate over a long session; this is not an LRU (that
    /// would need per-entry bookkeeping this cache doesn't otherwise want), just a circuit
    /// breaker that resets everything once the working set has clearly outgrown "the ranges the
    /// user is actually looking at."
    private static let maximumEntries = 512

    private var storage: [UUID: [RangeKey: [CalendarOccurrence]]] = [:]
    private var entryCount = 0
    private let expander: RecurrenceExpander

    init(expander: RecurrenceExpander = RecurrenceExpander()) {
        self.expander = expander
    }

    /// - Parameter exceptions: must be exactly the exceptions currently recorded for `event.id`.
    ///   The cache does not hash or store them — callers must invalidate `event.id` (via
    ///   `invalidate(masterID:)`) whenever they change, which `BetterCalendarStore` does for
    ///   every `EngineTransaction` it applies.
    func occurrences(of event: CalendarEvent, in range: DateInterval, exceptions: [RecurrenceException]) -> [CalendarOccurrence] {
        let key = RangeKey(start: range.start, end: range.end)
        if let cached = storage[event.id]?[key] {
            return cached
        }

        let computed = expander.occurrences(of: event, in: range, exceptions: exceptions)

        if entryCount >= Self.maximumEntries {
            invalidateAll()
        }
        storage[event.id, default: [:]][key] = computed
        entryCount += 1

        return computed
    }

    /// Drops every cached range for one event/series master, because something about it (its
    /// own fields, or an exception recorded against it) changed.
    func invalidate(masterID: UUID) {
        guard let removed = storage.removeValue(forKey: masterID) else { return }
        entryCount -= removed.count
    }

    func invalidateAll() {
        storage.removeAll()
        entryCount = 0
    }
}
