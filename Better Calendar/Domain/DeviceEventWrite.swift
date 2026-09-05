import Foundation

/// Spec 3.18–3.20 (3D.2): what Better Calendar asks the device to do, in its own value types.
///
/// Nothing here imports EventKit. The planner that produces these and the committer that
/// consumes their results are pure, so the whole write-back path runs in CI against a fake with
/// no device, no account and no event store (BC-EK-024).

/// EventKit offers exactly two spans, and there is no "all events" span — spec 3.20's table is
/// the mapping from Better Calendar's three edit scopes onto these two.
enum DeviceEventSpan: String, Hashable, CaseIterable {
    /// `EKSpan.thisEvent`. Applied to a detached occurrence it changes that occurrence; applied
    /// to a **series master** it changes the whole series, which is how EventKit expresses
    /// `.allEvents`.
    case thisEvent
    /// `EKSpan.futureEvents`. EventKit performs its own split from the addressed occurrence
    /// forward, which need not match `RecurrenceSplitter`'s prediction — see spec 3D.5.
    case futureEvents
}

/// One field of an event that Better Calendar is allowed to write.
///
/// This is the type that makes spec 3.17 enforceable rather than aspirational. A write carries
/// the *whole* desired event plus the subset of fields it may apply, and the adapter patches
/// exactly that subset onto a freshly fetched device event. Everything the adapter was not asked
/// about — structured location, conference data, per-account custom properties, and every field
/// Better Calendar does not model at all — is never written, because there is no code path that
/// could write it.
///
/// Attendees are deliberately absent. EventKit offers no API to add or change one, so a field
/// for them would be a promise this app cannot keep.
enum DeviceEventField: String, Hashable, CaseIterable {
    case title
    case notes
    case location
    case url
    case startDate
    case endDate
    case isAllDay
    case timeZone
    case availability
    case alarms
    case recurrence

    /// Which fields a change to this `CalendarEvent` coding key implies.
    ///
    /// The keys are the ones `FieldDiff.compute` emits, because spec 3D.4's patch set comes from
    /// the **change journal** — what the user's edit actually touched — rather than from a diff
    /// computed at write time against a local copy that may itself be stale.
    static func fields(forJournalKey key: String) -> Set<DeviceEventField> {
        switch key {
        case "title": [.title]
        case "notes": [.notes]
        case "location": [.location]
        case "urlString": [.url]
        case "startDate": [.startDate]
        case "endDate": [.endDate]
        // A change of time type is a change of what the dates *mean*, so both travel with it.
        case "timeType": [.isAllDay, .startDate, .endDate, .timeZone]
        case "timeZoneIdentifier": [.timeZone]
        case "availability": [.availability]
        case "reminders": [.alarms]
        case "recurrence": [.recurrence]
        // `id`, `calendarID`, `attendees`, `providerMetadata`, `versionNumber`, `createdAt` and
        // `updatedAt` are either not ours to write or not the device's to hear about.
        default: []
        }
    }

    /// Every writable field, for a create — where there is no prior state to patch against and
    /// the whole event is new.
    static let all = Set(DeviceEventField.allCases)
}

/// One create or update to issue against the device.
struct DeviceEventWrite: Hashable {
    /// `nil` for a create.
    var identifier: String?
    var calendarIdentifier: String
    var span: DeviceEventSpan
    /// The complete desired state of the event, as the device would describe it.
    var event: DeviceEvent
    /// The subset of `event` the adapter may apply. See `DeviceEventField`.
    var fields: Set<DeviceEventField>

    var isCreate: Bool { identifier == nil }
}

/// What the device says after a successful write. Spec 3.19: persisted onto the local row **in
/// the same transaction that marks the mutation applied**, because a crash between the two is
/// exactly the state that produces a duplicate on the next attempt.
struct DeviceWriteReceipt: Hashable {
    var identifier: String
    var externalIdentifier: String?
    var lastModified: Date?
}

/// Spec 3.21's four classes, at the seam. The adapter classifies; `MutationProcessor` decides
/// what each class means for the row.
enum DeviceWriteFailure: Error, Hashable {
    /// Store busy, account temporarily unavailable. Retry on the existing backoff.
    case transient
    /// Access revoked, write-only, calendar became read-only. Park without spending an attempt.
    case permission
    /// Calendar deleted, event gone, data the provider rejected. Fail — but never silently.
    case permanent
    /// Spec 3.22: the device event changed underneath this mutation. Carries what the device
    /// says its version is now, so a diagnostics surface can say more than "conflict".
    case conflict(currentProviderVersion: String?)
}
