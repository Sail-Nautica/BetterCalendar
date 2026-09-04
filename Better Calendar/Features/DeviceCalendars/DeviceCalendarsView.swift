import SwiftUI

/// `SRC-LIST-01` (spec 3.8/3B.8, BC-EK-004/BC-EK-005): the calendars already on this device,
/// grouped by the account that owns them, each with the one control that is actually ours —
/// whether to show it.
///
/// Everything else about a device calendar belongs to the account: spec 3.8 forbids renaming,
/// recolouring or deleting one from here, and the store enforces that at the model layer rather
/// than trusting this screen not to offer it.
struct DeviceCalendarsView: View {
    let store: BetterCalendarStore

    @State private var isShowingPrimer = false

    private var access: DeviceCalendarAccessState {
        store.deviceCalendarAccess
    }

    var body: some View {
        List {
            if access.canReadDeviceEvents {
                connectedContent
            } else {
                // Spec 3.4: every non-readable state explains itself in its own words, including
                // write-only, which must never render as an empty device (BC-EK-003).
                DeviceCalendarAccessSection(store: store, isShowingPrimer: $isShowingPrimer)
            }
        }
        .navigationTitle("Device Calendars")
        .task {
            // Spec 3.4/3B.0: a device-calendar surface appearing is both an authorization
            // re-check and one of this phase's explicit discovery triggers — and, from Phase 3C,
            // an event-mirroring trigger too.
            await store.refreshDeviceCalendars()
            // Spec 3.3: the primer auto-presents the first time this screen is opened, and only
            // the first time — the rule Phase 3A specified and this screen finally consumes.
            if store.deviceCalendarAccess.shouldPresentPrimerAutomatically {
                isShowingPrimer = true
            }
        }
        .sheet(isPresented: $isShowingPrimer) {
            CalendarAccessPrimerView(store: store)
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        let accounts = store.deviceCalendarAccounts

        if accounts.isEmpty {
            Section {
                Text("This device has calendar access but no calendars to show. Adding an account in Settings makes its calendars available here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(accounts) { account in
                Section {
                    ForEach(account.calendars) { calendar in
                        DeviceCalendarRow(calendar: calendar, store: store)
                    }
                } header: {
                    Text(account.name)
                } footer: {
                    if account.isUnavailable {
                        Text("This account is no longer on this device. Its calendars are kept here, hidden, in case it comes back.")
                    }
                }
            }

            Section {
                Text("Calendar names, colours, and which calendars exist are managed by each account. Change them in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceCalendarRow: View {
    let calendar: BetterCalendar
    let store: BetterCalendarStore

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(calendar.displayColor)
                .frame(width: 12, height: 12)
                .opacity(calendar.isUnavailable ? 0.4 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.name)
                    .foregroundStyle(calendar.isUnavailable ? .secondary : .primary)

                if let badge {
                    Text(badge)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // BC-EK-005: display state, not data state — toggling this off removes the
            // calendar's events from every view and deletes nothing, here or on the device.
            Toggle("Show \(calendar.name)", isOn: visibilityBinding)
                .labelsHidden()
                .disabled(calendar.isUnavailable)
        }
        .padding(.vertical, 2)
    }

    private var badge: String? {
        if calendar.isUnavailable {
            return "Not on this device"
        }
        if calendar.isReadOnly {
            return "Read-only"
        }
        return nil
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { calendar.isVisible },
            set: { newValue in
                guard newValue != calendar.isVisible else { return }
                store.toggleCalendarVisibility(calendar)
            }
        )
    }
}

#Preview {
    NavigationStack {
        DeviceCalendarsView(
            store: BetterCalendarStore(
                repository: JSONCalendarRepository(),
                notificationScheduler: NoopNotificationScheduler(),
                eventKitStore: FakeEventKitStore()
            )
        )
    }
}
