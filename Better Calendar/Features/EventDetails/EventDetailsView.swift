import SwiftUI
import UniformTypeIdentifiers

struct EventDetailsView: View {
    /// Used directly (not via a closure) for BC-EVT-020 actions that don't need to coordinate
    /// with the presenting screen's own navigation state: move-to-calendar, ICS export, and
    /// reading `store.calendars` for the move menu.
    let store: BetterCalendarStore
    let occurrence: CalendarOccurrence
    let calendar: BetterCalendar?
    let onEdit: (CalendarEvent) -> Void
    /// "This Event" edit scope (BC-REC-010, spec 1.11) — the caller resolves which event to
    /// open via `store.eventForEditingOccurrence(_:)`.
    let onEditOccurrence: (CalendarOccurrence) -> Void
    /// Spec 3D.5's "This and Future" scope. Separate from `onEditOccurrence` because the editor
    /// opens on the *master* and the split is applied on save, rather than on a per-occurrence
    /// seed.
    var onEditFuture: (CalendarOccurrence) -> Void = { _ in }
    let onDelete: (CalendarEvent) -> Void
    /// "This Event" delete scope (BC-REC-010, spec 1.11) — the caller calls
    /// `store.deleteOccurrence(_:)`.
    let onDeleteOccurrence: (CalendarOccurrence) -> Void
    let onDuplicate: (CalendarEvent) -> Void
    let onMove: (CalendarEvent, Date) -> Void
    let onResize: (CalendarEvent, Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingScopeAction: ScopeAction?

    private enum ScopeAction: Equatable {
        case edit
        case delete
    }

    private var event: CalendarEvent {
        occurrence.displayEvent
    }

    /// Asked of the store rather than derived here, so what this screen says and what the save
    /// path would do cannot drift apart. See `BetterCalendarStore.editRefusal(for:)`.
    private var editRefusal: CapabilityViolation? {
        store.editRefusal(for: occurrence.event)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(calendar?.displayColor ?? .blue)
                            .frame(width: 14, height: 14)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.displayTitle)
                                .font(.title2.weight(.semibold))
                            Text(event.timeRangeText())
                                .foregroundStyle(.secondary)

                            if occurrence.isRecurringOccurrence {
                                Label("Repeats: \(event.recurrence?.summary ?? "Recurring event")", systemImage: "repeat")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Spec 3.34/3C.9: everything that changes what the user may do goes *above*
                // the actions, so a read-only event says so before the attempt rather than
                // after. Nothing here renders for a Better Calendar-owned event: no local
                // calendar is read-only, nothing local carries a status other than confirmed,
                // and nothing local can have a repeat pattern the engine cannot express.
                if event.isCancelled || event.hasUnrepresentableRecurrence || editRefusal != nil {
                    Section {
                        if event.isCancelled {
                            Label {
                                Text("This event has been cancelled by its organizer. It's still shown here, and it no longer counts as busy time.")
                            } icon: {
                                Image(systemName: "xmark.circle")
                            }
                            .foregroundStyle(.secondary)
                        }

                        if event.hasUnrepresentableRecurrence {
                            Label {
                                Text("This event repeats in a way Better Calendar can't show yet, so only this date appears. Open it in the app that owns \(calendar?.accountName ?? "this calendar") to see the full series.")
                            } icon: {
                                Image(systemName: "repeat.circle")
                            }
                            .foregroundStyle(.secondary)
                        }

                        // The recurrence banner above already explains that case in its own
                        // words, so only a *different* refusal reason adds anything — but a
                        // read-only calendar and an unexpressible repeat pattern are two
                        // separate true facts, and an event with both says both.
                        if let editRefusal, editRefusal.reason != .unrepresentableRecurrence {
                            Label {
                                Text(editRefusal.message)
                            } icon: {
                                Image(systemName: "lock")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Actions") {
                    // Spec 3C.9: an event that cannot be edited does not open the editor at all,
                    // rather than opening it and refusing to save. The same gate hides every
                    // other action that would produce a rejected mutation — move, resize,
                    // reassignment and delete all route through `updateEvent`/`deleteEvent`.
                    if editRefusal == nil {
                        Button("Edit", systemImage: "pencil") {
                            if occurrence.isRecurringOccurrence {
                                pendingScopeAction = .edit
                            } else {
                                dismiss()
                                onEdit(occurrence.event)
                            }
                        }
                    }

                    Button("Duplicate this occurrence", systemImage: "plus.square.on.square") {
                        dismiss()
                        onDuplicate(event)
                    }

                    if editRefusal == nil {
                        Menu(occurrence.isRecurringOccurrence ? "Move series" : "Move") {
                            Button("15 minutes earlier") {
                                move(by: -15 * 60)
                            }
                            Button("15 minutes later") {
                                move(by: 15 * 60)
                            }
                            Button("1 day earlier") {
                                move(by: -24 * 60 * 60)
                            }
                            Button("1 day later") {
                                move(by: 24 * 60 * 60)
                            }
                        }
                    }

                    if editRefusal == nil, !event.isAllDay {
                        Menu(occurrence.isRecurringOccurrence ? "Resize series" : "Resize") {
                            Button("Shorten by 15 minutes") {
                                resizeEnd(by: -15 * 60)
                            }
                            Button("Extend by 15 minutes") {
                                resizeEnd(by: 15 * 60)
                            }
                            Button("Start 15 minutes earlier") {
                                resizeStart(by: -15 * 60)
                            }
                            Button("Start 15 minutes later") {
                                resizeStart(by: 15 * 60)
                            }
                        }
                    }

                    // Spec 3B.5/3B.8: only calendars that would actually accept the event are
                    // offered. A read-only or unavailable destination shown and then refused is
                    // exactly the pattern spec 3.34 exists to prevent.
                    if editRefusal == nil, store.writableDestinationCalendars.contains(where: { $0.id != event.calendarID }) {
                        Menu("Move to Calendar") {
                            ForEach(store.writableDestinationCalendars.filter { $0.id != event.calendarID }) { destination in
                                Button(destination.destinationLabel) {
                                    store.moveEventToCalendar(occurrence.event, calendarID: destination.id)
                                }
                            }
                        }
                    }

                    ShareLink(item: event.shareSummaryText(calendarName: calendar?.name ?? "Local calendar")) {
                        Label("Share as Text", systemImage: "square.and.arrow.up")
                    }

                    ShareLink(item: ICSShareDocument(text: exportICSText), preview: SharePreview("\(event.title).ics")) {
                        Label("Export as ICS", systemImage: "doc.badge.arrow.up")
                    }

                    if let location = event.location, let mapsURL = mapsURL(for: location) {
                        Link(destination: mapsURL) {
                            Label("Open in Maps", systemImage: "map")
                        }
                    }

                    if editRefusal == nil {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if occurrence.isRecurringOccurrence {
                                pendingScopeAction = .delete
                            } else {
                                dismiss()
                                onDelete(occurrence.event)
                            }
                        }
                    }
                }

                if occurrence.isRecurringOccurrence {
                    Section {
                        Text("Move and resize apply to the whole recurring series. Duplicate creates a standalone copy of only this occurrence.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    DetailRow(title: "Calendar", value: calendar?.name ?? "Local calendar", systemImage: "calendar")

                    // BC-EK-018 / spec 3.34: a user with a work Exchange calendar and a personal
                    // iCloud calendar must never have to guess which one an event is on before
                    // editing it. Shown only for a calendar that has an owning account — a local
                    // calendar has none, and "Account: Better Calendar" would be noise.
                    if let accountName = calendar?.accountName {
                        DetailRow(title: "Account", value: accountName, systemImage: "person.crop.circle")
                    }

                    // Spec 3C.9: status is shown when it is not plain confirmed. A confirmed
                    // event saying "Confirmed" tells the user nothing they did not assume.
                    if event.status != .confirmed && event.status != .none {
                        DetailRow(title: "Status", value: event.status.label, systemImage: "questionmark.circle")
                    }

                    // Spec 1.10 "time zone when relevant": an all-day event has no meaningful
                    // zone, and a timed event already in the device's current zone doesn't
                    // need to say so.
                    if !event.isAllDay && event.timeZoneIdentifier != TimeZone.current.identifier {
                        DetailRow(title: "Time Zone", value: event.timeZoneIdentifier, systemImage: "globe")
                    }

                    // BC-TZ-001, spec 1.17 "dual-time display": off by default (per spec) —
                    // shown only when the user has configured a secondary zone in Settings.
                    if let secondaryZoneID = store.settings.secondaryTimeZoneIdentifier,
                       secondaryZoneID != event.timeZoneIdentifier,
                       let secondaryTime = event.startTime(displayedIn: secondaryZoneID) {
                        DetailRow(title: "Also in \(secondaryZoneID)", value: secondaryTime, systemImage: "clock.badge")
                    }

                    DetailRow(title: "Availability", value: event.availability.label, systemImage: event.availability == .busy ? "circle.fill" : "circle")

                    if let location = event.location {
                        DetailRow(title: "Location", value: location, systemImage: "location")
                    }

                    if let urlString = event.urlString, let url = URL(string: urlString) {
                        Link(destination: url) {
                            Label(urlString, systemImage: "link")
                                .lineLimit(2)
                        }
                    } else if let urlString = event.urlString {
                        DetailRow(title: "URL", value: urlString, systemImage: "link")
                    }

                    if !event.reminders.isEmpty {
                        DetailRow(
                            title: "Reminder",
                            value: event.reminders.map(\.offset.label).joined(separator: ", "),
                            systemImage: "bell"
                        )
                    }

                    DetailRow(title: "Created", value: event.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    if event.updatedAt != event.createdAt {
                        DetailRow(title: "Last Edited", value: event.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.arrow.circlepath")
                    }
                }

                // Spec 3C.5 (BC-EK-018): read-only attribution. There is deliberately no "add
                // guest" affordance anywhere in this phase — EventKit offers no API to add an
                // attendee, and an affordance that silently does nothing is worse than none.
                if !event.attendees.isEmpty {
                    Section("Guests") {
                        ForEach(event.attendees.sorted { $0.sortOrder < $1.sortOrder }) { attendee in
                            AttendeeRow(attendee: attendee)
                        }
                    }
                }

                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes)
                    }
                }
            }
            .navigationTitle("Event Details")
#if os(iOS) || os(tvOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                pendingScopeAction == .delete ? "Delete recurring event" : "Edit recurring event",
                isPresented: Binding(get: { pendingScopeAction != nil }, set: { if !$0 { pendingScopeAction = nil } }),
                titleVisibility: .visible
            ) {
                Button("This Event") {
                    performScopedAction(scope: .thisEventOnly)
                }
                // Spec 3D.5: Phase 2 built `.thisAndFuture` in the engine and deliberately
                // withheld the button "until Phase 3 has a provider to justify the added
                // complexity". It does now.
                Button("This and Future Events") {
                    performScopedAction(scope: .thisAndFuture)
                }
                Button("All Events") {
                    performScopedAction(scope: .allEvents)
                }
                Button("Cancel", role: .cancel) {
                    pendingScopeAction = nil
                }
            }
        }
        .macSheetFrame()
    }

    private func performScopedAction(scope: EditScope) {
        defer { pendingScopeAction = nil }
        dismiss()

        switch (pendingScopeAction, scope) {
        case (.edit, .thisEventOnly):
            onEditOccurrence(occurrence)
        case (.edit, .allEvents):
            onEdit(occurrence.event)
        case (.edit, .thisAndFuture):
            // Unlike the other two, this one has no seed to hand the editor: the split happens on
            // save, from the selected occurrence forward. So the master opens for editing and the
            // store applies the result at this occurrence — see `editSeriesFromOccurrence`.
            onEditFuture(occurrence)
        case (.delete, .thisEventOnly):
            onDeleteOccurrence(occurrence)
        case (.delete, .allEvents):
            onDelete(occurrence.event)
        case (.delete, .thisAndFuture):
            // The engine has handled this since Phase 2 M4; only the button was withheld.
            store.deleteSeries(occurrence, scope: .thisAndFuture)
        case (nil, _):
            break
        }
    }

    private var exportICSText: String {
        let scope: BetterCalendarStore.ICSExportScope = occurrence.isRecurringOccurrence
            ? .series(masterEventID: occurrence.event.id)
            : .singleEvent(occurrence.event.id)
        return store.exportICS(scope: scope)
    }

    private func mapsURL(for location: String) -> URL? {
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "http://maps.apple.com/?q=\(encoded)")
    }

