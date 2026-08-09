import SwiftUI

/// The 8 recurrence presets spec 1.11 lists, layered over the raw `RecurrenceRule` fields.
/// "Every 2 Weeks" and "Every Weekday" aren't distinct `RecurrenceFrequency` cases — they're
/// just recognizable shapes of `weekly` (interval 2, and weekdays == Mon–Fri) — so this is a
/// view-only concept, derived from and applied back onto the draft's rule.
private enum RecurrencePreset: String, CaseIterable, Identifiable {
    case never, daily, weekly, everyTwoWeeks, monthly, yearly, everyWeekday, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        case .everyTwoWeeks: "Every 2 Weeks"
        case .monthly: "Every Month"
        case .yearly: "Every Year"
        case .everyWeekday: "Every Weekday"
        case .custom: "Custom"
        }
    }
}

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
                    Picker("Repeat", selection: presetBinding) {
                        ForEach(RecurrencePreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }

                    if currentPreset == .custom {
                        customRecurrenceControls
                    }

                    if draft.recurrence.frequency != .never {
                        endConditionControls
                        Text(draft.recurrence.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Reminders") {
                    ForEach(draft.reminderOffsets, id: \.self) { offset in
                        Text(offset.label)
                    }
                    .onDelete { offsets in
                        draft.reminderOffsets.remove(atOffsets: offsets)
                    }

                    if !availableReminderOffsets.isEmpty {
                        Menu {
                            ForEach(availableReminderOffsets) { offset in
                                Button(offset.label) {
                                    draft.reminderOffsets.append(offset)
                                }
                            }
                        } label: {
                            Label("Add Reminder", systemImage: "plus.circle")
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

    // MARK: - Recurrence (BC-REC-011, spec 1.11)

    /// Which of the 8 spec-1.11 presets `draft.recurrence`'s raw fields currently match, if
    /// any — anything that doesn't match a preset exactly falls through to `.custom`, which is
    /// also what's shown while the user is actively editing custom fields.
    private var currentPreset: RecurrencePreset {
        let recurrence = draft.recurrence
        guard recurrence.daysOfMonth.isEmpty, recurrence.setPositions.isEmpty else { return .custom }

        switch recurrence.frequency {
        case .never:
            return .never
        case .daily:
            return recurrence.interval == 1 ? .daily : .custom
        case .weekly:
            if recurrence.interval == 1 && recurrence.weekdays.isEmpty { return .weekly }
            if recurrence.interval == 2 && recurrence.weekdays.isEmpty { return .everyTwoWeeks }
            if recurrence.interval == 1 && recurrence.weekdays == Weekday.weekdays { return .everyWeekday }
            return .custom
        case .monthly:
            return recurrence.interval == 1 ? .monthly : .custom
        case .yearly:
            return recurrence.interval == 1 ? .yearly : .custom
        }
    }

    private var presetBinding: Binding<RecurrencePreset> {
        Binding(get: { currentPreset }, set: { applyPreset($0) })
    }

    private func applyPreset(_ preset: RecurrencePreset) {
        let end = draft.recurrence.end
        switch preset {
        case .never:
            draft.recurrence = .never
        case .daily:
            draft.recurrence = RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], end: end)
        case .weekly:
            draft.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [], end: end)
        case .everyTwoWeeks:
            draft.recurrence = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [], end: end)
        case .monthly:
            draft.recurrence = RecurrenceRule(frequency: .monthly, interval: 1, weekdays: [], end: end)
        case .yearly:
            draft.recurrence = RecurrenceRule(frequency: .yearly, interval: 1, weekdays: [], end: end)
        case .everyWeekday:
            draft.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: Weekday.weekdays, end: end)
        case .custom:
            if draft.recurrence.frequency == .never {
                draft.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [], end: end)
            }
        }
    }

    @ViewBuilder
    private var customRecurrenceControls: some View {
        Picker("Frequency", selection: $draft.recurrence.frequency) {
            ForEach(RecurrenceFrequency.allCases.filter { $0 != .never }) { frequency in
                Text(frequency.label).tag(frequency)
            }
        }

        Stepper("Every \(draft.recurrence.interval) \(draft.recurrence.frequency.pluralLabel)", value: $draft.recurrence.interval, in: 1...30)

        if draft.recurrence.frequency == .weekly {
            weekdaySelector
        }

        if draft.recurrence.frequency == .monthly || draft.recurrence.frequency == .yearly {
            monthlyPatternControls
        }
    }

    private var weekdaySelector: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases) { weekday in
                let isSelected = draft.recurrence.weekdays.contains(weekday)
                Button {
                    if isSelected {
                        draft.recurrence.weekdays.remove(weekday)
                    } else {
                        draft.recurrence.weekdays.insert(weekday)
                    }
                } label: {
                    Text(weekday.shortLabel.prefix(2))
                        .font(.caption)
                        .frame(minWidth: 32)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .secondary)
            }
        }
        .accessibilityLabel("Repeat on weekdays")
    }

    private enum MonthlyPattern: Hashable {
        case dayOfMonth
        case dayOfWeek
    }

    private var monthlyPatternBinding: Binding<MonthlyPattern> {
        Binding(
            get: { draft.recurrence.setPositions.isEmpty ? .dayOfMonth : .dayOfWeek },
            set: { newValue in
                switch newValue {
                case .dayOfMonth:
                    draft.recurrence.setPositions = []
                    if draft.recurrence.daysOfMonth.isEmpty {
                        draft.recurrence.daysOfMonth = [Calendar.current.component(.day, from: draft.startDate)]
                    }
                case .dayOfWeek:
                    draft.recurrence.daysOfMonth = []
                    if draft.recurrence.setPositions.isEmpty {
                        draft.recurrence.setPositions = [1]
                    }
                    if draft.recurrence.weekdays.isEmpty {
                        let weekdayValue = Calendar.current.component(.weekday, from: draft.startDate)
                        draft.recurrence.weekdays = Set([Weekday(rawValue: weekdayValue)].compactMap { $0 })
                    }
                }
            }
        )
    }

    private var dayOfMonthBinding: Binding<Int> {
        Binding(
            get: { draft.recurrence.daysOfMonth.first ?? Calendar.current.component(.day, from: draft.startDate) },
            set: { draft.recurrence.daysOfMonth = [$0] }
        )
    }

    private var setPositionBinding: Binding<Int> {
        Binding(
            get: { draft.recurrence.setPositions.first ?? 1 },
            set: { draft.recurrence.setPositions = [$0] }
        )
    }

    private var positionalWeekdayBinding: Binding<Weekday> {
        Binding(
            get: { draft.recurrence.weekdays.first ?? .monday },
            set: { draft.recurrence.weekdays = [$0] }
        )
    }

    @ViewBuilder
    private var monthlyPatternControls: some View {
        Picker("Pattern", selection: monthlyPatternBinding) {
            Text("Day of Month").tag(MonthlyPattern.dayOfMonth)
            Text("Day of Week").tag(MonthlyPattern.dayOfWeek)
        }

        switch monthlyPatternBinding.wrappedValue {
        case .dayOfMonth:
            Stepper("Day \(dayOfMonthBinding.wrappedValue)", value: dayOfMonthBinding, in: 1...31)
        case .dayOfWeek:
            Picker("Occurrence", selection: setPositionBinding) {
                ForEach([1, 2, 3, 4, -1], id: \.self) { position in
                    Text(position.ordinalLabel).tag(position)
                }
            }
            Picker("Weekday", selection: positionalWeekdayBinding) {
                ForEach(Weekday.allCases) { weekday in
                    Text(weekday.shortLabel).tag(weekday)
                }
            }
        }
    }

    private enum EndOption: Hashable {
        case never
        case afterCount
        case onDate
    }

    private var endOptionBinding: Binding<EndOption> {
        Binding(
            get: {
                switch draft.recurrence.end {
                case .never: .never
                case .afterOccurrences: .afterCount
                case .onDate: .onDate
                }
            },
            set: { newValue in
                switch newValue {
                case .never:
                    draft.recurrence.end = .never
                case .afterCount:
                    draft.recurrence.end = .afterOccurrences(occurrenceCountBinding.wrappedValue)
                case .onDate:
                    draft.recurrence.end = .onDate(endDateBinding.wrappedValue)
                }
            }
        )
    }

    private var occurrenceCountBinding: Binding<Int> {
        Binding(
            get: {
                if case .afterOccurrences(let count) = draft.recurrence.end { return count }
                return 12
            },
            set: { draft.recurrence.end = .afterOccurrences($0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: {
                if case .onDate(let date) = draft.recurrence.end { return date }
                return draft.startDate.addingTimeInterval(30 * 24 * 60 * 60)
            },
            set: { draft.recurrence.end = .onDate($0) }
        )
    }

    @ViewBuilder
    private var endConditionControls: some View {
        Picker("Ends", selection: endOptionBinding) {
            Text("Never").tag(EndOption.never)
            Text("After").tag(EndOption.afterCount)
            Text("On Date").tag(EndOption.onDate)
        }

        switch endOptionBinding.wrappedValue {
        case .never:
            EmptyView()
        case .afterCount:
            Stepper("\(occurrenceCountBinding.wrappedValue) occurrences", value: occurrenceCountBinding, in: 1...999)
        case .onDate:
            DatePicker("End Date", selection: endDateBinding, displayedComponents: [.date])
        }
    }

    private var availableReminderOffsets: [ReminderOffset] {
        ReminderOffset.allCases.filter { $0 != .none && !draft.reminderOffsets.contains($0) }
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
