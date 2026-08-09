import SwiftUI

/// BC-VIEW-011, spec 1.9: chronological list grouped by date with sticky headers, all-day
/// occurrences before timed ones within a day, empty days simply omitted (only dates with
/// occurrences get a section), past-event de-emphasis, a "Today" jump, and a growing forward
/// window loaded in pages rather than the old fixed 90-day range — the past side stays a
/// modest fixed window since an agenda's job is showing what's coming up, not an unbounded
/// scrollback.
struct AgendaScreen: View {
    let store: BetterCalendarStore

    @State private var selectedOccurrence: CalendarOccurrence?
    @State private var editingEvent: CalendarEvent?
    @State private var isAddingEvent = false
    @State private var futureHorizon = Date.now.addingTimeInterval(AgendaScreen.initialFutureWindow)

    private static let pastWindow: TimeInterval = -7 * 24 * 60 * 60
    private static let initialFutureWindow: TimeInterval = 30 * 24 * 60 * 60
    private static let pageIncrement: TimeInterval = 30 * 24 * 60 * 60
    private static let maxFutureWindow: TimeInterval = 365 * 24 * 60 * 60

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(groupedSections, id: \.date) { section in
                        Section(header: Text(sectionTitle(for: section.date))) {
                            ForEach(section.occurrences) { occurrence in
                                Button {
                                    selectedOccurrence = occurrence
                                } label: {
                                    AgendaEventRow(
                                        occurrence: occurrence,
                                        calendar: calendar(for: occurrence.event),
                                        isPast: occurrence.occurrenceEndDate < .now
                                    )
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        store.deleteEvent(occurrence.event)
                                    }
                                }
                                .onAppear {
                                    if occurrence.id == lastOccurrenceID {
                                        extendFutureHorizonIfNeeded()
                                    }
                                }
                            }
                        }
                        .id(section.date)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("Agenda")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Today", systemImage: "calendar.circle") {
                            withAnimation {
                                proxy.scrollTo(todaySectionID, anchor: .top)
                            }
                        }

                        Button("Add Event", systemImage: "plus") {
                            isAddingEvent = true
                        }
                    }
                }
                .overlay {
                    if groupedSections.isEmpty {
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
    }

    private struct AgendaSection {
        let date: Date
        let occurrences: [CalendarOccurrence]
    }

    private var groupedSections: [AgendaSection] {
        _ = store.environmentRevision
        let now = Date.now
        let range = DateInterval(start: now.addingTimeInterval(Self.pastWindow), end: futureHorizon)
        let occurrences = store.visibleOccurrences(in: range)

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: occurrences) { calendar.startOfDay(for: $0.occurrenceStartDate) }

        return grouped.keys.sorted().map { date in
            let dayOccurrences = (grouped[date] ?? []).sorted { lhs, rhs in
                if lhs.event.isAllDay != rhs.event.isAllDay {
                    return lhs.event.isAllDay
                }
                if lhs.occurrenceStartDate == rhs.occurrenceStartDate {
                    return lhs.event.title < rhs.event.title
                }
                return lhs.occurrenceStartDate < rhs.occurrenceStartDate
            }
            return AgendaSection(date: date, occurrences: dayOccurrences)
        }
    }

    private var lastOccurrenceID: String? {
        groupedSections.last?.occurrences.last?.id
    }

    private var todaySectionID: Date {
        Calendar.current.startOfDay(for: .now)
    }

    private func extendFutureHorizonIfNeeded() {
        guard futureHorizon < Date.now.addingTimeInterval(Self.maxFutureWindow) else { return }
        futureHorizon = futureHorizon.addingTimeInterval(Self.pageIncrement)
    }

    private func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        store.calendars.first { $0.id == event.calendarID }
    }
}

private struct AgendaEventRow: View {
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?
    let isPast: Bool

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

                Text(event.isAllDay ? "All Day" : event.startDate.formatted(date: .omitted, time: .shortened))
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
        .opacity(isPast ? 0.5 : 1.0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.accessibilitySummary(calendarName: calendar?.name ?? "Local calendar"))
    }
}
