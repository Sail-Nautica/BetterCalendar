import SwiftUI

struct EventDetailsView: View {
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?
    let onEdit: (CalendarEvent) -> Void
    /// "This Event" edit scope (BC-REC-010, spec 1.11) — the caller resolves which event to
    /// open via `store.eventForEditingOccurrence(_:)`.
    let onEditOccurrence: (CalendarOccurrence) -> Void
    let onDelete: (CalendarEvent) -> Void
    /// "This Event" delete scope (BC-REC-010, spec 1.11) — the caller calls
    /// `store.deleteOccurrence(_:)`.
    let onDeleteOccurrence: (CalendarOccurrence) -> Void
    let onDuplicate: (CalendarEvent) -> Void
    let onMove: (CalendarEvent, Date) -> Void
    let onResize: (CalendarEvent, Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingScopeAction: ScopeAction?

    private enum ScopeAction: Equatable {
        case edit
        case delete
    }

    private var event: CalendarEvent {
        occurrence.displayEvent
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(calendar?.colorName.color ?? .blue)
                            .frame(width: 14, height: 14)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.title)
                                .font(.title2.weight(.semibold))
                            Text(event.timeRangeText())
                                .foregroundStyle(.secondary)

                            if occurrence.isRecurringOccurrence {
                                Label("Repeats: \(event.recurrence?.summary ?? "Recurring event")", systemImage: "repeat")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Actions") {
                    Button("Edit", systemImage: "pencil") {
                        if occurrence.isRecurringOccurrence {
                            pendingScopeAction = .edit
                        } else {
                            dismiss()
                            onEdit(occurrence.event)
                        }
                    }

                    Button("Duplicate this occurrence", systemImage: "plus.square.on.square") {
                        dismiss()
                        onDuplicate(event)
                    }

                    Menu(occurrence.isRecurringOccurrence ? "Move series" : "Move") {
                        Button("15 minutes earlier") {
                            move(by: -15 * 60)
                        }
                        Button("15 minutes later") {
                            move(by: 15 * 60)
                        }
                        Button("1 day earlier") {
                            move(by: -24 * 60 * 60)
                        }
                        Button("1 day later") {
                            move(by: 24 * 60 * 60)
                        }
                    }

                    if !event.isAllDay {
                        Menu(occurrence.isRecurringOccurrence ? "Resize series" : "Resize") {
                            Button("Shorten by 15 minutes") {
                                resizeEnd(by: -15 * 60)
                            }
                            Button("Extend by 15 minutes") {
                                resizeEnd(by: 15 * 60)
                            }
                            Button("Start 15 minutes earlier") {
                                resizeStart(by: -15 * 60)
                            }
                            Button("Start 15 minutes later") {
                                resizeStart(by: 15 * 60)
                            }
                        }
                    }

                    Button("Delete", systemImage: "trash", role: .destructive) {
                        if occurrence.isRecurringOccurrence {
                            pendingScopeAction = .delete
                        } else {
                            dismiss()
                            onDelete(occurrence.event)
                        }
                    }
                }

                if occurrence.isRecurringOccurrence {
                    Section {
                        Text("Move and resize apply to the whole recurring series. Duplicate creates a standalone copy of only this occurrence.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    DetailRow(title: "Calendar", value: calendar?.name ?? "Local calendar", systemImage: "calendar")
                    DetailRow(title: "Time Zone", value: event.timeZoneIdentifier, systemImage: "globe")

                    if let location = event.location {
                        DetailRow(title: "Location", value: location, systemImage: "location")
                    }

                    if let urlString = event.urlString, let url = URL(string: urlString) {
                        Link(destination: url) {
                            Label(urlString, systemImage: "link")
                                .lineLimit(2)
                        }
                    } else if let urlString = event.urlString {
                        DetailRow(title: "URL", value: urlString, systemImage: "link")
                    }

                    if !event.reminders.isEmpty {
                        DetailRow(
                            title: "Reminder",
                            value: event.reminders.map(\.offset.label).joined(separator: ", "),
                            systemImage: "bell"
                        )
                    }
                }

                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes)
                    }
                }
            }
            .navigationTitle("Event Details")
#if os(iOS) || os(tvOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                pendingScopeAction == .delete ? "Delete recurring event" : "Edit recurring event",
                isPresented: Binding(get: { pendingScopeAction != nil }, set: { if !$0 { pendingScopeAction = nil } }),
                titleVisibility: .visible
            ) {
                Button("This Event") {
                    performScopedAction(applyToThisEventOnly: true)
                }
                Button("All Events") {
                    performScopedAction(applyToThisEventOnly: false)
                }
                Button("Cancel", role: .cancel) {
                    pendingScopeAction = nil
                }
            }
        }
    }

    private func performScopedAction(applyToThisEventOnly: Bool) {
        defer { pendingScopeAction = nil }
        dismiss()

        switch pendingScopeAction {
        case .edit:
            applyToThisEventOnly ? onEditOccurrence(occurrence) : onEdit(occurrence.event)
        case .delete:
            applyToThisEventOnly ? onDeleteOccurrence(occurrence) : onDelete(occurrence.event)
        case nil:
            break
        }
    }

    private func move(by seconds: TimeInterval) {
        dismiss()
        onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(seconds))
    }

    private func resizeEnd(by seconds: TimeInterval) {
        let newEndDate = occurrence.occurrenceEndDate.addingTimeInterval(seconds)
        guard newEndDate > occurrence.occurrenceStartDate.addingTimeInterval(15 * 60) else { return }
        dismiss()
        onResize(occurrence.event, occurrence.occurrenceStartDate, newEndDate)
    }

    private func resizeStart(by seconds: TimeInterval) {
        let newStartDate = occurrence.occurrenceStartDate.addingTimeInterval(seconds)
        guard occurrence.occurrenceEndDate > newStartDate.addingTimeInterval(15 * 60) else { return }
        dismiss()
        onResize(occurrence.event, newStartDate, occurrence.occurrenceEndDate)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .foregroundStyle(.primary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
