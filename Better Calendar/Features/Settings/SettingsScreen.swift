import SwiftUI

/// Surfaces every BC-SET-001 key (spec 1.20), plus data-management actions and (debug-only)
/// diagnostics. Each control writes straight through `store.updateSettings`, matching how every
/// other screen mutates the store — there is no local draft/save step here since settings are
/// low-stakes, single-field edits.
struct SettingsScreen: View {
    let store: BetterCalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAllConfirmation = false
    @State private var pendingNotificationCount: Int?

    private static let snapIntervalOptions = [5, 10, 15, 30, 60]
    private static let durationOptions = [15, 30, 45, 60, 90, 120]

    /// Spec 2.20 diagnostics: rows not yet finalized one way or the other.
    private var outboxDepth: Int {
        store.pendingMutations.filter { $0.status == .pending || $0.status == .inFlight }.count
    }

    private var failedMutationCount: Int {
        store.pendingMutations.filter { $0.status == .failed }.count
    }

    /// A one-word answer on the Settings row itself, so a stuck queue is visible without
    /// opening the screen that explains it.
    private var syncStatusSummary: String {
        let stuck = store.outboxRowsNeedingAttention.count
        if stuck > 0 { return "\(stuck) need\(stuck == 1 ? "s" : "") attention" }
        let waiting = (store.outboxDepthByStatus[.pending] ?? 0) + (store.outboxDepthByStatus[.inFlight] ?? 0)
        return waiting > 0 ? "\(waiting) waiting" : "Up to date"
    }

    private var repositoryDiagnostics: RepositoryDiagnostics {
        store.repositoryDiagnostics()
    }

