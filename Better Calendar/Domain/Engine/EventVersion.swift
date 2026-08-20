import Foundation

/// Spec 2.9: a full-snapshot version row, written on every committed event update — whether or
/// not a provider is ever connected. Reuses `CalendarEvent.encodedSnapshotJSON()`, the same
/// serialisation the tombstone snapshot path already proved (spec 0.12).
struct EventVersion: Identifiable, Equatable {
    var id: UUID
    var eventID: UUID
    var versionNumber: Int
    var snapshotJSON: String
    var createdAt: Date
    var changeJournalEntryID: UUID
}
