import SwiftUI

struct SearchScreen: View {
    let store: BetterCalendarStore

    @State private var query = ""
    @State private var selectedCalendarID: UUID?
    @State private var timeframe: SearchFilters.Timeframe = .all
    @State private var allDayOnly = false
    @State private var recurringOnly = false
    @State private var isDateRangeEnabled = false
    @State private var rangeStart = Calendar.current.startOfDay(for: .now)
    @State private var rangeEnd = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var selectedOccurrence: CalendarOccurrence?
    @State private var editingEvent: CalendarEvent?
    /// Spec 3D.5: set when the user picks "This and Future Events", and read by the editor's
    /// draft so the save applies the split at that occurrence instead of editing the master
    /// outright. Cleared whenever the editor closes, so it cannot leak into the next edit.
    @State private var futureSplitOccurrenceStart: Date?

    var body: some View {
        NavigationStack {
            List {
                if !store.calendars.isEmpty {
                    Section("Filters") {
                        Picker("Calendar", selection: $selectedCalendarID) {
                            Text("All Visible Calendars").tag(UUID?.none)
                            ForEach(store.calendars) { calendar in
                                Text(calendar.name).tag(Optional(calendar.id))
                            }
                        }

                        Picker("Timeframe", selection: $timeframe) {
                            Text("All").tag(SearchFilters.Timeframe.all)
                            Text("Upcoming").tag(SearchFilters.Timeframe.futureOnly)
                            Text("Past").tag(SearchFilters.Timeframe.pastOnly)
                        }

                        Toggle("All-Day Only", isOn: $allDayOnly)
                        Toggle("Recurring Only", isOn: $recurringOnly)

                        Toggle("Custom Date Range", isOn: $isDateRangeEnabled)
                        if isDateRangeEnabled {
                            DatePicker("From", selection: $rangeStart, displayedComponents: [.date])
                            DatePicker("To", selection: $rangeEnd, displayedComponents: [.date])
                        }
                    }
                }

                Section("Results") {
                    ForEach(results) { event in
                        Button {
                            selectedOccurrence = CalendarOccurrence(event: event)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.displayTitle)
                                    .font(.headline)

                                Text(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                if let notes = event.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search events")
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Search local events" : "No results",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty ? "Find events by title, location, or notes." : "Try a different title, location, or note keyword.")
                    )
                }
            }
            .sheet(item: $editingEvent) { event in
                EventEditorView(
                    calendars: store.calendars,
                    draft: scopedDraft(for: event),
                    event: event,
                    onSave: store.saveEvent,
                    onDelete: store.deleteEvent
                )
            }
            .onChange(of: editingEvent == nil) { _, isClosed in
                if isClosed { futureSplitOccurrenceStart = nil }
            }
            .sheet(item: $selectedOccurrence) { occurrence in
                EventDetailsView(
                    store: store,
                    occurrence: occurrence,
                    calendar: calendar(for: occurrence.event),
                    onEdit: { event in
                        selectedOccurrence = nil
                        editingEvent = event
                    },
                    onEditOccurrence: { occurrence in
                        selectedOccurrence = nil
                        editingEvent = store.eventForEditingOccurrence(occurrence)
                    },
                    onEditFuture: { occurrence in
                        selectedOccurrence = nil
                        futureSplitOccurrenceStart = occurrence.occurrenceStartDate
                        editingEvent = occurrence.event
                    },
                    onDelete: store.deleteEvent,
                    onDeleteOccurrence: store.deleteOccurrence,
                    onDuplicate: { event in
                        store.duplicateEvent(event, startDate: event.startDate)
                    },
                    onMove: store.moveEvent,
                    onResize: store.resizeEvent
                )
            }
        }
    }

    private var filters: SearchFilters {
        SearchFilters(
            calendarID: selectedCalendarID,
            dateRange: isDateRangeEnabled ? DateInterval(start: min(rangeStart, rangeEnd), end: max(rangeStart, rangeEnd)) : nil,
            timeframe: timeframe,
            allDayOnly: allDayOnly,
            recurringOnly: recurringOnly
        )
    }

    private var results: [CalendarEvent] {
        store.searchEvents(matching: query, filters: filters)
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        store.calendars.first { $0.id == event.calendarID }
    }

    /// Spec 3D.5: carries the "This and Future" choice from the confirmation dialog into the
    /// draft, so the save applies a split at that occurrence rather than editing the master.
    private func scopedDraft(for event: CalendarEvent) -> EventDraft {
        var draft = EventDraft(event: event)
        draft.scopedSplitOccurrenceStart = futureSplitOccurrenceStart
        return draft
    }

}
