import SwiftUI

/// `SRC-PERM-01` (spec 3.3, BC-EK-001): the plain-language explanation that precedes the system
/// calendar prompt.
///
/// Three things it has to say, per spec 3.3 — what is read, that nothing leaves the device in
/// this phase, and that access is revocable in Settings — plus "Not Now" as a first-class
/// choice rather than a dismissible afterthought. Dismissing without connecting deliberately
/// does *not* burn the single-use system prompt: it records only that the primer has been seen.
struct CalendarAccessPrimerView: View {
    let store: BetterCalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false

    private let points: [PrimerPoint] = [
        PrimerPoint(
            systemImage: "calendar",
            title: "What Better Calendar reads",
            message: "The calendars already set up on this device — iCloud, Google, Exchange, and subscribed calendars — including their events, times, and locations."
        ),
        PrimerPoint(
            systemImage: "iphone",
            title: "Nothing leaves this device",
            message: "Better Calendar has no account and no server. Your calendar data is read and written on this device only."
        ),
        PrimerPoint(
            systemImage: "gearshape",
            title: "You stay in control",
            message: "You can turn calendar access off at any time in Settings, and Better Calendar's own local calendars keep working either way."
        )
    ]

    var body: some View {
        VStack(spacing: 24) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        Text("Connect Your Device Calendars")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("See everything already on this device alongside the calendars you keep in Better Calendar.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(points) { point in
                            PrimerPointView(point: point)
                        }
                    }
                }
                .padding(.horizontal, 28)
            }

            VStack(spacing: 12) {
                Button {
                    connect()
                } label: {
                    Text("Connect Calendars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)

                Button("Not Now") {
                    // BC-EK-001: records that the primer was shown and stops. The system prompt
                    // stays unburned, so the connect affordance still works whenever the user
                    // is ready.
                    store.markCalendarAccessPrimerSeen()
                    dismiss()
                }
                .disabled(isRequesting)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .macSheetFrame(minWidth: 420, minHeight: 520)
    }

    private func connect() {
        isRequesting = true
        Task {
            store.markCalendarAccessPrimerSeen()
            // The store refuses to reach the system alert unless the primer has been seen and
            // the device has not already answered, so this is safe to call unconditionally.
            await store.requestDeviceCalendarAccess()
            isRequesting = false
            dismiss()
        }
    }
}

private struct PrimerPoint: Identifiable {
    let systemImage: String
    let title: String
    let message: String

    var id: String { systemImage }
}

private struct PrimerPointView: View {
    let point: PrimerPoint

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: point.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(point.title)
                    .font(.headline)
                Text(point.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    CalendarAccessPrimerView(
        store: BetterCalendarStore(
            repository: JSONCalendarRepository(),
            notificationScheduler: NoopNotificationScheduler(),
            calendarAuthorization: FakeCalendarAuthorization()
        )
    )
}
