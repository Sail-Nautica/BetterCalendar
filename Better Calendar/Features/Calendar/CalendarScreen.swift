import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct CalendarScreen: View {
    let store: BetterCalendarStore
    @Binding var viewMode: CalendarViewMode

    @State private var selectedDate: Date
    @State private var selectedOccurrence: CalendarOccurrence?
    @State private var editingEvent: CalendarEvent?
    /// Spec 3D.5: set when the user picks "This and Future Events", and read by the editor's
    /// draft so the save applies the split at that occurrence instead of editing the master
    /// outright. Cleared whenever the editor closes, so it cannot leak into the next edit.
    @State private var futureSplitOccurrenceStart: Date?
    @State private var isAddingEvent = false
    @State private var newEventStartDate = Date.now
    @State private var isShowingCalendars = false
    @State private var isChoosingDate = false
    @State private var isShowingSettings = false
    /// Bumped every time the user asks to return to today, so the week view can re-align even
    /// when `selectedDate` itself does not change (tapping Today while already on today).
    @State private var todayAlignmentToken = 0

    init(store: BetterCalendarStore, viewMode: Binding<CalendarViewMode>) {
        self.store = store
        self._viewMode = viewMode
        // The calendar always opens on the current day. `settings.lastSelectedDate` is still
        // recorded (BC-VIEW-010, spec 1.2) for anything else that wants the last view state,
        // but it is deliberately not restored here — launching onto a stale date read as a bug.
        self._selectedDate = State(initialValue: Date.now)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Calendar View", selection: $viewMode) {
                    ForEach(CalendarViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                DateNavigationStrip(
                    selectedDate: selectedDate,
                    viewMode: viewMode,
                    title: navigationTitle,
                    onPrevious: { moveSelection(by: -1) },
                    onNext: { moveSelection(by: 1) },
                    onToday: { goToToday(alignWeekToToday: true) },
                    onChooseDate: { isChoosingDate = true }
                )

                switch viewMode {
                case .day:
                    DayCalendarView(
                        occurrences: selectedDateOccurrences,
                        calendars: store.calendars,
                        selectedDate: selectedDate,
                        onSelect: { selectedOccurrence = $0 },
                        onCreate: beginAddingEvent,
                        onMove: moveOccurrence,
                        onResize: resizeOccurrence
                    )
                case .week:
                    WeekCalendarView(
                        occurrences: visibleWeekOccurrences,
                        calendars: store.calendars,
                        selectedDate: $selectedDate,
                        todayAlignmentToken: todayAlignmentToken,
                        onSelect: { selectedOccurrence = $0 },
                        onCreate: beginAddingEvent,
                        onMove: moveOccurrence
                    )
                case .month:
                    MonthCalendarView(
                        occurrences: visibleMonthOccurrences,
                        calendars: store.calendars,
                        selectedDate: $selectedDate,
                        onSelect: { selectedOccurrence = $0 },
                        onCreate: beginAddingEvent
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(calendarPageDragGesture)
            .navigationTitle(viewMode.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }

                    Button("Calendars", systemImage: "calendar.badge.checkmark") {
                        isShowingCalendars = true
                    }

                    Button("Add Event", systemImage: "plus") {
                        beginAddingEvent(at: defaultEventStartDate(on: selectedDate))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $isAddingEvent) {
                editor(for: nil, startDate: newEventStartDate)
            }
            .onChange(of: editingEvent == nil) { _, isClosed in
                if isClosed { futureSplitOccurrenceStart = nil }
            }
            // Spec 3.23's fourth trigger: the visible date range moving outside the mirrored
            // window. Called on every change of the selected date because it costs nothing while
            // the range stays inside what has already been reconciled, which is almost always.
            .onChange(of: selectedDate) { _, newDate in
                store.visibleRangeDidChange(to: Self.mirrorRange(around: newDate))
            }
            .sheet(item: $editingEvent) { event in
                editor(for: event, startDate: event.startDate)
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
            .sheet(isPresented: $isShowingCalendars) {
                CalendarManagerView(store: store)
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsScreen(store: store)
            }
            .sheet(isPresented: $isChoosingDate) {
                DatePickerNavigationSheet(selectedDate: $selectedDate, viewMode: viewMode)
            }
            .onChange(of: viewMode) { _, _ in
                // Switching between Day/Week/Month always lands on the current day; the week
                // view keeps its natural leading edge (the start of the week) on a mode switch.
                goToToday(alignWeekToToday: false)
            }
            .onChange(of: selectedDate) { _, newDate in
                store.updateLastViewState(date: newDate)
            }
            .onAppear {
                PrivacyLog.track(.calendarViewOpened)
            }
        }
    }

    private var navigationTitle: String {
        switch viewMode {
        case .day:
            selectedDate.formatted(.dateTime.month(.wide).day().year())
        case .week:
            weekTitle
        case .month:
            selectedDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private var weekTitle: String {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate),
              let endDate = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) else {
            return selectedDate.formatted(.dateTime.month(.wide).day().year())
        }

        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// A month either side of what the user is looking at — enough that paging by a month lands
    /// on already-mirrored events rather than on a fetch.
    static func mirrorRange(around date: Date) -> DateInterval {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, end: date)
        return DateInterval(
            start: calendar.date(byAdding: .month, value: -1, to: month.start) ?? month.start,
            end: calendar.date(byAdding: .month, value: 1, to: month.end) ?? month.end
        )
    }

    private var selectedDateOccurrences: [CalendarOccurrence] {
        _ = store.environmentRevision
        return store.visibleOccurrences(on: selectedDate)
    }

    private var visibleWeekOccurrences: [CalendarOccurrence] {
        _ = store.environmentRevision
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return selectedDateOccurrences
        }
        return store.visibleOccurrences(in: interval)
    }

    private var visibleMonthOccurrences: [CalendarOccurrence] {
        _ = store.environmentRevision
        guard let interval = Calendar.current.dateInterval(of: .month, for: selectedDate) else {
            return selectedDateOccurrences
        }
        let paddedInterval = DateInterval(
            start: interval.start.addingTimeInterval(-7 * 24 * 60 * 60),
            end: interval.end.addingTimeInterval(7 * 24 * 60 * 60)
        )
        return store.visibleOccurrences(in: paddedInterval)
    }

    private var calendarPageDragGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontalDistance = value.translation.width
                let verticalDistance = value.translation.height
                guard abs(horizontalDistance) > 60,
                      abs(horizontalDistance) > abs(verticalDistance) else { return }

                moveSelection(by: horizontalDistance < 0 ? 1 : -1)
            }
    }

    private func moveSelection(by value: Int) {
        let component: Calendar.Component = switch viewMode {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }

        if let date = Calendar.current.date(byAdding: component, value: value, to: selectedDate) {
            selectedDate = date
        }
    }

    /// Returns the calendar to the current day. `alignWeekToToday` additionally asks the week
    /// view to scroll today into its leading column — the Today button does, a view-mode switch
    /// does not.
    private func goToToday(alignWeekToToday: Bool) {
        selectedDate = .now
        if alignWeekToToday {
            todayAlignmentToken += 1
        }
    }

    private func beginAddingEvent(at startDate: Date) {
        newEventStartDate = startDate
        isAddingEvent = true
    }

    private func moveOccurrence(_ event: CalendarEvent, to newStartDate: Date) {
        store.moveEvent(event, to: newStartDate)
    }

    private func resizeOccurrence(_ event: CalendarEvent, startDate: Date, endDate: Date) {
        store.resizeEvent(event, startDate: startDate, endDate: endDate)
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        store.calendars.first { $0.id == event.calendarID }
    }

    private func defaultEventStartDate(on date: Date) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }

    /// Spec 3D.5: carries the "This and Future" choice from the confirmation dialog into the
    /// draft, so the save applies a split at that occurrence rather than editing the master.
    private func draft(for event: CalendarEvent?, defaultCalendarID: UUID, startDate: Date) -> EventDraft {
        guard let event else { return EventDraft(calendarID: defaultCalendarID, startDate: startDate) }
        var draft = EventDraft(event: event)
        draft.scopedSplitOccurrenceStart = futureSplitOccurrenceStart
        return draft
    }

    @ViewBuilder
    private func editor(for event: CalendarEvent?, startDate: Date) -> some View {
        if let defaultCalendarID = store.defaultCalendarID {
            EventEditorView(
                calendars: store.calendars,
                draft: draft(for: event, defaultCalendarID: defaultCalendarID, startDate: startDate),
                event: event,
                onSave: store.saveEvent,
                onDelete: store.deleteEvent
            )
        } else {
            ContentUnavailableView("No calendar", systemImage: "calendar.badge.exclamationmark", description: Text("Create a local calendar before adding events."))
        }
    }
}

