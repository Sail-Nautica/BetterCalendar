import EventKit
import Foundation

/// Spec 3.2: **the only file in the codebase that imports EventKit.** Domain code stays free of
/// it exactly as it stays free of SwiftUI and GRDB, and no view ever sees an EventKit type.
/// Phase 3B's store implementation joins it in this directory under the same rule.
///
/// Holds no `EKEventStore`. `EKEventStore.authorizationStatus(for:)` is a static read, and the
/// instance needed to issue a request is created inside the request and released with it — so
/// launch instantiates nothing from EventKit, which is spec 3.18's "launch must not block on
/// EventKit" applied one phase early.
///
/// EventKit, the status read, and `requestFullAccessToEvents()` all exist on macOS 14 and
/// iOS 17 — the project's deployment targets — so this compiles unguarded on both. The one
/// platform difference in Phase 3A is the Settings deep link, which lives in `SystemSettingsLink`.
struct EventKitCalendarAuthorization: CalendarAccessAuthorizing {
    var authorizationStatus: CalendarAccessStatus {
        CalendarAccessStatus(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus {
        guard level == .full else {
            // Spec 3A.2 rule 1 / 3A.6: Better Calendar never requests write-only access and so
            // does not declare `NSCalendarsWriteOnlyAccessUsageDescription`. Requesting a level
            // whose usage description is missing terminates the app — so this returns the
            // current status instead of asking. If a later phase needs write-only, the string
            // and this call arrive in the same change.
            return authorizationStatus
        }

        let eventStore = EKEventStore()
        do {
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {
            // A thrown request is not a distinct product state: the status read below is the
            // authoritative answer either way. The error itself carries no user content, but
            // `PrivacyLog.debug` takes a `StaticString` regardless (spec 0.13), so nothing from
            // it can reach a log line.
            PrivacyLog.debug("Calendar access request finished with an error")
        }

        return authorizationStatus
    }
}

private extension CalendarAccessStatus {
    /// The translation that keeps `EKAuthorizationStatus` out of the domain layer.
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .fullAccess:
            self = .fullAccess
        case .writeOnly:
            self = .writeOnly
        @unknown default:
            // A status this build does not understand is treated as "not yet answered" rather
            // than as access: the failure mode of guessing high is displaying a calendar we
            // cannot actually read.
            self = .notDetermined
        }
    }
}
