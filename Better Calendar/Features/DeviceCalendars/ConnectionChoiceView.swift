import SwiftUI

/// `SRC-CONN-01` (spec 3.29/3F.7): which connection to a calendar Better Calendar should use,
/// when it can see more than one.
///
/// The trade-off is presented as spec 3.29 writes it, including the part that is inconvenient to
/// say: the direct connection is not available yet. A screen that offered a choice the app cannot
/// honour would be worse than one that explains why there is only one answer today.
struct ConnectionChoiceView: View {
    let store: BetterCalendarStore

    var body: some View {
        List {
            if store.allDuplicateConnections.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No duplicate connections",
                        systemImage: "checkmark.circle",
                        description: Text("Each of your calendars is reaching Better Calendar one way. If that ever changes, you'll be asked which connection to use.")
                    )
                }
            }

            ForEach(store.allDuplicateConnections) { group in
                Section {
                    ForEach(group.calendars) { calendar in
                        ConnectionOptionRow(
                            calendar: calendar,
                            isChosen: !calendar.isSupersededByDuplicateConnection,
                            isDecided: group.isResolved,
                            onChoose: { store.resolveDuplicateConnection(group, keeping: calendar.id) }
                        )
                    }
                } header: {
                    Text(group.identity.calendarKey.capitalized)
                } footer: {
                    Text(explanation(for: group))
                }
            }
        }
        .navigationTitle("Connections")
#if os(iOS) || os(tvOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func explanation(for group: DuplicateConnectionDetector.DuplicateGroup) -> String {
        if group.isResolved {
            return "Better Calendar is using one of these. The other is kept — nothing has been deleted — and you can switch at any time."
        }
        return """
        This calendar is reaching Better Calendar more than once, so its events would appear twice. \
        Choose the one to use. The other is kept and can be switched back to later.
        """
    }
}

/// One connection, with what it costs and what it gives — spec 3.29's trade-off, per row.
private struct ConnectionOptionRow: View {
    let calendar: BetterCalendar
    let isChosen: Bool
    let isDecided: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChosen && isDecided ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen && isDecided ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(calendar.accountName ?? calendar.name)
                        .foregroundStyle(.primary)
                    Text(tradeOff)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen && isDecided ? [.isSelected] : [])
    }

    /// Spec 3.29's two options, stated honestly. Only the device one exists in Phase 3, and the
    /// copy says so rather than implying a choice the app cannot yet make.
    private var tradeOff: String {
        switch calendar.connectionMethod {
        case .device:
            "Through your device. No extra sign-in, and works with everything already on your phone."
        case .direct:
            "Signed in directly. Richer features, and needs its own sign-in."
        case .local:
            "Stored only in Better Calendar."
        }
    }
}