private struct DateNavigationStrip: View {
    let selectedDate: Date
    let viewMode: CalendarViewMode
    let title: String
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onChooseDate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Previous \(viewMode.title)", systemImage: "chevron.left", action: onPrevious)
                .labelStyle(.iconOnly)

            Button(action: onChooseDate) {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(selectedDate.formatted(.dateTime.weekday(.wide)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button("Next \(viewMode.title)", systemImage: "chevron.right", action: onNext)
                .labelStyle(.iconOnly)

            Button("Today", systemImage: "location", action: onToday)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

private struct DayCalendarView: View {
    let occurrences: [CalendarOccurrence]
    let calendars: [BetterCalendar]
    let selectedDate: Date
    let onSelect: (CalendarOccurrence) -> Void
    let onCreate: (Date) -> Void
    let onMove: (CalendarEvent, Date) -> Void
    let onResize: (CalendarEvent, Date, Date) -> Void

    private let hourHeight: CGFloat = 64
    private let labelWidth: CGFloat = 54

    // BC-VIEW-012 (spec 1.6 "auto-scroll while dragging near the top or bottom"): rather than
    // measuring pixel proximity to the viewport edge (which needs coordinate-space plumbing
    // through every nested card), this keeps the drag's *destination* hour scrolled into view
    // as it changes — a simpler, more robust way to reach the same "the content follows your
    // drag" outcome.
    @State private var lastAutoScrollHour: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    allDaySection
                        .padding(.horizontal)

                    timeline(scrollProxy: proxy)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .overlay {
                if occurrences.isEmpty {
                    ContentUnavailableView("No events", systemImage: "calendar.badge.plus", description: Text("Tap an hour or use Add Event to plan this day."))
                }
            }
        }
    }

    private func handleAutoScrollHint(_ estimatedDate: Date, proxy: ScrollViewProxy) {
        let hour = Calendar.current.component(.hour, from: estimatedDate)
        guard hour != lastAutoScrollHour else { return }
        lastAutoScrollHour = hour
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("hour-\(hour)", anchor: .center)
        }
    }

    private var allDayOccurrences: [CalendarOccurrence] {
        occurrences.filter(\.event.isAllDay)
    }

    private var timedOccurrences: [CalendarOccurrence] {
        occurrences.filter { !$0.event.isAllDay }
    }

    @ViewBuilder
    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All-day")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if allDayOccurrences.isEmpty {
                Text("No all-day events")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(allDayOccurrences) { occurrence in
                        Button {
                            onSelect(occurrence)
                        } label: {
                            Label(occurrence.event.title, systemImage: "calendar")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(calendar(for: occurrence.event)?.displayColor.opacity(0.18) ?? Color.accentColor.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func timeline(scrollProxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .topLeading) {
            timelineGrid
            ForEach(layouts) { layout in
                TimelineOccurrenceCard(
                    occurrence: layout.occurrence,
                    calendar: calendar(for: layout.occurrence.event),
                    hourHeight: hourHeight,
                    onSelect: onSelect,
                    onMove: onMove,
                    onResize: onResize,
                    onAutoScrollHint: { estimatedDate in handleAutoScrollHint(estimatedDate, proxy: scrollProxy) }
                )
                .frame(width: layout.width, height: layout.height)
                .offset(x: labelWidth + 8 + layout.xOffset, y: layout.yOffset)
            }

            if Calendar.current.isDateInToday(selectedDate) {
                currentTimeIndicator
            }
        }
        .frame(height: hourHeight * 24)
    }

    private var timelineGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .padding(.top, -6)

                    Button {
                        onCreate(dateForHour(hour))
                    } label: {
                        Rectangle()
                            .fill(.clear)
                            .overlay(alignment: .top) {
                                Divider()
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add event at \(hourLabel(hour))")
                }
                .frame(height: hourHeight)
                .id("hour-\(hour)")
            }
        }
    }

    private var currentTimeIndicator: some View {
        let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
        let yOffset = CGFloat(minutes) / 60 * hourHeight

        return HStack(spacing: 6) {
            Text("Now")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: labelWidth, alignment: .trailing)
            Rectangle()
                .fill(.red)
                .frame(height: 1)
        }
        .offset(y: yOffset)
        .accessibilityHidden(true)
    }

