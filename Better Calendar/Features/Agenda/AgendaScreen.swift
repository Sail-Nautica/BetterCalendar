import SwiftUI

struct AgendaScreen: View {
    let store: BetterCalendarStore

    @State private var selectedOccurrence: CalendarOccurrence?
    @State private var editingEvent: CalendarEvent?
    @State private var isAddingEvent = false

    var body: some View {
        NavigationStack {
            List(sortedOccurrences) { occurrence in
                Button {
                    selectedOccurrence = occurrence
                } label: {
                    AgendaEventRow(occurrence: occurrence, calendar: calendar(for: occurrence.event))
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        store.deleteEvent(occurrence.event)
                    }
                }
            }
            .navigationTitle("Agenda")
            .toolbar {
                Button("Add Event", systemImage: "plus") {
                    isAddingEvent = true
                }
            }
            .overlay {
                if sortedOccurrences.isEmpty {
                    ContentUnavailableView(
                        "No upcoming events",
                        systemImage: "calendar.badge.plus",
                        description: Text("Add an event or import an ICS file to start planning locally.")
                    )
                }
            }
            .sheet(isPresented: $isAddingEvent) {
                if let calendarID = store.defaultCalendarID {
                    EventEditorView(calendars: store.calendars, draft: EventDraft(calendarID: calendarID), onSave: store.saveEvent)
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
                    onEditOccurrence: { occurrence in
                        selectedOccurrence = nil
                        editingEvent = store.eventForEditingOccurrence(occurrence)
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

    private var sortedOccurrences: [CalendarOccurrence] {
        _ = store.environmentRevision
        let now = Date.now
        let range = DateInterval(start: now.addingTimeInterval(-24 * 60 * 60), end: now.addingTimeInterval(90 * 24 * 60 * 60))
        return store.visibleOccurrences(in: range)
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        store.calendars.first { $0.id == event.calendarID }
    }
}

private struct AgendaEventRow: View {
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?

    var body: some View {
        let event = occurrence.displayEvent

        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(calendar?.colorName.color ?? .blue)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title)
                    .font(.headline)

                Text(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if occurrence.isRecurringOccurrence {
                    Label("Repeats", systemImage: "repeat")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let location = event.location {
                    Label(location, systemImage: "location")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.accessibilitySummary(calendarName: calendar?.name ?? "Local calendar"))
    }
}