    private var discoverySummaryText: String {
        guard let summary = store.lastDiscoverySummary else { return "—" }
        return "+\(summary.added) ~\(summary.updated) ↩\(summary.reconnected) ✕\(summary.markedUnavailable) =\(summary.unchanged)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Defaults") {
                    // Spec 3.9 (BC-EK-019): the default destination spans every writable
                    // calendar, local and device, and never offers a read-only or unavailable
                    // one.
                    if !store.writableDestinationCalendars.isEmpty {
                        Picker("Default Calendar", selection: defaultCalendarBinding) {
                            ForEach(store.writableDestinationCalendars) { calendar in
                                Text(calendar.destinationLabel).tag(calendar.id)
                            }
                        }
                    }

                    Picker("Default Duration", selection: defaultDurationBinding) {
                        ForEach(Self.durationOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }

                    Picker("Default Reminder", selection: defaultReminderBinding) {
                        ForEach(ReminderOffset.allCases) { offset in
                            Text(offset.label).tag(offset)
                        }
                    }
                }

                Section("Calendar Display") {
                    Picker("First Day of Week", selection: firstWeekdayBinding) {
                        Text("System Default").tag(Weekday?.none)
                        ForEach(Weekday.allCases) { weekday in
                            Text(weekday.shortLabel).tag(Weekday?.some(weekday))
                        }
                    }

                    Toggle("Show Weekends", isOn: boolBinding(\.showWeekends))

                    Picker("Time Format", selection: enumBinding(\.timeFormat)) {
                        ForEach(TimeFormatPreference.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }

                    Picker("Default View", selection: enumBinding(\.defaultCalendarView)) {
                        ForEach(CalendarViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("Appearance", selection: enumBinding(\.appearance)) {
                        ForEach(AppearancePreference.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }

                    Toggle("Reduce Calendar Animation", isOn: boolBinding(\.reduceCalendarAnimation))
                }

                Section("Time Zone") {
                    NavigationLink {
                        TimeZoneSearchView(selection: secondaryTimeZoneBinding)
                    } label: {
                        LabeledContent("Secondary Time Zone", value: store.settings.secondaryTimeZoneIdentifier ?? "None")
                    }

                    if store.settings.secondaryTimeZoneIdentifier != nil {
                        Button("Clear Secondary Time Zone", role: .destructive) {
                            store.updateSettings { $0.secondaryTimeZoneIdentifier = nil }
                        }
                    }
                }

                Section("Notifications") {
                    Stepper(
                        "All-Day Reminder Time: \(formattedHour(store.settings.allDayReminderHour))",
                        value: intBinding(\.allDayReminderHour),
                        in: 0...23
                    )

                    Picker("Snap Interval", selection: intBinding(\.snapIntervalMinutes)) {
                        ForEach(Self.snapIntervalOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }

                // Spec 3D.8: `SRC-STAT-01`. Outside `#if DEBUG`, unlike the diagnostics section
                // below — spec 3.21 requires a failed or conflicted change stay findable by the
                // user whose change it was, not only by whoever is holding a debug build.
                Section("Sync") {
                    NavigationLink {
                        SyncStatusScreen(store: store)
                    } label: {
                        LabeledContent("Sync Status", value: syncStatusSummary)
                    }
                }

                Section("Data") {
                    NavigationLink("Export / Import Data") {
                        ImportExportView(store: store)
                    }

                    Button("Delete All Local Data", role: .destructive) {
                        showDeleteAllConfirmation = true
                    }
                }

#if DEBUG
                Section("Diagnostics") {
                    LabeledContent("Schema Version", value: "\(LocalCalendarDatabase.currentSchemaVersion)")
                    LabeledContent("Event Count", value: "\(store.events.count)")
                    LabeledContent("Recurrence Master Count", value: "\(store.events.filter { $0.recurrence != nil }.count)")
                    LabeledContent("Pending Notification Count", value: pendingNotificationCount.map(String.init) ?? "—")
                    LabeledContent("Outbox Depth", value: "\(outboxDepth)")
                    LabeledContent("Calendar Access", value: store.calendarAccessStatus.rawValue)
                    LabeledContent("Device Calendars", value: "\(store.deviceCalendars.count)")
                    // Spec 3.24: counts, never content.
                    LabeledContent("Last Discovery", value: discoverySummaryText)
                    LabeledContent("Failed Mutation Count", value: "\(failedMutationCount)")
                    LabeledContent("Journal Size", value: repositoryDiagnostics.changeJournalRowCount.map(String.init) ?? "—")
                    LabeledContent("Last Applied Migration", value: repositoryDiagnostics.lastAppliedMigrationIdentifier ?? "—")
                    LabeledContent("Migration Checksum", value: repositoryDiagnostics.migrationChecksum ?? "—")

                    Button("Reconcile Notifications") {
                        store.reconcileAllNotifications()
                    }

                    Button("Load Sample Calendar") {
                        store.loadSampleData()
                    }

                    Button("Reset Database", role: .destructive) {
                        store.deleteAllLocalData()
                    }
                }
#endif
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
            .task {
                pendingNotificationCount = await store.pendingNotificationCount()
            }
            .confirmationDialog(
                "Delete all local data?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    store.deleteAllLocalData()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes every local calendar and event on this device. This cannot be undone.")
            }
        }
    }

    private var secondaryTimeZoneBinding: Binding<String> {
        Binding(
            get: { store.settings.secondaryTimeZoneIdentifier ?? TimeZone.current.identifier },
            set: { newValue in store.updateSettings { $0.secondaryTimeZoneIdentifier = newValue } }
        )
    }

    private var defaultCalendarBinding: Binding<UUID> {
        Binding(
            get: { store.defaultCalendarID ?? store.calendars.first?.id ?? UUID() },
            set: { newID in
                guard let calendar = store.calendars.first(where: { $0.id == newID }) else { return }
                store.setDefaultCalendar(calendar)
            }
        )
    }

    private var defaultDurationBinding: Binding<Int> {
        Binding(
            get: { store.settings.defaultEventDurationMinutes },
            set: { newValue in store.updateSettings { $0.defaultEventDurationMinutes = newValue } }
        )
    }

    private var defaultReminderBinding: Binding<ReminderOffset> {
        Binding(
            get: { store.settings.defaultReminderOffset ?? .none },
            set: { newValue in
                store.updateSettings { $0.defaultReminderOffset = newValue == .none ? nil : newValue }
            }
        )
    }

    private var firstWeekdayBinding: Binding<Weekday?> {
        Binding(
            get: { store.settings.firstWeekday },
            set: { newValue in store.updateSettings { $0.firstWeekday = newValue } }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in store.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in store.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func enumBinding<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in store.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func formattedHour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let calendar = Calendar.current
        let date = calendar.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
