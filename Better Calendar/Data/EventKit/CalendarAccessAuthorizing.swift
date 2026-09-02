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
/// `NoopNotificationScheduler` precedent, so previews and tests share one double. Phase 3B's
/// `FakeEventKitStore` extends it rather than restating it.
class FakeCalendarAuthorization: CalendarAccessAuthorizing {
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

// MARK: - Phase 3B: calendar enumeration

/// Spec 3.2's `EventKitStore`, as far as Phase 3B needs it. Refines 3A's authorization seam
/// rather than restating it, so a caller that only asks about permission keeps the narrower
/// type and the 3A call sites did not change when this arrived.
///
/// Spec 3.2 also sketches `sources()`, `events(in:calendarIDs:)`, `save`, `remove` and
/// `changeObservations()`. The event members are Phase 3C/3D. `sources()` is Phase 3F: every
/// consumer in 3B wants the source *of a calendar*, which `DeviceCalendar` carries, and an
/// account with no calendars has nothing to list or toggle — it is the duplicate-connection rule
/// that eventually needs to compare accounts rather than calendars.
protocol EventKitStore: CalendarAccessAuthorizing {
    /// Everything one discovery pass needs, in one call.
    ///
    /// One call rather than two properties because the real implementation needs a live
    /// `EKEventStore` for both answers and creating one is the expensive part — the shape of the
    /// protocol should not force the adapter to make two.
    func discoverCalendars() throws -> DeviceCalendarSnapshot
}

/// What the device reports about its calendars at one moment.
struct DeviceCalendarSnapshot: Equatable {
    var calendars: [DeviceCalendar]
    /// `EKEventStore.defaultCalendarForNewEvents`, as an identifier. Spec 3B.5's second fallback
    /// step. Read live and held in memory only — never persisted, because it is the device's
    /// state and a stored copy disagrees with it the moment the user changes it in Settings.
    var defaultCalendarIdentifierForNewEvents: String?

    static let empty = DeviceCalendarSnapshot(calendars: [], defaultCalendarIdentifierForNewEvents: nil)

    init(calendars: [DeviceCalendar], defaultCalendarIdentifierForNewEvents: String? = nil) {
        self.calendars = calendars
        self.defaultCalendarIdentifierForNewEvents = defaultCalendarIdentifierForNewEvents
    }
}

/// Spec 3.36's fake, extended to calendars: scriptable calendars, a scriptable device default,
/// injectable failure, and a count of how many times discovery actually reached the device.
final class FakeEventKitStore: FakeCalendarAuthorization, EventKitStore {
    var snapshot: DeviceCalendarSnapshot
    /// Set to make the next discovery throw, for the failure paths spec 3.21 will classify.
    var discoveryError: Error?
    private(set) var discoveryCount = 0

    init(
        status: CalendarAccessStatus = .fullAccess,
        grantResult: CalendarAccessStatus = .fullAccess,
        snapshot: DeviceCalendarSnapshot = .empty
    ) {
        self.snapshot = snapshot
        super.init(status: status, grantResult: grantResult)
    }

    func discoverCalendars() throws -> DeviceCalendarSnapshot {
        discoveryCount += 1
        if let discoveryError {
            throw discoveryError
        }
        return snapshot
    }

    /// Someone added, removed, renamed or recoloured a calendar in Settings between passes.
    func simulateDeviceChange(to snapshot: DeviceCalendarSnapshot) {
        self.snapshot = snapshot
    }
}
