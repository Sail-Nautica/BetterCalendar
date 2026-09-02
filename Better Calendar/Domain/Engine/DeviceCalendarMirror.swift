import Foundation

/// Spec 3B.3: the discovery pass, as a pure function.
///
/// Takes what the device reports and what is already mirrored, and returns the `EntityChange`s
/// that reconcile them — exactly the shape `EventMutationUseCases` produces for a user edit, so
/// the result goes through the same atomic `EngineTransaction` path and gets the same journal,
/// rollback and consistency guarantees.
///
/// No I/O, no clock, no `UUID()` it does not own: `now` and `makeIdentifier` are parameters, so
/// every rule below is a deterministic unit test with no device (BC-EK-024).
enum DeviceCalendarMirror {

    /// Counts, never content — the shape spec 3.24 requires of a pass's diagnostics.
    struct Summary: Equatable {
        var added = 0
        var updated = 0
        var reconnected = 0
        var markedUnavailable = 0
        var unchanged = 0

        var isNoOp: Bool {
            added == 0 && updated == 0 && reconnected == 0 && markedUnavailable == 0
        }
    }

    struct Plan: Equatable {
        var changes: [EntityChange] = []
        var summary = Summary()

        var isEmpty: Bool { changes.isEmpty }
    }

    /// The key a mirrored row and a device calendar are matched on: the account and the
    /// provider's own calendar identifier.
    ///
    /// Never the name. Two accounts each having a calendar called "Work" is ordinary, and a
    /// renamed calendar is still the same calendar — matching on the name would produce a
    /// duplicate on every rename and a collision on every device with two accounts.
    struct MirrorKey: Hashable {
        var accountIdentifier: String
        var calendarIdentifier: String
    }

    static func plan(
        devices: [DeviceCalendar],
        existing: [BetterCalendar],
        now: Date,
        makeIdentifier: () -> UUID = UUID.init
    ) -> Plan {
        var plan = Plan()

        let mirroredRows = existing.filter { $0.connectionMethod == .device }
        var rowsByKey: [MirrorKey: BetterCalendar] = [:]
        for row in mirroredRows {
            guard let key = mirrorKey(for: row) else { continue }
            rowsByKey[key] = row
        }

        // Sorted so a first discovery assigns sort order — and therefore the on-screen order of
        // a freshly connected device — the same way every time, rather than in whatever order
        // EventKit happened to enumerate.
        let sortedDevices = devices.sorted {
            ($0.source.title, $0.title, $0.identifier) < ($1.source.title, $1.title, $1.identifier)
        }

        var nextSortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        var matchedKeys: Set<MirrorKey> = []

        for device in sortedDevices {
            let key = MirrorKey(accountIdentifier: device.source.identifier, calendarIdentifier: device.identifier)
            matchedKeys.insert(key)

            guard let row = rowsByKey[key] else {
                plan.changes.append(.upsertCalendar(mirroredRow(for: device, id: makeIdentifier(), sortOrder: nextSortOrder, now: now)))
                nextSortOrder += 1
                plan.summary.added += 1
                continue
            }

            let updated = applyingProviderFields(of: device, to: row)
            guard updated != row else {
                plan.summary.unchanged += 1
                continue
            }

            var committed = updated
            committed.updatedAt = now
            committed.versionNumber = row.versionNumber + 1
            plan.changes.append(.upsertCalendar(committed))

            if row.isUnavailable {
                plan.summary.reconnected += 1
            } else {
                plan.summary.updated += 1
            }
        }

        // Spec 3.8: a calendar that disappeared is *marked*, never purged — its `isVisible`,
        // `isDefault` and `sortOrder` are the user's, and deleting the row would throw them away
        // along with (from Phase 3C) every event mirrored onto it.
        for row in mirroredRows {
            guard let key = mirrorKey(for: row), !matchedKeys.contains(key) else { continue }
            guard !row.isUnavailable else {
                // Already marked on an earlier pass. Re-marking would rewrite `unavailableSince`
                // every pass and break idempotence — and that timestamp is what Phase 3E's
                // retention limit will measure from.
                plan.summary.unchanged += 1
                continue
            }

            var marked = row
            marked.isUnavailable = true
            marked.unavailableSince = now
            marked.updatedAt = now
            marked.versionNumber = row.versionNumber + 1
            plan.changes.append(.upsertCalendar(marked))
            plan.summary.markedUnavailable += 1
        }

        return plan
    }