    private var layouts: [TimedOccurrenceLayout] {
        TimedOccurrenceLayout.makeLayouts(
            occurrences: timedOccurrences,
            day: selectedDate,
            hourHeight: hourHeight,
            availableWidth: 320
        )
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        calendars.first { $0.id == event.calendarID }
    }

    private func hourLabel(_ hour: Int) -> String {
        let components = DateComponents(hour: hour)
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }

    private func dateForHour(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDate) ?? selectedDate
    }
}

private struct WeekCalendarView: View {
    let occurrences: [CalendarOccurrence]
    let calendars: [BetterCalendar]
    @Binding var selectedDate: Date
    /// Changes whenever the Today button is tapped. Each change scrolls today's column to the
    /// leading edge of the week — a plain `selectedDate` observation would miss the case where
    /// Today is tapped while today is already the selected date.
    let todayAlignmentToken: Int
    let onSelect: (CalendarOccurrence) -> Void
    let onCreate: (Date) -> Void
    /// BC-VIEW-012 (spec 1.7 "drag events between days"): the store's `moveEvent`, called with
    /// the dragged event and its new start (same time-of-day, new date).
    let onMove: (CalendarEvent, Date) -> Void

    @State private var dropTargetDay: Date?

    var body: some View {
        ScrollViewReader { proxy in
            weekStrip
                .onChange(of: todayAlignmentToken) { _, _ in
                    alignTodayToLeadingEdge(using: proxy)
                }
        }
    }

