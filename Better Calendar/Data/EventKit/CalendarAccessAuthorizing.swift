import Foundation

/// Spec 3.2/3A.5: the authorization surface of the `EventKitStore` protocol, split out so
/// Phase 3A can ship the permission model without the enumeration, fetch and save members that
/// need `DeviceCalendar`/`DeviceEvent` value types to exist first.
///
/// Phase 3B's `EventKitStore` refines this protocol rather than restating it, so the seam widens
/// without any Phase 3A call site changing.
///
/// Defined against a protocol rather than `EKEventStore` for the reason spec 3.36 gives: no iOS
/// runtime is installed on the primary development machine and the whole suite runs on the macOS
/// destination, so every state of this flow has to be reachable without a device, an account, or
/// a system prompt.
protocol CalendarAccessAuthorizing {
    /// Read live on every call. Spec 3.4 forbids caching this for the process lifetime — a user
    /// can revoke access in Settings while the app is backgrounded, and a stale copy is how an
    /// app ends up confidently showing a calendar it can no longer read.
    var authorizationStatus: CalendarAccessStatus { get }

    /// Presents the system alert, which can only ever happen once for the lifetime of the
    /// install. Callers are responsible for not burning it — see
    /// `BetterCalendarStore.requestDeviceCalendarAccess()`, which is the only caller and refuses
    /// unless `DeviceCalendarAccessState.canRequestAccess` is true.
    ///
    /// Returns the resulting status rather than a `Bool`: "not granted" has three distinct
    /// meanings (`denied`, `restricted`, `writeOnly`) and they lead to three different screens.
    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus
}

/// Spec 3.36's authorization surface: scriptable status, scriptable answer to the system alert,
/// and a record of what was asked, so "granted → revoked → re-granted" is a deterministic test
/// step and "we asked the system exactly once" is assertable.
///
/// Ships in the app target beside the real implementation, following the
/// `NoopNotificationScheduler` precedent, so previews and tests share one double. Phase 3B folds
/// it into `FakeEventKitStore`.
final class FakeCalendarAuthorization: CalendarAccessAuthorizing {
    var authorizationStatus: CalendarAccessStatus
    /// What the system alert "answers" when `requestAccess` is called.
    var grantResult: CalendarAccessStatus
    private(set) var requestedLevels: [CalendarAccessLevel] = []

    var requestCount: Int { requestedLevels.count }

    init(status: CalendarAccessStatus = .notDetermined, grantResult: CalendarAccessStatus = .fullAccess) {
        self.authorizationStatus = status
        self.grantResult = grantResult
    }

    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus {
        requestedLevels.append(level)
        authorizationStatus = grantResult
        return grantResult
    }

    /// The user changing the setting outside the app — the BC-EK-022 scenario. Deliberately not
    /// spelled `authorizationStatus = ...` at the call site, so a test that means "someone
    /// revoked this in Settings" reads that way.
    func simulateExternalChange(to status: CalendarAccessStatus) {
        authorizationStatus = status
    }
}
