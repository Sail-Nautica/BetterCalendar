import Foundation

/// Spec 3.3: the two levels of calendar access iOS 17 and macOS 14 distinguish.
///
/// Better Calendar only ever *requests* `.full`, because the product is a calendar client that
/// must display existing events. `.writeOnly` exists here because the level has to be
/// expressible — see `CalendarAccessStatus.writeOnly` for why the *status* is reachable anyway.
enum CalendarAccessLevel: String, CaseIterable, Hashable {
    /// May create events; may not read any.
    case writeOnly
    /// May read and write.
    case full
}

/// Spec 3.3/3.4: the device's answer, in Better Calendar's own vocabulary rather than
/// EventKit's. `EKAuthorizationStatus` is translated at the adapter boundary (see
/// `EventKitCalendarAuthorization`), so nothing in the domain layer — and no view — depends on
/// EventKit's spelling of these states, or on EventKit at all.
enum CalendarAccessStatus: String, CaseIterable, Hashable {
    case notDetermined
    /// Device policy, MDM, or Screen Time. Not the user's choice to change, which is the whole
    /// reason it is a separate case from `denied`: the copy differs, and this state must never
    /// offer a Settings deep link.
    case restricted
    case denied
    /// The user allowed adding events but not reading them. Reachable even though Better
    /// Calendar never requests this level — a user can select add-only access in Settings.
    case writeOnly
    case fullAccess

    /// Spec 3.4: only full access may display device events. `writeOnly` deliberately answers
    /// `false` — showing an empty calendar in that state is BC-EK-003's failure mode.
    var canReadDeviceEvents: Bool {
        self == .fullAccess
    }

    var canCreateDeviceEvents: Bool {
        self == .fullAccess || self == .writeOnly
    }

    /// Spec 3.3: the system prompt is a single-use resource. Once the device has answered —
    /// however it answered — the app must never ask again in-app.
    var allowsInAppRequest: Bool {
        self == .notDetermined
    }

    /// Spec 3.4: whether sending the user to Settings can actually change this state.
    /// `restricted` cannot be resolved there, and `notDetermined` should be resolved by asking
    /// rather than by sending the user out of the app.
    var isResolvableInSettings: Bool {
        self == .denied || self == .writeOnly
    }
}

/// Spec 3.4's behavior table as a single value: the device's answer plus the one piece of state
/// Better Calendar itself owns about the flow. Every device-calendar surface reads this rather
/// than switching on the raw status, which is what keeps the table in one place instead of
/// scattered across views.
struct DeviceCalendarAccessState: Equatable {
    var status: CalendarAccessStatus
    /// Whether `SRC-PERM-01` has been shown before. Persisted as
    /// `AppSettings.hasSeenCalendarAccessPrimer`; the status itself never is.
    var hasSeenPrimer: Bool

    init(status: CalendarAccessStatus = .notDetermined, hasSeenPrimer: Bool = false) {
        self.status = status
        self.hasSeenPrimer = hasSeenPrimer
    }

    var canReadDeviceEvents: Bool { status.canReadDeviceEvents }
    var canCreateDeviceEvents: Bool { status.canCreateDeviceEvents }
    var isResolvableInSettings: Bool { status.isResolvableInSettings }

    /// BC-EK-001: the primer precedes the system alert, so a request is only permissible once
    /// the primer has been seen *and* the device has not already answered.
    var canRequestAccess: Bool {
        status.allowsInAppRequest && hasSeenPrimer
    }

    /// Spec 3.3: `SRC-LIST-01` (Phase 3B) presents the primer the first time the user opens it,
    /// and only the first time — after that the surface shows its ordinary connect affordance
    /// and waits to be asked. Nothing in Phase 3A auto-presents; the rule lives here so 3B
    /// inherits it already specified and already tested.
    var shouldPresentPrimerAutomatically: Bool {
        status.allowsInAppRequest && !hasSeenPrimer
    }

    var message: DeviceCalendarAccessMessage {
        .forStatus(status)
    }
}

/// Spec 3.35 / UI/UX §9.2: the copy for every state Phase 3A can produce. Each says what
/// happened, why, and what to do next — and the two states most apps get wrong get their own
/// wording rather than a shared "permission denied" string.
struct DeviceCalendarAccessMessage: Equatable {
    /// The single recovery action a state permits, if any.
    enum Action: Equatable {
        /// Show `SRC-PERM-01`, which is the only route to the system alert.
        case connect
        /// Deep-link to the Settings pane that can change this state.
        case openSettings

        var title: String {
            switch self {
            case .connect: "Connect Device Calendars"
            case .openSettings: "Open Settings"
            }
        }
    }

    var title: String
    var message: String
    var action: Action?

    static func forStatus(_ status: CalendarAccessStatus) -> DeviceCalendarAccessMessage {
        switch status {
        case .notDetermined:
            DeviceCalendarAccessMessage(
                title: "Not Connected",
                message: "Better Calendar can show the calendars already set up on this device — iCloud, Google, Exchange, and subscribed calendars — alongside your local ones.",
                action: .connect
            )
        case .restricted:
            // Spec 3.4: never show a Settings deep link that cannot help. Access here is
            // controlled by a profile or Screen Time, and the copy must not send the user
            // looking for a switch that will not move.
            DeviceCalendarAccessMessage(
                title: "Calendar Access Is Managed by This Device",
                message: "A profile or Screen Time restriction controls calendar access, so it can't be granted here. Your local Better Calendar calendars are unaffected.",
                action: nil
            )
        case .denied:
            // BC-EK-002: denial is not a failure state. Everything the app could do before it
            // can still do, and the copy says so rather than implying the app is broken.
            DeviceCalendarAccessMessage(
                title: "Calendar Access Is Off",
                message: "Better Calendar doesn't have permission to use this device's calendars. Your local calendars are unaffected. Turn access on in Settings to see the rest of your schedule here.",
                action: .openSettings
            )
        case .writeOnly:
            // BC-EK-003, the sentence this whole case exists for: the user's device calendars
            // are not empty, they are unreadable, and the app must never let those look alike.
            DeviceCalendarAccessMessage(
                title: "Add-Only Calendar Access",
                message: "Better Calendar can add events to this device's calendars but can't read them, so device events aren't shown here. This is not an empty calendar.",
                action: .openSettings
            )
        case .fullAccess:
            // Phase 3A grants access and lists nothing, because listing device calendars is
            // Phase 3B. Saying so is better than rendering a connected account with no
            // calendars under it, which reads as a sync failure.
            DeviceCalendarAccessMessage(
                title: "Connected",
                message: "Better Calendar has permission to use this device's calendars. Choosing which of them to show isn't available in this version.",
                action: nil
            )
        }
    }
}