    private var weekStrip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            selectedDate = day
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(day.formatted(.dateTime.month().day()))
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        let dayOccurrences = occurrencesForDay(day)
                        if dayOccurrences.isEmpty {
                            Button {
                                onCreate(defaultStartDate(on: day))
                            } label: {
                                Text("No events")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ForEach(dayOccurrences) { occurrence in
                                Button {
                                    onSelect(occurrence)
                                } label: {
                                    CompactOccurrenceCard(occurrence: occurrence, calendar: calendar(for: occurrence.event))
                                }
                                .buttonStyle(.plain)
                                .draggable(occurrence.id)
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 210, alignment: .top)
                    .background(backgroundColor(for: day), in: RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button("Add Event", systemImage: "plus") {
                            onCreate(defaultStartDate(on: day))
                        }
                    }
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        handleDrop(droppedIDs, onto: day)
                    } isTargeted: { isTargeted in
                        dropTargetDay = isTargeted ? day : (dropTargetDay == day ? nil : dropTargetDay)
                    }
                    .id(day)
                }
            }
            .padding()
        }
    }

    /// Scrolls the week so the current day sits in the leftmost visible column. If today falls
    /// late in the week the scroll view clamps at its end, which is as far left as today can go.
    private func alignTodayToLeadingEdge(using proxy: ScrollViewProxy) {
        guard let today = days.first(where: { Calendar.current.isDateInToday($0) }) else { return }
        // Tapping Today can switch the visible week and request this scroll in the same update,
        // so wait for the new columns to be laid out before reaching for one of them.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(today, anchor: .leading)
            }
        }
    }

    private func backgroundColor(for day: Date) -> Color {
        if dropTargetDay == day {
            return Color.accentColor.opacity(0.28)
        }
        if Calendar.current.isDate(day, inSameDayAs: selectedDate) {
            return Color.accentColor.opacity(0.12)
        }
        return Color.secondary.opacity(0.07)
    }

    private func handleDrop(_ droppedIDs: [String], onto day: Date) -> Bool {
        guard let occurrenceID = droppedIDs.first,
              let occurrence = occurrences.first(where: { $0.id == occurrenceID }) else {
            return false
        }
        let newStartDate = occurrence.event.movedPreservingTimeOfDay(to: day)
        onMove(occurrence.event, newStartDate)
        return true
    }

    private var days: [Date] {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate) else { return [selectedDate] }
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func occurrencesForDay(_ day: Date) -> [CalendarOccurrence] {
        occurrences.filter { $0.occurs(on: day) }
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        calendars.first { $0.id == event.calendarID }
    }

    private func defaultStartDate(on date: Date) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }
}

