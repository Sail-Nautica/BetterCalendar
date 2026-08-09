import Foundation
import UserNotifications

protocol LocalNotificationScheduling {
    func reconcile(events: [CalendarEvent], calendars: [BetterCalendar], now: Date, authorizationRequestPolicy: NotificationAuthorizationRequestPolicy, allDayAlertHour: Int)
    func cancelNotifications(for eventIDs: Set<UUID>)
    func pendingRequestCount() async -> Int
}

extension LocalNotificationScheduling {
    func reconcile(events: [CalendarEvent], calendars: [BetterCalendar], now: Date) {
        reconcile(events: events, calendars: calendars, now: now, authorizationRequestPolicy: .never, allDayAlertHour: 9)
    }

    func reconcile(events: [CalendarEvent], calendars: [BetterCalendar], now: Date, authorizationRequestPolicy: NotificationAuthorizationRequestPolicy) {
        reconcile(events: events, calendars: calendars, now: now, authorizationRequestPolicy: authorizationRequestPolicy, allDayAlertHour: 9)
    }
}

enum NotificationAuthorizationRequestPolicy {
    case never
    case ifNeeded
}

struct LocalNotificationRequest: Hashable {
    var identifier: String
    var eventID: UUID
    var title: String
    var body: String
    var fireDate: Date
}

struct LocalNotificationReconciliationPlan: Equatable {
    var requestsToSchedule: [LocalNotificationRequest]
    var identifiersToCancel: [String]
}

struct LocalNotificationPlanner {
    static let identifierPrefix = "better-calendar"
    static let defaultSchedulingWindow: TimeInterval = 60 * 24 * 60 * 60

    var expander = RecurrenceExpander(maximumGeneratedOccurrences: 1_000)
    var allDayAlertHour = 9

    func plan(
        events: [CalendarEvent],
        calendars: [BetterCalendar],
        pendingIdentifiers: Set<String>,
        now: Date,
        horizonEnd: Date = Date().addingTimeInterval(defaultSchedulingWindow)
    ) -> LocalNotificationReconciliationPlan {
        let visibleCalendarIDs = Set(calendars.filter(\.isVisible).map(\.id))
        let range = DateInterval(start: now, end: horizonEnd)
        var requests: [LocalNotificationRequest] = []

        for event in events where visibleCalendarIDs.contains(event.calendarID) && !event.reminders.isEmpty {
            let occurrences = expander.occurrences(of: event, in: range)

            for occurrence in occurrences {
                for reminder in event.reminders {
                    guard let offset = reminder.offset.notificationOffsetSeconds,
                          let fireDate = triggerDate(for: occurrence, offset: offset),
                          fireDate > now,
                          fireDate <= horizonEnd else {
                        continue
                    }

                    requests.append(
                        LocalNotificationRequest(
                            identifier: notificationIdentifier(event: event, reminder: reminder, occurrence: occurrence),
                            eventID: event.id,
                            title: event.title,
                            body: notificationBody(for: occurrence),
                            fireDate: fireDate
                        )
                    )
                }
            }
        }

        let desiredIdentifiers = Set(requests.map(\.identifier))
        let identifiersToCancel = pendingIdentifiers
            .filter { $0.hasPrefix(Self.identifierPrefix) && !desiredIdentifiers.contains($0) }
            .sorted()

        return LocalNotificationReconciliationPlan(
            requestsToSchedule: requests.sorted { $0.fireDate < $1.fireDate },
            identifiersToCancel: identifiersToCancel
        )
    }

    func notificationIdentifier(event: CalendarEvent, reminder: EventReminder, occurrence: CalendarOccurrence) -> String {
        "\(Self.identifierPrefix).event.\(event.id.uuidString).reminder.\(reminder.id.uuidString).occurrence.\(occurrence.occurrenceKey)"
    }

    private func triggerDate(for occurrence: CalendarOccurrence, offset: TimeInterval) -> Date? {
        if occurrence.event.isAllDay {
            var calendar = occurrence.event.calendarInOriginalTimeZone
            var components = calendar.dateComponents([.year, .month, .day], from: occurrence.occurrenceStartDate)
            components.hour = allDayAlertHour
            components.minute = 0
            components.second = 0
            guard let baseDate = calendar.date(from: components) else { return nil }
            return baseDate.addingTimeInterval(offset)
        }

        return occurrence.occurrenceStartDate.addingTimeInterval(offset)
    }

    private func notificationBody(for occurrence: CalendarOccurrence) -> String {
        if occurrence.event.isAllDay {
            return occurrence.event.allDayLocalDateRangeText
        }

        return occurrence.event.timeRangeText()
    }
}

struct UserNotificationScheduler: LocalNotificationScheduling {
    func reconcile(events: [CalendarEvent], calendars: [BetterCalendar], now: Date = .now, authorizationRequestPolicy: NotificationAuthorizationRequestPolicy = .never, allDayAlertHour: Int = 9) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            if settings.authorizationStatus == .notDetermined {
                guard authorizationRequestPolicy == .ifNeeded else {
                    return
                }
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }

            let updatedSettings = await center.notificationSettings()
#if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
            let isAuthorized = updatedSettings.authorizationStatus == .authorized || updatedSettings.authorizationStatus == .provisional || updatedSettings.authorizationStatus == .ephemeral
#else
            let isAuthorized = updatedSettings.authorizationStatus == .authorized || updatedSettings.authorizationStatus == .provisional
#endif
            guard isAuthorized else {
                return
            }

            let pendingRequests = await center.pendingNotificationRequests()
            let pendingIdentifiers = Set(pendingRequests.map(\.identifier))
            var planner = LocalNotificationPlanner()
            planner.allDayAlertHour = allDayAlertHour
            let plan = planner.plan(
                events: events,
                calendars: calendars,
                pendingIdentifiers: pendingIdentifiers,
                now: now,
                horizonEnd: now.addingTimeInterval(LocalNotificationPlanner.defaultSchedulingWindow)
            )

            if !plan.identifiersToCancel.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: plan.identifiersToCancel)
            }

            let existingIdentifiers = pendingIdentifiers.subtracting(plan.identifiersToCancel)
            for request in plan.requestsToSchedule where !existingIdentifiers.contains(request.identifier) {
                let content = UNMutableNotificationContent()
                content.title = request.title
                content.body = request.body
                content.sound = .default

                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let notificationRequest = UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
                try? await center.add(notificationRequest)
            }
        }
    }

    func cancelNotifications(for eventIDs: Set<UUID>) {
        guard !eventIDs.isEmpty else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let pendingRequests = await center.pendingNotificationRequests()
            let identifiers = pendingRequests
                .map(\.identifier)
                .filter { identifier in
                    eventIDs.contains { eventID in
                        identifier.contains(".event.\(eventID.uuidString).")
                    }
                }

            if !identifiers.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

    func pendingRequestCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }
}

struct NoopNotificationScheduler: LocalNotificationScheduling {
    func reconcile(events: [CalendarEvent], calendars: [BetterCalendar], now: Date, authorizationRequestPolicy: NotificationAuthorizationRequestPolicy, allDayAlertHour: Int) { }
    func cancelNotifications(for eventIDs: Set<UUID>) { }
    func pendingRequestCount() async -> Int { 0 }
}
