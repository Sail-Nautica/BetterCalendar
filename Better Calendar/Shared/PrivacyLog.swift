import Foundation
import os

/// BC-PRIV-001 (spec 0.13): the one sanctioned path for diagnostics and analytics in this app.
/// Two deliberate restrictions keep event content out of logs by construction rather than by
/// programmer discipline at each call site:
/// - `debug(_:)` takes a `StaticString`, so a call site can never interpolate a title, note,
///   location, or search query into a log line — only a compile-time literal.
/// - `track(_:)` takes a closed `AnalyticsEvent` enum (the spec 0.13 allow-list), so there is no
///   free-form "eventName: String" path that could leak into analytics.
enum PrivacyLog {
    /// The spec 0.13 analytics allow-list. Adding an event means adding a case here — there is
    /// no other way to emit one.
    enum AnalyticsEvent: String, CaseIterable {
        case calendarViewOpened = "calendar_view_opened"
        case eventCreationStarted = "event_creation_started"
        case eventSaved = "event_saved"
        case eventDeleted = "event_deleted"
        case searchPerformed = "search_performed"
        case notificationPermissionResult = "notification_permission_result"
        /// Spec 3K: the resulting `CalendarAccessStatus`, which is enum-like status text and
        /// carries no calendar name, account email, or event content.
        case calendarPermissionResult = "calendar_permission_result"
        case icsImportResult = "ics_import_result"
    }

    private static let diagnostics = Logger(subsystem: "com.bettercalendar.app", category: "diagnostics")
    private static let analytics = Logger(subsystem: "com.bettercalendar.app", category: "analytics")

    /// Debug/diagnostic logging. `message` is a compile-time `StaticString` literal so it can
    /// never carry interpolated user content. Any per-call variable data (counts, identifiers,
    /// booleans — never event title/notes/location/search text) goes through `metadata`, which
    /// os_log redacts as `.private` by default; pass `isPublic: true` only for values you're
    /// certain never derive from user content.
    static func debug(_ message: StaticString, metadata: String? = nil, isPublic: Bool = false) {
        guard let metadata else {
            diagnostics.debug("\(message, privacy: .public)")
            return
        }
        if isPublic {
            diagnostics.debug("\(message, privacy: .public): \(metadata, privacy: .public)")
        } else {
            diagnostics.debug("\(message, privacy: .public): \(metadata, privacy: .private)")
        }
    }

    /// Analytics logging restricted to `AnalyticsEvent`. `metadata`, when supplied, must never
    /// contain event title/notes/location/search query/attendee name/calendar name — see the
    /// "Do not transmit" list in spec 0.13; every current call site only passes counts or
    /// enum-like status strings.
    static func track(_ event: AnalyticsEvent, metadata: String? = nil) {
        if let metadata {
            analytics.log("\(event.rawValue, privacy: .public) \(metadata, privacy: .public)")
        } else {
            analytics.log("\(event.rawValue, privacy: .public)")
        }
    }
}