private struct MonthCalendarView: View {
    let occurrences: [CalendarOccurrence]
    let calendars: [BetterCalendar]
    @Binding var selectedDate: Date
    let onSelect: (CalendarOccurrence) -> Void
    let onCreate: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(daysInGrid, id: \.self) { day in
                    MonthDayCell(
                        day: day,
                        isInSelectedMonth: Calendar.current.isDate(day, equalTo: selectedDate, toGranularity: .month),
                        isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                        occurrences: occurrencesForDay(day),
                        calendarColor: { calendar(for: $0.event)?.displayColor ?? .blue },
                        onSelect: {
                            selectedDate = day
                        },
                        onCreate: {
                            onCreate(defaultStartDate(on: day))
                        }
                    )
                }
            }
            .padding()

            selectedDaySection
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var selectedDaySection: some View {
        let selectedOccurrences = occurrencesForDay(selectedDate)
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if selectedOccurrences.isEmpty {
                Button {
                    onCreate(defaultStartDate(on: selectedDate))
                } label: {
                    Label("Add event", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(selectedOccurrences) { occurrence in
                    Button {
                        onSelect(occurrence)
                    } label: {
                        CompactOccurrenceCard(occurrence: occurrence, calendar: calendar(for: occurrence.event))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var daysInGrid: [Date] {
        guard let monthInterval = Calendar.current.dateInterval(of: .month, for: selectedDate),
              let firstWeek = Calendar.current.dateInterval(of: .weekOfYear, for: monthInterval.start),
              let lastVisibleDay = Calendar.current.date(byAdding: .day, value: -1, to: monthInterval.end),
              let lastWeek = Calendar.current.dateInterval(of: .weekOfYear, for: lastVisibleDay) else {
            return []
        }

        var days: [Date] = []
        var current = firstWeek.start
        while current < lastWeek.end {
            days.append(current)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let firstIndex = Calendar.current.firstWeekday - 1
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private func occurrencesForDay(_ day: Date) -> [CalendarOccurrence] {
        occurrences
            .filter { $0.occurs(on: day) }
            .sorted { lhs, rhs in
                if lhs.event.isAllDay != rhs.event.isAllDay { return lhs.event.isAllDay }
                return lhs.occurrenceStartDate < rhs.occurrenceStartDate
            }
    }

    private func calendar(for event: CalendarEvent) -> BetterCalendar? {
        calendars.first { $0.id == event.calendarID }
    }

    private func defaultStartDate(on date: Date) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }
}

private struct MonthDayCell: View {
    let day: Date
    let isInSelectedMonth: Bool
    let isSelected: Bool
    let occurrences: [CalendarOccurrence]
    let calendarColor: (CalendarOccurrence) -> Color
    let onSelect: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.caption.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                    .foregroundStyle(isInSelectedMonth ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(occurrences.prefix(3))) { occurrence in
                    HStack(spacing: 3) {
                        if occurrence.event.isAllDay {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(calendarColor(occurrence))
                                .frame(width: 12, height: 4)
                        } else {
                            Circle()
                                .fill(calendarColor(occurrence))
                                .frame(width: 5, height: 5)
                        }
                        Text(occurrence.event.displayTitle)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if occurrences.count > 3 {
                    Text("+\(occurrences.count - 3) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(background)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Add Event", systemImage: "plus", action: onCreate)
        }
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(occurrences.count) events")
    }

    private var background: some ShapeStyle {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if Calendar.current.isDateInToday(day) {
            return Color.accentColor.opacity(0.08)
        }
        return Color.secondary.opacity(0.06)
    }
}

private struct CompactOccurrenceCard: View {
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendar?.displayColor ?? .blue)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.event.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(occurrence.displayEvent.timeRangeText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(occurrence.displayEvent.accessibilitySummary(calendarName: calendar?.name ?? "Local calendar"))
    }
}

private struct TimelineOccurrenceCard: View {
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?
    let hourHeight: CGFloat
    let onSelect: (CalendarOccurrence) -> Void
    let onMove: (CalendarEvent, Date) -> Void
    let onResize: (CalendarEvent, Date, Date) -> Void
    /// BC-VIEW-012 (spec 1.6): called with the drag's live estimated destination time so the
    /// containing scroll view can follow it. Fired from both the move gesture and either
    /// resize handle.
    let onAutoScrollHint: (Date) -> Void

    @State private var lastSnappedMinutes: Int?

    var body: some View {
        Button {
            onSelect(occurrence)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Capsule()
                    .fill(calendar?.displayColor ?? .blue)
                    .frame(height: 4)

                Text(occurrence.event.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)

                Text(occurrence.displayEvent.timeRangeText())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .top) {
                resizeHandle(edge: .top)
            }
            .overlay(alignment: .bottom) {
                resizeHandle(edge: .bottom)
            }
        }
        .buttonStyle(.plain)
        .gesture(moveGesture)
        .contextMenu {
            Button("Move 15 minutes later") {
                onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(15 * 60))
            }
            Button("Move 15 minutes earlier") {
                onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(-15 * 60))
            }
            Button("Extend 15 minutes") {
                onResize(occurrence.event, occurrence.occurrenceStartDate, occurrence.occurrenceEndDate.addingTimeInterval(15 * 60))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(occurrence.displayEvent.accessibilitySummary(calendarName: calendar?.name ?? "Local calendar"))
        .accessibilityAction(named: occurrence.isRecurringOccurrence ? "Move series later" : "Move later") {
            onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(15 * 60))
        }
        .accessibilityAction(named: occurrence.isRecurringOccurrence ? "Duplicate series occurrence in details" : "Resize longer") {
            onResize(occurrence.event, occurrence.occurrenceStartDate, occurrence.occurrenceEndDate.addingTimeInterval(15 * 60))
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let minutes = roundedMinutes(forVerticalOffset: value.translation.height)
                handleSnapFeedback(for: minutes)
                onAutoScrollHint(occurrence.occurrenceStartDate.addingTimeInterval(TimeInterval(minutes * 60)))
            }
            .onEnded { value in
                lastSnappedMinutes = nil
                let minutes = roundedMinutes(forVerticalOffset: value.translation.height)
                guard minutes != 0 else { return }
                onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(TimeInterval(minutes * 60)))
            }
    }

    private func resizeHandle(edge: VerticalEdge) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(height: 12)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 28, height: 3)
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let minutes = roundedMinutes(forVerticalOffset: value.translation.height)
                        handleSnapFeedback(for: minutes)
                        let referenceDate = edge == .top ? occurrence.occurrenceStartDate : occurrence.occurrenceEndDate
                        onAutoScrollHint(referenceDate.addingTimeInterval(TimeInterval(minutes * 60)))
                    }
                    .onEnded { value in
                        lastSnappedMinutes = nil
                        let minutes = roundedMinutes(forVerticalOffset: value.translation.height)
                        guard minutes != 0 else { return }
                        if edge == .top {
                            let newStart = occurrence.occurrenceStartDate.addingTimeInterval(TimeInterval(minutes * 60))
                            guard occurrence.occurrenceEndDate > newStart.addingTimeInterval(15 * 60) else { return }
                            onResize(occurrence.event, newStart, occurrence.occurrenceEndDate)
                        } else {
                            let newEnd = occurrence.occurrenceEndDate.addingTimeInterval(TimeInterval(minutes * 60))
                            guard newEnd > occurrence.occurrenceStartDate.addingTimeInterval(15 * 60) else { return }
                            onResize(occurrence.event, occurrence.occurrenceStartDate, newEnd)
                        }
                    }
            )
    }

    /// BC-VIEW-012 (spec 1.6 "haptic feedback at 15- or 30-minute boundaries"): fires once per
    /// newly-reached 15-minute snap increment, not on every pixel of drag movement.
    private func handleSnapFeedback(for minutes: Int) {
        guard minutes != lastSnappedMinutes else { return }
        lastSnappedMinutes = minutes
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func roundedMinutes(forVerticalOffset offset: CGFloat) -> Int {
        let rawMinutes = Double(offset / hourHeight) * 60
        return Int((rawMinutes / 15).rounded()) * 15
    }
}

