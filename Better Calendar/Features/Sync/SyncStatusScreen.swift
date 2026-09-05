import SwiftUI

/// `SRC-STAT-01` (spec 3D.8): what is queued for the device, what is stuck, and why.
///
/// This is a **screen** rather than a banner on purpose. Spec 3.21 requires that a failed
/// mutation stay user-visible and that a conflict the user dismissed by accident remain findable
/// — neither of which a transient notice can promise. Everything here is counts and the user's
/// own event titles; nothing about a device event's content, per spec 3K.
struct SyncStatusScreen: View {
    let store: BetterCalendarStore

    var body: some View {
        List {
            Section {
                LabeledContent("Waiting to send", value: "\(count(of: .pending) + count(of: .inFlight))")
                if count(of: .parked) > 0 {
                    LabeledContent("Waiting for permission", value: "\(count(of: .parked))")
                }
                if count(of: .conflicted) > 0 {
                    LabeledContent("Changed in two places", value: "\(count(of: .conflicted))")
                }
                if count(of: .failed) > 0 {
                    LabeledContent("Couldn't be saved", value: "\(count(of: .failed))")
                }
            } header: {
                Text("Queue")
            } footer: {
                if store.outboxRowsNeedingAttention.isEmpty && count(of: .pending) == 0 && count(of: .inFlight) == 0 {
                    Text("Everything you've changed has reached your calendars.")
                }
            }

            if let summary = store.lastWriteBackSummary {
                Section("Last Sync") {
                    // Spec 3.24: counts, never content.
                    LabeledContent("Sent", value: "\(summary.applied)")
                    if summary.adopted > 0 {
                        LabeledContent("Already there", value: "\(summary.adopted)")
                    }
                    if summary.retried > 0 {
                        LabeledContent("Will retry", value: "\(summary.retried)")
                    }
                }
            }

            if !store.outboxRowsNeedingAttention.isEmpty {
                Section {
                    ForEach(store.outboxRowsNeedingAttention) { mutation in
                        StuckMutationRow(
                            title: store.eventTitle(forMutation: mutation),
                            mutation: mutation,
                            onRetry: { store.retryMutation(mutation) }
                        )
                    }
                } header: {
                    Text("Needs attention")
                } footer: {
                    // Spec 2.12's rule, said to the user rather than only to the engine.
                    Text("Nothing here has been lost. Your changes are saved on this device and will be sent when they can be.")
                }
            }

            // Spec 3A.7: offered only where Settings can actually resolve it, and omitted
            // entirely where it cannot rather than shown as an action that does nothing.
            if count(of: .parked) > 0, let settingsURL = SystemSettingsLink.calendarPrivacy {
                Section {
                    Link("Open Settings", destination: settingsURL)
                } footer: {
                    Text("Better Calendar needs calendar access to send these changes.")
                }
            }
        }
        .navigationTitle("Sync Status")
#if os(iOS) || os(tvOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func count(of status: MutationStatus) -> Int {
        store.outboxDepthByStatus[status] ?? 0
    }
}

/// One stuck mutation, named by the event it is about — spec 3.35's rule that copy says what
/// happened, why, and what to do next.
private struct StuckMutationRow: View {
    let title: String
    let mutation: PendingMutation
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // A parked mutation has nothing to retry — the block is a permission, and it resumes
            // on its own when access returns. Offering a button that cannot work would be worse
            // than offering none.
            if mutation.status != .parked {
                Button("Try Again", action: onRetry)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var explanation: String {
        switch mutation.status {
        case .parked:
            "Waiting for calendar access. It'll be sent as soon as access is granted again."
        case .conflicted:
            "This was changed here and on your device at the same time. Your version is safe; open the event to decide which to keep."
        case .failed:
            "Your calendar wouldn't accept this change. It's still saved here."
        default:
            "Waiting to be sent."
        }
    }
}
