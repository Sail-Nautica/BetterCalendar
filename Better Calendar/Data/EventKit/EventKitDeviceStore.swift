import EventKit
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Spec 3.2: **the only file in the codebase that imports EventKit.** Domain code stays free of
/// it exactly as it stays free of SwiftUI and GRDB, and no view ever sees an EventKit type.
///
/// Named `EventKitCalendarAuthorization` in Phase 3A, when authorization was all it did. It grew
/// into the `EventKitStore` seam in Phase 3B rather than gaining a sibling, so that spec 3.2's
/// "only file" rule stays literally true.
///
/// Holds no long-lived `EKEventStore`. The status read is static, and the instance a request or
/// a discovery pass needs is created inside it and released with it — so launch instantiates
/// nothing from EventKit, which is spec 3.18's "launch must not block on EventKit" applied
/// early. Phase 3C, which fetches events on every reconciliation pass, is where a long-lived
/// store earns its keep; here it would only make launch heavier (ADR 0006).
///
/// EventKit, the status read, `requestFullAccessToEvents()` and calendar enumeration all exist on
/// macOS 14 and iOS 17 — the project's deployment targets — so this compiles unguarded on both.
struct EventKitDeviceStore: EventKitStore {
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

    /// Spec 3B.3. Returns nothing at all below full access rather than an empty list of
    /// calendars that happen not to be readable: BC-EK-003's rule is that write-only must never
    /// look like an empty device, and the caller decides what to say about a state it can see.
    func discoverCalendars() throws -> DeviceCalendarSnapshot {
        guard authorizationStatus.canReadDeviceEvents else {
            return .empty
        }

        let eventStore = EKEventStore()
        return DeviceCalendarSnapshot(
            calendars: eventStore.calendars(for: .event).map(DeviceCalendar.init(_:)),
            defaultCalendarIdentifierForNewEvents: eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        )
    }
}

// MARK: - Translation

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

private extension DeviceCalendar {
    init(_ calendar: EKCalendar) {
        self.init(
            identifier: calendar.calendarIdentifier,
            source: DeviceCalendarSource(calendar.source),
            title: calendar.title,
            type: DeviceCalendarType(calendar.type),
            colorHex: calendar.calendarColorHex,
            isImmutable: calendar.isImmutable,
            isSubscribed: calendar.isSubscribed,
            allowsContentModifications: calendar.allowsContentModifications,
            allowedAvailabilities: calendar.supportedEventAvailabilities.betterCalendarAvailabilities
        )
    }
}

private extension DeviceCalendarSource {
    init(_ source: EKSource?) {
        // `EKCalendar.source` is `null_unspecified` in the header. A calendar with no source is
        // not a state EventKit is expected to produce, but it is expressible, and a crash on it
        // would be a crash in discovery — so it degrades to an unattributable local source.
        guard let source else {
            self.init(identifier: "", title: "Other", type: .local)
            return
        }
        self.init(
            identifier: source.sourceIdentifier,
            title: source.title,
            type: DeviceCalendarSourceType(source.sourceType)
        )
    }
}

private extension DeviceCalendarSourceType {
    init(_ type: EKSourceType) {
        switch type {
        case .local: self = .local
        case .exchange: self = .exchange
        case .calDAV: self = .calDAV
        case .mobileMe: self = .mobileMe
        case .subscribed: self = .subscribed
        case .birthdays: self = .birthdays
        @unknown default: self = .calDAV
        }
    }
}

private extension DeviceCalendarType {
    init(_ type: EKCalendarType) {
        switch type {
        case .local: self = .local
        case .calDAV: self = .calDAV
        case .exchange: self = .exchange
        case .subscription: self = .subscription
        case .birthday: self = .birthday
        @unknown default: self = .calDAV
        }
    }
}

private extension EKCalendarEventAvailabilityMask {
    /// The two availability values Better Calendar models, intersected with what the calendar
    /// accepts. `EKCalendarEventAvailabilityNone` means the calendar supports availability at
    /// all, and maps to an empty set rather than to a guess.
    var betterCalendarAvailabilities: [EventAvailability] {
        var availabilities: [EventAvailability] = []
        if contains(.busy) {
            availabilities.append(.busy)
        }
        if contains(.free) {
            availabilities.append(.free)
        }
        return availabilities
    }
}

private extension EKCalendar {
    /// Spec 3.6/ADR 0004: the provider's exact colour, as the `#RRGGBB` the `color_hex` column
    /// already stores. Converted through sRGB so a calendar in a wide-gamut or grayscale space
    /// does not read back as garbage components.
    var calendarColorHex: String? {
        guard let cgColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }

        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }

        return String(format: "#%02X%02X%02X", channel(components[0]), channel(components[1]), channel(components[2]))
    }
}