    /// A row's half of the matching key. `nil` for a device row missing either identifier, which
    /// should not exist — but a row that cannot be matched must be left alone rather than
    /// matched against the wrong calendar or swept up as unavailable.
    static func mirrorKey(for calendar: BetterCalendar) -> MirrorKey? {
        guard calendar.connectionMethod == .device,
              let accountIdentifier = calendar.providerAccountID,
              let calendarIdentifier = calendar.providerCalendarID else {
            return nil
        }
        return MirrorKey(accountIdentifier: accountIdentifier, calendarIdentifier: calendarIdentifier)
    }

    // MARK: - Field ownership (spec 3B.3)

    private static func mirroredRow(for device: DeviceCalendar, id: UUID, sortOrder: Int, now: Date) -> BetterCalendar {
        let color = colorFields(for: device)
        return BetterCalendar(
            id: id,
            name: device.title,
            colorName: color.name,
            // Spec 3.8's default display rule. Everything is shown except the large ambient
            // calendars — birthdays, holiday feeds, subscriptions — which would swamp a day view
            // on first connect. Nothing is asked; every one of them is one toggle away.
            isVisible: !device.isAmbient,
            // Never set by discovery. The user's existing default is untouched, and a device
            // calendar becomes the default only when the user chooses it (spec 3B.5, ADR 0005).
            isDefault: false,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now,
            versionNumber: 1,
            provider: device.source.provider,
            connectionMethod: .device,
            providerAccountID: device.source.identifier,
            providerCalendarID: device.identifier,
            accountName: device.source.title,
            colorHex: color.hex,
            isReadOnly: device.isReadOnly,
            // `EKCalendar` has no time zone — only `EKEvent` does — so a mirrored calendar has
            // none to carry. Per-event zones are Phase 3C's business.
            timeZoneIdentifier: nil,
            capabilities: device.capabilities
        )
    }

    /// Overwrites exactly the fields the provider owns, and leaves every local-only field — the
    /// row id, `isVisible`, `isDefault`, `sortOrder` — untouched.
    ///
    /// That split is the safety property of the whole mirror. A hidden calendar staying hidden
    /// through an upstream rename depends on it, and so does every event Phase 3C mirrors onto
    /// this row: a regenerated id would reparent all of them on the next pass.
    private static func applyingProviderFields(of device: DeviceCalendar, to row: BetterCalendar) -> BetterCalendar {
        let color = colorFields(for: device)
        var updated = row
        updated.name = device.title
        updated.colorName = color.name
        updated.colorHex = color.hex
        updated.provider = device.source.provider
        updated.accountName = device.source.title
        updated.isReadOnly = device.isReadOnly
        updated.capabilities = device.capabilities
        // Seeing it at all is what makes it available again — reconnection by provider identity,
        // not a re-import (BC-EK-022).
        updated.isUnavailable = false
        updated.unavailableSince = nil
        return updated
    }

    /// Normalises a provider colour the same way `SQLiteCalendarRepository` does when it reads
    /// one back: a hex that *is* one of the six design tokens is that token, with no raw hex.
    ///
    /// Both sides have to agree, or a device calendar coloured exactly `#4F7DFF` would compare
    /// unequal to its own stored row on every pass and be rewritten forever.
    private static func colorFields(for device: DeviceCalendar) -> (name: CalendarColorName, hex: String?) {
        guard let hex = device.colorHex else { return (.betterBlue, nil) }
        if let token = CalendarColorName(hexValue: hex) {
            return (token, nil)
        }
        // The token is a fallback that only renders if the hex turns out to be unparseable
        // (spec 3B.7); `displayColor` prefers the hex whenever it can read it.
        return (.betterBlue, hex)
    }
}
