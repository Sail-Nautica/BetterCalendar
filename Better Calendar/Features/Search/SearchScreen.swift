import SwiftUI

struct SearchScreen: View {
    let store: BetterCalendarStore

    @State private var query = ""
    @State private var selectedCalendarID: UUID?
    @State private var selectedOccurrence: CalendarOccurrence?
    @State private var editingEvent: CalendarEvent?

    var body: some View {
        NavigationStack {
            List {
                if !store.calendars.isEmpty {
                    Section("Scope") {
                        Picker("Calendar", selection: $selectedCalendarID) {
                            Text("All Visible Calendars").tag(UUID?.none)
                            ForEach(store.calendars) { calendar in
                                Text(calendar.name).tag(Optional(calendar.id))
                            }
                        }
                    }
                }

                Section("Results") {
                    ForEach(results) { event in
                        Button {
                            selectedOccurrence = CalendarOccurrence(event: event)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.title)
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
                    draft: EventDraft(event: event),
                    event: event,
                    onSave: store.saveEvent,
                    onDelete: store.deleteEvent
                )
            }
            .sheet(item: $selectedOccurrence) { occurrence in
                EventDetailsView(
                    occurrence: occurrence,
                    calendar: calendar(for: occurrence.event),
                    onEdit: { event in
                        selectedOccurrence = nil
                        editingEvent = event
                    },
                    onDelete: store.deleteEvent,
                    onDuplicate: { event in
                        store.duplicateEvent(event, startDate: event.startDate)
                    },
                    onMove: store.moveEvent,
                    onResize: store.resizeEvent
                )
            }
        }
    }

    private var results: [CalendarEvent] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let scopedEvents = selectedCalendarID.map { calendarID in
            store.events.filter { $0.calendarID == calendarID }
        } ?? store.visibleEvents

        return scopedEvents.filter { event in
            event.title.localizedCaseInsensitiveContains(trimmedQuery)
                || (event.location?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (event.notes?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
        .sorted { lhs, rhs in
            if lhs.startDate >= .now && rhs.startDate < .now { return true }
            return lhs.startDate < rhs.startDate
        }
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        store.calendars.first { $0.id == event.calendarID }
    }
}