private struct TimedOccurrenceLayout: Identifiable {
    let occurrence: CalendarOccurrence
    let column: Int
    let columnCount: Int
    let yOffset: CGFloat
    let height: CGFloat
    let availableWidth: CGFloat

    var id: String { occurrence.id }

    var width: CGFloat {
        max((availableWidth - CGFloat(columnCount - 1) * 6) / CGFloat(columnCount), 72)
    }

    var xOffset: CGFloat {
        CGFloat(column) * (width + 6)
    }

    static func makeLayouts(occurrences: [CalendarOccurrence], day: Date, hourHeight: CGFloat, availableWidth: CGFloat) -> [TimedOccurrenceLayout] {
        guard let dayInterval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        let sortedOccurrences = occurrences.sorted { $0.occurrenceStartDate < $1.occurrenceStartDate }
        let clusters = overlapClusters(for: sortedOccurrences)

        return clusters.flatMap { cluster -> [TimedOccurrenceLayout] in
            let columns = assignedColumns(for: cluster)
            let columnCount = max((columns.values.max() ?? 0) + 1, 1)

            return cluster.compactMap { occurrence in
                let start = max(occurrence.occurrenceStartDate, dayInterval.start)
                let end = min(occurrence.occurrenceEndDate, dayInterval.end)
                guard end > start else { return nil }

                let startMinutes = start.timeIntervalSince(dayInterval.start) / 60
                let durationMinutes = end.timeIntervalSince(start) / 60

                return TimedOccurrenceLayout(
                    occurrence: occurrence,
                    column: columns[occurrence.id] ?? 0,
                    columnCount: columnCount,
                    yOffset: CGFloat(startMinutes / 60) * hourHeight,
                    height: max(CGFloat(durationMinutes / 60) * hourHeight, 34),
                    availableWidth: availableWidth
                )
            }
        }
    }

