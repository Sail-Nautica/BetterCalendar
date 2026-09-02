import SwiftUI

/// The device-calendar permission surface inside `CAL-MGR-01` (spec 3.4, 3.33). It renders the
/// one row spec 3.4 specifies for the current authorization state — title, message, and the one
/// recovery action that state permits — and nothing else.
///
/// It never switches on the raw status: `DeviceCalendarAccessMessage.forStatus(_:)` owns the
/// whole table, so the copy is unit-tested rather than proofread.
struct DeviceCalendarAccessSection: View {
    let store: BetterCalendarStore
    @Binding var isShowingPrimer: Bool
    /// `nil` inside `SRC-LIST-01`, whose navigation title already says "Device Calendars" and
    /// would otherwise say it twice.
    var header: String?

    @Environment(\.openURL) private var openURL

    private var message: DeviceCalendarAccessMessage {
        store.deviceCalendarAccess.message
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.title)
                    .font(.subheadline.weight(.semibold))

                Text(message.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)

            if let action = message.action {
                actionButton(action)
            }
        } header: {
            if let header {
                Text(header)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: DeviceCalendarAccessMessage.Action) -> some View {
        switch action {
        case .connect:
            Button(action.title) {
                // BC-EK-001: the affordance opens the primer. It never requests access
                // directly — there is no path from a tap here to the system alert that does not
                // pass through `SRC-PERM-01`.
                isShowingPrimer = true
            }
        case .openSettings:
            // Spec 3.4: offered only where Settings can actually resolve the state, and omitted
            // entirely rather than shown inert where the platform has no such destination.
            if let url = SystemSettingsLink.calendarPrivacy {
                Button(action.title) {
                    openURL(url)
                }
            }
        }
    }
}
