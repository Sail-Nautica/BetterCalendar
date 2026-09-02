import Foundation

/// Spec 3B.1: what EventKit reports about a calendar, in Better Calendar's own value types.
///
/// Nothing in this file imports EventKit. The adapter translates `EKSource`/`EKCalendar` into
/// these and stops; every rule that follows — provider attribution, read-only derivation, the
/// mirror's matching and defaults — is pure, and therefore testable with no device (BC-EK-024).

/// `EKSourceType`, in our own words. Kept as a distinct type from `EventProvider` because the
/// interesting step is the *classification* between them (3B.2), and a pure enum on this side is
/// what lets that classification be unit-tested.
enum DeviceCalendarSourceType: String, Hashable, CaseIterable {
    case local
    case exchange
    case calDAV
    case mobileMe
    case subscribed
    case birthdays
}

/// An account, as the device has it configured. `identifier` is `EKSource.sourceIdentifier` and
/// is half of the mirror's matching key (3B.3).
struct DeviceCalendarSource: Hashable, Identifiable {
    var identifier: String
    var title: String
    var type: DeviceCalendarSourceType

    var id: String { identifier }

    /// Spec 3B.2: who owns the data. Deliberately narrow about Google — a source is Google only
    /// when its identity says so, never by elimination, because a wrong `.google` becomes a false
    /// match in Phase 3F's duplicate-connection rule while a wrong `.otherAccount` is only a
    /// cosmetic grouping error.
    var provider: EventProvider {
        switch type {
        case .local:
            .deviceLocal
        case .exchange:
            .exchange
        case .subscribed:
            .subscribed
        case .birthdays, .mobileMe:
            .apple
        case .calDAV:
            if Self.looksLikeGoogle(title) {
                .google
            } else if Self.looksLikeICloud(title) {
                .apple
            } else {
                .otherAccount
            }
        }
    }

    private static func looksLikeGoogle(_ title: String) -> Bool {
        let lowercased = title.lowercased()
        return lowercased.contains("gmail")
            || lowercased.contains("google")
            || lowercased.hasSuffix("@googlemail.com")
    }

    private static func looksLikeICloud(_ title: String) -> Bool {
        let lowercased = title.lowercased()
        return lowercased.contains("icloud")
            || lowercased.contains("me.com")
            || lowercased.contains("mac.com")
    }
}

/// `EKCalendarType`, in our own words.
enum DeviceCalendarType: String, Hashable, CaseIterable {
    case local
    case calDAV
    case exchange
    case subscription
    case birthday

}

/// One calendar on the device. Carries its own `source` rather than the store exposing a
/// separate `sources()`: every consumer in Phase 3B wants the source *of a calendar*, and a
/// source with no calendars has nothing to list or toggle. Spec 3.2's `sources()` arrives in
/// Phase 3F, where the duplicate-connection rule compares accounts rather than calendars.
struct DeviceCalendar: Hashable, Identifiable {
    var identifier: String
    var source: DeviceCalendarSource
    var title: String
    var type: DeviceCalendarType
    var colorHex: String?
    var isImmutable: Bool
    var isSubscribed: Bool
    var allowsContentModifications: Bool
    /// The subset of *our* two availability values the calendar accepts. EventKit reports four
    /// and a "supports none at all" case; the two Better Calendar models are mapped across and
    /// the rest is 3C's problem, per spec 3.12.
    var allowedAvailabilities: [EventAvailability]

    var id: String { identifier }

    init(
        identifier: String,
        source: DeviceCalendarSource,
        title: String,
        type: DeviceCalendarType,
        colorHex: String? = nil,
        isImmutable: Bool = false,
        isSubscribed: Bool = false,
        allowsContentModifications: Bool = true,
        allowedAvailabilities: [EventAvailability] = EventAvailability.allCases
    ) {
        self.identifier = identifier
        self.source = source
        self.title = title
        self.type = type
        self.colorHex = colorHex
        self.isImmutable = isImmutable
        self.isSubscribed = isSubscribed
        self.allowsContentModifications = allowsContentModifications
        self.allowedAvailabilities = allowedAvailabilities
    }

    /// Spec 3.8's "large ambient calendars" — mirrored as rows, but not displayed by default,
    /// because a birthday or holiday feed swamps a day view and almost nobody wants it there the
    /// first time they connect.
    ///
    /// Driven by `isSubscribed` rather than by `type`, because EventKit documents that "CalDAV
    /// subscribed calendars have type EKCalendarTypeCalDAV with isSubscribed = YES" — so a
    /// subscribed holiday feed inside an iCloud account does not report `.subscription` at all.
    var isAmbient: Bool {
        type == .birthday || type == .subscription || isSubscribed
    }

    /// Spec 3.10: "Birthday and subscribed calendars are always read-only." EventKit reports
    /// `allowsContentModifications == false` for both already; asserting it here as well means a
    /// provider that ever reports otherwise cannot make one of them writable by accident.
    var isReadOnly: Bool {
        !allowsContentModifications || isImmutable || isAmbient
    }

    /// The fine-grained truth spec 3.10 asks a provider for, as opposed to the coarse
    /// `isReadOnly` flag the UI shows.
    ///
    /// Two fields have no EventKit counterpart and are derived rather than reported:
    /// `supportsRecurrence` is assumed for every calendar (EventKit exposes no such flag, so a
    /// calendar that refuses one has to fail the write in Phase 3D and be classified there), and
    /// `supportsReminders` follows writability, since an alarm cannot be added to a calendar
    /// whose contents cannot be modified.
    var capabilities: CalendarCapabilities {
        let isWritable = allowsContentModifications && !isImmutable
        return CalendarCapabilities(
            allowsContentModifications: isWritable,
            allowsEventCreation: isWritable && !isAmbient,
            allowedAvailabilities: allowedAvailabilities,
            supportsRecurrence: true,
            supportsReminders: isWritable,
            isSubscribed: isSubscribed || type == .subscription,
            isImmutable: isImmutable
        )
    }
}