    private static func overlapClusters(for occurrences: [CalendarOccurrence]) -> [[CalendarOccurrence]] {
        var clusters: [[CalendarOccurrence]] = []
        var currentCluster: [CalendarOccurrence] = []
        var clusterEnd: Date?

        for occurrence in occurrences {
            if let end = clusterEnd, occurrence.occurrenceStartDate >= end {
                clusters.append(currentCluster)
                currentCluster = [occurrence]
                clusterEnd = occurrence.occurrenceEndDate
            } else {
                currentCluster.append(occurrence)
                clusterEnd = max(clusterEnd ?? occurrence.occurrenceEndDate, occurrence.occurrenceEndDate)
            }
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters
    }

    private static func assignedColumns(for occurrences: [CalendarOccurrence]) -> [String: Int] {
        var activeColumns: [(end: Date, column: Int)] = []
        var assignments: [String: Int] = [:]

        for occurrence in occurrences.sorted(by: { $0.occurrenceStartDate < $1.occurrenceStartDate }) {
            activeColumns.removeAll { $0.end <= occurrence.occurrenceStartDate }
            let usedColumns = Set(activeColumns.map(\.column))
            let column = sequence(first: 0, next: { $0 + 1 }).first { !usedColumns.contains($0) } ?? 0
            assignments[occurrence.id] = column
            activeColumns.append((end: occurrence.occurrenceEndDate, column: column))
        }

        return assignments
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = rows(in: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [(width: CGFloat, height: CGFloat)] {
        var rows: [(width: CGFloat, height: CGFloat)] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > width, currentWidth > 0 {
                rows.append((currentWidth, currentHeight))
                currentWidth = 0
                currentHeight = 0
            }

            currentWidth += size.width + (currentWidth > 0 ? spacing : 0)
            currentHeight = max(currentHeight, size.height)
        }

        if currentWidth > 0 {
            rows.append((currentWidth, currentHeight))
        }

        return rows
    }
}

private struct DatePickerNavigationSheet: View {
    @Binding var selectedDate: Date
    let viewMode: CalendarViewMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $selectedDate, displayedComponents: [.date])
                    .datePickerStyle(.graphical)

                Section {
                    Text("Choosing a date updates the current \(viewMode.title.lowercased()) view.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Go to Date")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
