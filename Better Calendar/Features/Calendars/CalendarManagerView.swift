import SwiftUI

struct CalendarManagerView: View {
    let store: BetterCalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var newCalendarName = ""
    @State private var newCalendarColor: CalendarColorName = .betterBlue

    var body: some View {
        NavigationStack {
            List {
                Section("My Calendars") {
                    ForEach(store.localCalendars) { calendar in
                        CalendarManagerRow(calendar: calendar, store: store, isEditing: isEditing)
                    }
                    .onMove { source, destination in
                        store.reorderCalendars(fromOffsets: source, toOffset: destination)
                    }
                }

                // Creating, renaming, recolouring, hiding, defaulting and deleting are all edit
                // affordances, so they sit behind the same Edit toggle that reveals the reorder
                // handles rather than cluttering the list you are only reading.
                if isEditing {
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
                        .buttonStyle(.borderless)
                        .disabled(newCalendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // Spec 3B.8: device calendars live on their own screen rather than in the
                // list above, because almost nothing the manager offers a local calendar —
                // rename, recolour, reorder, delete — may be done to one. This row is the entry
                // point; `SRC-LIST-01` owns the access states and the visibility toggles.
                // Spec 3.29 names the calendar manager as where the choice is changeable, so the
                // entry point is here as well as on `SRC-LIST-01`.
                if !store.allDuplicateConnections.isEmpty {
                    Section("Connections") {
                        NavigationLink {
                            ConnectionChoiceView(store: store)
                        } label: {
                            LabeledContent(
                                "Duplicate Connections",
                                value: store.unresolvedDuplicateConnections.isEmpty ? "Resolved" : "\(store.unresolvedDuplicateConnections.count) to choose"
                            )
                        }
                    }
                }

                Section("Device Calendars") {
                    NavigationLink {
                        DeviceCalendarsView(store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceCalendarSummary.title)
                            Text(deviceCalendarSummary.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
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
                                .buttonStyle(.borderless)
                                .disabled(tombstone.eventSnapshotJSON == nil)
                            }
                        }
                    }
                }

                Section("Data") {
                    NavigationLink("Import / Export") {
                        ImportExportView(store: store)
                    }
                }
            }
            // Spec 3.4: authorization is re-read whenever a device-calendar surface appears,
            // never cached from launch — the user may have changed it in Settings since. On the
            // `List` rather than on the row, because a row below the fold would not trigger the
            // read until it scrolled into view, and the summary above is what it feeds.
            .task {
                store.refreshDeviceCalendarAccess()
            }
            .calendarListEditMode($isEditing)
            .navigationTitle("Calendars")
            .toolbar {
                // A plain `Button` rather than `EditButton`, which does not exist on macOS —
                // that is why the Edit affordance was missing there entirely. Owning the flag
                // here is also what lets the same toggle gate the per-row controls.
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation {
                            isEditing.toggle()
                        }
                    }
                    .accessibilityLabel(isEditing ? "Finish editing calendars" : "Edit calendars")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Close calendars")
                }
            }
        }
        // `SRC-PERM-01` is presented by `SRC-LIST-01`, which owns every access state — spec 3.3
        // forbids reaching the system prompt from anywhere else, and one owner is how that stays
        // true.
        // Keeps the sheet a stable size across pushes (e.g. Import / Export).
        .macSheetFrame()
    }

    /// What the entry row says before the user opens it: the access state when there is nothing
    /// to count, and counts once there is.
    private var deviceCalendarSummary: (title: String, detail: String) {
        let access = store.deviceCalendarAccess
        guard access.canReadDeviceEvents else {
            return (access.message.title, access.message.message)
        }

        let accounts = store.deviceCalendarAccounts
        guard !accounts.isEmpty else {
            return ("Connected", "No calendars on this device yet.")
        }

        let calendars = store.deviceCalendars
        let shown = calendars.filter { $0.isVisible && !$0.isUnavailable }.count
        let calendarLabel = calendars.count == 1 ? "1 calendar" : "\(calendars.count) calendars"
        let accountLabel = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
        return ("\(calendarLabel) from \(accountLabel)", "\(shown) shown")
    }
}

private struct CalendarManagerRow: View {
    let calendar: BetterCalendar
    let store: BetterCalendarStore
    let isEditing: Bool

    @State private var editedName: String
    @State private var editedColor: CalendarColorName
    @State private var showDeleteConfirmation = false

    init(calendar: BetterCalendar, store: BetterCalendarStore, isEditing: Bool) {
        self.calendar = calendar
        self.store = store
        self.isEditing = isEditing
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

                if isEditing {
                    TextField("Calendar Name", text: $editedName)
                        .onSubmit(saveEdits)

                    Button(calendar.isVisible ? "Hide" : "Show", systemImage: calendar.isVisible ? "eye" : "eye.slash") {
                        store.toggleCalendarVisibility(calendar)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(calendar.isVisible ? "Hide \(calendar.name)" : "Show \(calendar.name)")
                } else {
                    Text(calendar.name)

                    Spacer(minLength: 8)
                }
            }

            // Default and hidden stay legible outside edit mode, where their controls are gone.
            Text(statusLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isEditing {
                HStack {
                    Picker("Color", selection: $editedColor) {
                        ForEach(CalendarColorName.allCases) { colorName in
                            Text(colorName.rawValue).tag(colorName)
                        }
                    }
                    .onChange(of: editedColor) { _, _ in saveEdits() }

                    Spacer()

                    if !calendar.isDefault {
                        Button("Set Default") {
                            store.setDefaultCalendar(calendar)
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    }
                }

                Button("Delete Calendar", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .disabled(calendar.isDefault && store.localCalendars.count == 1)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: isEditing) { _, editing in
            // Leaving edit mode takes the text field with it, so commit whatever was typed but
            // never submitted; entering picks up any change made elsewhere in the meantime.
            if editing {
                editedName = calendar.name
                editedColor = calendar.colorName
            } else {
                saveEdits()
            }
        }
        .confirmationDialog("Delete \"\(calendar.name)\"?", isPresented: $showDeleteConfirmation) {
            if let replacement = store.localCalendars.first(where: { $0.id != calendar.id }) {
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

    private var statusLabel: String {
        let count = store.futureEventCount(for: calendar)
        var parts = [count == 1 ? "1 upcoming event" : "\(count) upcoming events"]
        if calendar.isDefault {
            parts.append("Default")
        }
        if !calendar.isVisible {
            parts.append("Hidden")
        }
        return parts.joined(separator: " · ")
    }

    private func saveEdits() {
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = calendar
        updated.name = trimmedName.isEmpty ? calendar.name : trimmedName
        updated.colorName = editedColor
        guard updated.name != calendar.name || updated.colorName != calendar.colorName else { return }
        store.updateCalendar(updated)
    }
}

private extension View {
    /// Drives the list's edit mode from a plain `Bool` so one flag gates both the row controls
    /// and `.onMove` reordering. macOS has no `EditMode` — rows there reorder by dragging
    /// without one — so this is a no-op off iOS.
    @ViewBuilder
    func calendarListEditMode(_ isEditing: Binding<Bool>) -> some View {
#if canImport(UIKit)
        environment(\.editMode, Binding(
            get: { isEditing.wrappedValue ? EditMode.active : EditMode.inactive },
            set: { isEditing.wrappedValue = $0.isEditing }
        ))
#else
        self
#endif
    }
}