    private func move(by seconds: TimeInterval) {
        dismiss()
        onMove(occurrence.event, occurrence.occurrenceStartDate.addingTimeInterval(seconds))
    }

    private func resizeEnd(by seconds: TimeInterval) {
        let newEndDate = occurrence.occurrenceEndDate.addingTimeInterval(seconds)
        guard newEndDate > occurrence.occurrenceStartDate.addingTimeInterval(15 * 60) else { return }
        dismiss()
        onResize(occurrence.event, occurrence.occurrenceStartDate, newEndDate)
    }

    private func resizeStart(by seconds: TimeInterval) {
        let newStartDate = occurrence.occurrenceStartDate.addingTimeInterval(seconds)
        guard occurrence.occurrenceEndDate > newStartDate.addingTimeInterval(15 * 60) else { return }
        dismiss()
        onResize(occurrence.event, newStartDate, occurrence.occurrenceEndDate)
    }
}

private struct ICSShareDocument: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .icsCalendar) { document in
            Data(document.text.utf8)
        }
    }
}

/// Spec 3C.5: one guest, with their answer and — where they are the organizer — the fact that
/// they called the meeting. Read-only by construction; there is nothing to tap.
private struct AttendeeRow: View {
    let attendee: EventAttendee

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(attendee.displayName)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(attendee.participationStatus == .declined ? Color.secondary : Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [attendee.participationStatus.label]
        if attendee.isOrganizer {
            parts.append("Organizer")
        }
        // The role is only worth saying when it is not the unremarkable default.
        if attendee.role != .unknown && attendee.role != .required {
            parts.append(attendee.role.label)
        }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch attendee.participationStatus {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle"
        case .tentative: "questionmark.circle"
        case .delegated: "arrowshape.turn.up.right.circle"
        case .pending, .unknown: "person.crop.circle"
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .foregroundStyle(.primary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
