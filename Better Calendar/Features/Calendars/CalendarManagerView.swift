import SwiftUI

struct CalendarManagerView: View {
    let store: BetterCalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var newCalendarName = ""
    @State private var newCalendarColor: CalendarColorName = .betterBlue

    var body: some View {
        NavigationStack {
            List {
                Section("Local Calendars") {
                    ForEach(store.calendars) { calendar in
                        CalendarManagerRow(calendar: calendar, store: store)
                    }
                    .onMove { source, destination in
                        store.reorderCalendars(fromOffsets: source, toOffset: destination)
                    }
                }

                Section("Add Calendar") {
                    TextField("Name", text: $newCalendarName)
                    Picker("Color", selection: $newCalendarColor) {
                        ForEach(CalendarColorName.allCases) { colorName in
                            Text(colorName.rawValue).tag(colorName)
                        }
                    }
                    Button("Create Calendar", systemImage: "plus") {
                        store.addCalendar(named: newCalendarName, colorName: newCalendarColor)
                        newCalendarName = ""
                        newCalendarColor = .betterBlue
                    }
                    .disabled(newCalendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Recently Deleted") {
                    if store.deletedEventTombstones.isEmpty {
                        Text("No recently deleted events.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.deletedEventTombstones.sorted { $0.deletedAt > $1.deletedAt }) { tombstone in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tombstone.title)
                                    Text("Deleted \(tombstone.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Restore") {
                                    store.restoreDeletedEvent(tombstone)
                                }
                                .font(.footnote)
                                .disabled(tombstone.eventSnapshotJSON == nil)
                            }
                        }
                    }
                }

                Section("Data") {
                    NavigationLink("Import / Export") {
                        ImportExportView(store: store)
                    }

                    Text("Local-only MVP. Connected accounts are intentionally not exposed in Phase 1.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calendars")
            .toolbar {
#if canImport(UIKit)
                // Puts the list into edit mode so `.onMove` reordering is reachable. macOS has no
                // `EditButton`/edit mode; there the rows are drag-reorderable directly.
                ToolbarItem(placement: .cancellationAction) {
                    EditButton()
                }
#endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct CalendarManagerRow: View {
    let calendar: BetterCalendar
    let store: BetterCalendarStore

    @State private var editedName: String
    @State private var editedColor: CalendarColorName
    @State private var showDeleteConfirmation = false

    init(calendar: BetterCalendar, store: BetterCalendarStore) {
        self.calendar = calendar
        self.store = store
        _editedName = State(initialValue: calendar.name)
        _editedColor = State(initialValue: calendar.colorName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(editedColor.color)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                TextField("Calendar Name", text: $editedName)
                    .onSubmit(saveEdits)

                Button(calendar.isVisible ? "Hide" : "Show", systemImage: calendar.isVisible ? "eye" : "eye.slash") {
                    store.toggleCalendarVisibility(calendar)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(calendar.isVisible ? "Hide \(calendar.name)" : "Show \(calendar.name)")
            }

            Text(futureEventCountLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Color", selection: $editedColor) {
                    ForEach(CalendarColorName.allCases) { colorName in
                        Text(colorName.rawValue).tag(colorName)
                    }
                }
                .onChange(of: editedColor) { _, _ in saveEdits() }

                Spacer()

                if calendar.isDefault {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Set Default") {
                        store.setDefaultCalendar(calendar)
                    }
                    .font(.footnote)
                }
            }

            Button("Delete Calendar", role: .destructive) {
                showDeleteConfirmation = true
            }
            .font(.footnote)
            .disabled(calendar.isDefault && store.calendars.count == 1)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete \"\(calendar.name)\"?", isPresented: $showDeleteConfirmation) {
            if let replacement = store.calendars.first(where: { $0.id != calendar.id }) {
                Button("Move Events to \(replacement.name)") {
                    store.deleteCalendar(calendar, moveEventsTo: replacement.id)
                }
            }
            Button("Delete Calendar and Events", role: .destructive) {
                store.deleteCalendar(calendar, moveEventsTo: nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Calendar deletion never silently deletes events. Choose whether to move or delete contained events.")
        }
    }

    private var futureEventCountLabel: String {
        let count = store.futureEventCount(for: calendar)
        return count == 1 ? "1 upcoming event" : "\(count) upcoming events"
    }

    private func saveEdits() {
        var updated = calendar
        updated.name = editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? calendar.name : editedName
        updated.colorName = editedColor
        store.updateCalendar(updated)
    }
}
