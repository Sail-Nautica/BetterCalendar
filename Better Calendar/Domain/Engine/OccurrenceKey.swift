import Foundation

/// Spec 2.3: a stable identity for one occurrence of a recurring series — the master event's id
/// paired with that occurrence's original start instant. `RecurrenceException` and
/// `CalendarEvent.recurrenceMasterID`/`recurrenceOriginalStart` already identify a single slot
/// this same way (`existingReplacementEvent(forOccurrenceOf:occurrenceStartDate:)` in
/// `LocalCalendarStore` compares the same two fields directly) — this type formalises the pair
/// so `RecurrenceSplitter` has one thing to pass around instead of two loose arguments.
struct OccurrenceKey: Hashable {
    var recurrenceMasterID: UUID
    var originalStart: Date
}

/// Spec 2.3/2.4: which occurrences of a recurring series a create/update/delete applies to
/// (BC-REC-010's "This Event"/"All Events" dialog choice, generalized with the middle option
/// spec 1.11 always described but Phase 1 never implemented).
///
/// `.thisAndFuture` was engine-API only in Phase 2 — `RecurrenceSplitter` implemented and tested
/// it fully, with deliberately no third button on `EventDetailsView`'s confirmation dialog
/// (`Instructions/phase2plan.md`'s M4 section), because the split logic should ship ready to wire
/// up rather than be built twice. Phase 3D wires it up: spec 3.20 gives the scope a device
/// meaning (a future-span write, which EventKit splits for itself), which is the provider that
/// justified the complexity.
enum EditScope: String, Codable, Hashable, CaseIterable {
    /// Only the single selected occurrence. Leaves the master and every other occurrence
    /// untouched — today's "This Event" behavior (BC-REC-010).
    case thisEventOnly
    /// The selected occurrence and every later one. Splits the series in two: the original
    /// master is truncated to end immediately before the selected occurrence, and a new master
    /// (a new entity, its own id) takes over the pattern from there (BC-ENG-002).
    case thisAndFuture
    /// The entire series, including occurrences before the selected one. Updates (or deletes)
    /// the master directly — today's "All Events" behavior (BC-ENG-001).
    case allEvents
}
