import Foundation

/// Spec 2.8: the append-only history of every entity-level change, independent of whether a
/// provider is ever attached. `EngineTransaction.journalEntries` carries these; the SQLite
/// consumer inserts them into `change_journal` and never updates or deletes a row afterward —
/// corrections are made by writing a new entry, never by editing this one.
struct ChangeJournalEntry: Identifiable, Equatable {
    var id: UUID
    var entityType: EngineEntityType
    var entityID: UUID
    var operation: JournalOperation
    /// Before/after JSON for only the fields that changed, from `FieldDiff.compute(from:to:)`.
    /// `nil` for a create (nothing to diff against) or when the caller has no prior value.
    var fieldDiff: String?
    var source: JournalSource
    var occurredAt: Date
    /// Links back to the outbox row that carried this change, once applied (spec 2.10). `nil`
    /// until the mutation processor marks the corresponding `PendingMutation` applied.
    var appliedMutationID: UUID?
}

enum JournalOperation: String, Codable, Hashable, CaseIterable {
    case create
    case update
    case delete
}

/// Spec 2.8's `source` column: what kind of actor produced this entry, so a later reader (Undo,
/// diagnostics, support) can tell a user's own edit apart from the engine acting on their behalf.
enum JournalSource: String, Codable, Hashable, CaseIterable {
    case userEdit
    case undo
    case importICS
    case migration
    case reconciliation
    case recovery
}

/// Spec 2.8's `fieldDiff`: before/after values for only the fields that actually changed between
/// two snapshots of the same Codable entity.
enum FieldDiff {
    /// Diffs two optional snapshots at the JSON-object level. `before == nil` (a create) or
    /// `after == nil` (a delete) is represented as every field of the non-nil side appearing
    /// with only its `after` or only its `before` key set.
    ///
    /// Returns `nil` when there is nothing to record — both sides absent, or every field equal
    /// — so a journal entry with no diff can distinguish "no changes" from "diff not computed."
    static func compute<T: Encodable>(from before: T?, to after: T?) -> String? {
        let beforeFields = jsonObject(before)
        let afterFields = jsonObject(after)
        guard !(beforeFields.isEmpty && afterFields.isEmpty) else { return nil }

        var diff: [String: Any] = [:]
        for key in Set(beforeFields.keys).union(afterFields.keys).sorted() {
            let beforeValue = beforeFields[key]
            let afterValue = afterFields[key]
            guard !valuesAreEqual(beforeValue, afterValue) else { continue }

            var entry: [String: Any] = [:]
            if let beforeValue { entry["before"] = beforeValue }
            if let afterValue { entry["after"] = afterValue }
            diff[key] = entry
        }

        guard !diff.isEmpty,
              JSONSerialization.isValidJSONObject(diff),
              let data = try? JSONSerialization.data(withJSONObject: diff, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObject<T: Encodable>(_ value: T?) -> [String: Any] {
        guard let value else { return [:] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// JSON values decoded by `JSONSerialization` are always `NSString`/`NSNumber`/`NSArray`/
    /// `NSDictionary`/`NSNull`, all of which bridge to `NSObject` and implement deep `isEqual`
    /// — that is what lets this compare nested arrays/objects without hand-rolling recursion.
    private static func valuesAreEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return (lhs as? NSObject)?.isEqual(rhs) ?? false
        default:
            return false
        }
    }
}
