import SwiftUI

struct EventEditorView: View {
    let calendars: [BetterCalendar]
    let initialDraft: EventDraft
    let onSave: (EventDraft) -> Bool
    let onDelete: ((CalendarEvent) -> Void)?
    let event: CalendarEvent?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var validationError: String?
    @State private var showDiscardConfirmation = false
    @State private var preservesDuration = true
    @State private var isProgrammaticallyUpdatingEndDate = false

    init(
        calendars: [BetterCalendar],
        draft: EventDraft,
        event: CalendarEvent? = nil,
        onSave: @escaping (EventDraft) -> Bool,
        onDelete: ((CalendarEvent) -> Void)? = nil
    ) {
        self.calendars = calendars
        self.initialDraft = draft
        self.event = event
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                        .font(.headline)
                        .submitLabel(.done)
                        .onSubmit(save)
                }

                Section("When") {
                    Toggle("All-day", isOn: $draft.isAllDay)
                        .onChange(of: draft.isAllDay) { _, isAllDay in
                            if isAllDay {
                                convertTimedEventToAllDay()
                            } else {
                                convertAllDayEventToTimed()
                            }
                        }

                    DatePicker("Start", selection: $draft.startDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: draft.startDate) { oldValue, newValue in
                            preserveDurationAfterStartChange(from: oldValue, to: newValue)
                        }

                    DatePicker("End", selection: $draft.endDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: draft.endDate) { _, _ in
                            if !isProgrammaticallyUpdatingEndDate {
                                preservesDuration = false
                            }
                        }

                    Picker("Time Zone", selection: $draft.timeZoneIdentifier) {
                        ForEach(timeZoneOptions, id: \.self) { identifier in
                            Text(timeZoneLabel(identifier)).tag(identifier)
                        }
                    }
                }

                Section("Calendar") {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(calendars) { calendar in
                            Label(calendar.name, systemImage: calendar.isDefault ? "checkmark.circle.fill" : "circle.fill")
                                .tag(calendar.id)
                        }
                    }
                }

                Section("Repeat") {
                    Picker("Repeat", selection: $draft.recurrence.frequency) {
                        ForEach(RecurrenceFrequency.allCases) { frequency in
                            Text(frequency.label).tag(frequency)
                        }
                    }

                    if draft.recurrence.frequency != .never {
                        Stepper("Every \(draft.recurrence.interval) \(draft.recurrence.frequency.pluralLabel)", value: $draft.recurrence.interval, in: 1...30)
                        Text(draft.recurrence.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Reminder") {
                    Picker("Reminder", selection: $draft.reminderOffset) {
                        ForEach(ReminderOffset.allCases) { offset in
                            Text(offset.label).tag(offset)
                        }
                    }
                }

                Section("Details") {
                    TextField("Location", text: $draft.location)
                    #if os(macOS)
                    TextField("URL", text: $draft.urlString)
                    #else
                    TextField("URL", text: $draft.urlString)
                        .textInputAutocapitalization(.never)
                    #endif
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let event, let onDelete {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            onDelete(event)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(event == nil ? "Add Event" : "Edit Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft == initialDraft {
                            dismiss()
                        } else {
                            showDiscardConfirmation = true
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(draft.validationError != nil)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirmation) {
                Button("Discard Changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) { }
            }
        }
    }

    private func save() {
        if let error = draft.validationError {
            validationError = error
            return
        }

        if onSave(draft) {
            dismiss()
        } else {
            validationError = "Event could not be saved. Check the fields and try again."
        }
    }

    private var timeZoneOptions: [String] {
        var identifiers = [
            TimeZone.current.identifier,
            draft.timeZoneIdentifier,
            "America/Detroit",
            "America/New_York",
            "America/Chicago",
            "America/Denver",
            "America/Los_Angeles",
            "UTC"
        ]
        var seen: Set<String> = []
        identifiers.removeAll { identifier in
            if seen.contains(identifier) { return true }
            seen.insert(identifier)
            return false
        }
        return identifiers
    }

    private func timeZoneLabel(_ identifier: String) -> String {
        if identifier == TimeZone.current.identifier {
            return "Current (\(identifier))"
        }
        return identifier
    }

    private func preserveDurationAfterStartChange(from oldStartDate: Date, to newStartDate: Date) {
        guard preservesDuration else { return }
        let duration = max(draft.endDate.timeIntervalSince(oldStartDate), draft.isAllDay ? 24 * 60 * 60 : 15 * 60)
        isProgrammaticallyUpdatingEndDate = true
        draft.endDate = newStartDate.addingTimeInterval(duration)
        isProgrammaticallyUpdatingEndDate = false
    }

    private func convertTimedEventToAllDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
        let startOfDay = calendar.startOfDay(for: draft.startDate)
        isProgrammaticallyUpdatingEndDate = true
        draft.startDate = startOfDay
        draft.endDate = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? draft.endDate
        isProgrammaticallyUpdatingEndDate = false
        preservesDuration = true
    }

    private func convertAllDayEventToTimed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
        let localDate = calendar.dateComponents([.year, .month, .day], from: draft.startDate)
        var startComponents = localDate
        startComponents.hour = 9
        startComponents.minute = 0
        let timedStart = calendar.date(from: startComponents) ?? draft.startDate
        isProgrammaticallyUpdatingEndDate = true
        draft.startDate = timedStart
        draft.endDate = timedStart.addingTimeInterval(60 * 60)
        isProgrammaticallyUpdatingEndDate = false
        preservesDuration = true
    }
}
