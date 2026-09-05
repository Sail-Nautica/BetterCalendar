import Foundation

/// Spec 3.2/3A.5: the authorization surface of the `EventKitStore` protocol, split out so
/// Phase 3A can ship the permission model without the enumeration, fetch and save members that
/// need `DeviceCalendar`/`DeviceEvent` value types to exist first.
///
/// Phase 3B's `EventKitStore` refines this protocol rather than restating it, so the seam widens
/// without any Phase 3A call site changing.
///
/// Defined against a protocol rather than `EKEventStore` for the reason spec 3.36 gives: no iOS
/// runtime is installed on the primary development machine and the whole suite runs on the macOS
/// destination, so every state of this flow has to be reachable without a device, an account, or
/// a system prompt.
protocol CalendarAccessAuthorizing {
    /// Read live on every call. Spec 3.4 forbids caching this for the process lifetime — a user
    /// can revoke access in Settings while the app is backgrounded, and a stale copy is how an
    /// app ends up confidently showing a calendar it can no longer read.
    var authorizationStatus: CalendarAccessStatus { get }

    /// Presents the system alert, which can only ever happen once for the lifetime of the
    /// install. Callers are responsible for not burning it — see
    /// `BetterCalendarStore.requestDeviceCalendarAccess()`, which is the only caller and refuses
    /// unless `DeviceCalendarAccessState.canRequestAccess` is true.
    ///
    /// Returns the resulting status rather than a `Bool`: "not granted" has three distinct
    /// meanings (`denied`, `restricted`, `writeOnly`) and they lead to three different screens.
    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus
}

/// Spec 3.36's authorization surface: scriptable status, scriptable answer to the system alert,
/// and a record of what was asked, so "granted → revoked → re-granted" is a deterministic test
/// step and "we asked the system exactly once" is assertable.
///
/// Ships in the app target beside the real implementation, following the
/// `NoopNotificationScheduler` precedent, so previews and tests share one double. Phase 3B's
/// `FakeEventKitStore` extends it rather than restating it.
class FakeCalendarAuthorization: CalendarAccessAuthorizing {
    var authorizationStatus: CalendarAccessStatus
    /// What the system alert "answers" when `requestAccess` is called.
    var grantResult: CalendarAccessStatus
    private(set) var requestedLevels: [CalendarAccessLevel] = []

    var requestCount: Int { requestedLevels.count }

    init(status: CalendarAccessStatus = .notDetermined, grantResult: CalendarAccessStatus = .fullAccess) {
        self.authorizationStatus = status
        self.grantResult = grantResult
    }

    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus {
        requestedLevels.append(level)
        authorizationStatus = grantResult
        return grantResult
    }

    /// The user changing the setting outside the app — the BC-EK-022 scenario. Deliberately not
    /// spelled `authorizationStatus = ...` at the call site, so a test that means "someone
    /// revoked this in Settings" reads that way.
    func simulateExternalChange(to status: CalendarAccessStatus) {
        authorizationStatus = status
    }
}

// MARK: - Phase 3B: calendar enumeration

/// Spec 3.2's `EventKitStore`, as far as Phase 3B needs it. Refines 3A's authorization seam
/// rather than restating it, so a caller that only asks about permission keeps the narrower
/// type and the 3A call sites did not change when this arrived.
///
/// Spec 3.2 also sketches `sources()`, `events(in:calendarIDs:)`, `save`, `remove` and
/// `changeObservations()`. The event members are Phase 3C/3D. `sources()` is Phase 3F: every
/// consumer in 3B wants the source *of a calendar*, which `DeviceCalendar` carries, and an
/// account with no calendars has nothing to list or toggle — it is the duplicate-connection rule
/// that eventually needs to compare accounts rather than calendars.
protocol EventKitStore: CalendarAccessAuthorizing {
    /// Everything one discovery pass needs, in one call.
    ///
    /// One call rather than two properties because the real implementation needs a live
    /// `EKEventStore` for both answers and creating one is the expensive part — the shape of the
    /// protocol should not force the adapter to make two.
    func discoverCalendars() throws -> DeviceCalendarSnapshot

    /// Spec 3C.8 step 2: the device events intersecting `range`, on the given provider calendar
    /// identifiers.
    ///
    /// **Bounded by construction.** There is no "everything" call, because spec 3.24's most
    /// dangerous failure is a mirror inferring a deletion from an absence it never actually
    /// queried for. A caller that cannot name a range and a calendar set cannot ask.
    ///
    /// A series is returned as its **master plus its detachments**, not as expanded occurrences
    /// — see `DeviceEvent`'s doc comment for why that collapsing belongs on this side of the
    /// seam.
    ///
    /// `async` because this is the expensive member: it is bounded by the size of the user's
    /// calendar rather than by a handful of calendars, and spec 3.27 requires that rendering
    /// never block on it. `discoverCalendars` stays synchronous for exactly the opposite reason.
    func events(in range: DateInterval, calendarIdentifiers: Set<String>) async throws -> [DeviceEvent]

    /// One device event by identifier, or `nil` if it is no longer there.
    ///
    /// Phase 3D's update path fetches through this immediately before writing, for two reasons
    /// that are really one: spec 3.17 requires the patch be applied to a *fresh* event so the
    /// fields we do not model survive, and spec 3.22 requires the concurrency check compare
    /// against what the device holds *now*.
    ///
    /// For a recurring event this returns the series master, matching `events(in:)`.
    func event(withIdentifier identifier: String) async throws -> DeviceEvent?

    /// Spec 3.19: create or update, returning the receipt that names the event on the device.
    ///
    /// The adapter applies exactly `write.fields` onto a freshly fetched event and leaves
    /// everything else alone. That is not a convention this protocol hopes callers follow — it
    /// is the only shape this call has, which is what makes "a title-only edit must not strip a
    /// video-call link" structurally true.
    func save(_ write: DeviceEventWrite) async throws -> DeviceWriteReceipt

    /// Spec 3.19: remove an event, with the span that says how much of a series goes with it.
    func remove(identifier: String, span: DeviceEventSpan) async throws

    /// Spec 3.2/3F.2: the device's accounts, independent of the calendars on them.
    ///
    /// Reserved for this phase from the start, and Phase 3B was right to defer it: every consumer
    /// there wanted the source *of a calendar*, which `DeviceCalendar` carries, and a source with
    /// no calendars has nothing to list or toggle. It does have something to *compare* — the
    /// duplicate-connection rule matches accounts, not calendars.
    func sources() throws -> [DeviceCalendarSource]

    /// Spec 3.23: `EKEventStoreChanged`, as a stream.
    ///
    /// The notification carries no payload — it means "something changed, re-query", never "this
    /// event changed" — so an element of this stream is a signal to run a pass, not a description
    /// of what to do. Exposed through the seam rather than read from `NotificationCenter` at the
    /// call site so a test can post one and prove the wiring with no device (BC-EK-024).
    func changeObservations() -> AsyncStream<Void>

    /// Spec 3.23: ask the device to pull from its servers rather than only reporting what it
    /// already holds.
    ///
    /// Triggers network activity, so it is **not** run on every pass — only on a foreground and
    /// on an explicit user refresh. A pass reacting to `EKEventStoreChanged` never calls it: that
    /// notification is by definition the device telling us about something it already knows.
    func refreshSources() async
}

/// What the device reports about its calendars at one moment.
struct DeviceCalendarSnapshot: Equatable {
    var calendars: [DeviceCalendar]
    /// `EKEventStore.defaultCalendarForNewEvents`, as an identifier. Spec 3B.5's second fallback
    /// step. Read live and held in memory only — never persisted, because it is the device's
    /// state and a stored copy disagrees with it the moment the user changes it in Settings.
    var defaultCalendarIdentifierForNewEvents: String?

    static let empty = DeviceCalendarSnapshot(calendars: [], defaultCalendarIdentifierForNewEvents: nil)

    init(calendars: [DeviceCalendar], defaultCalendarIdentifierForNewEvents: String? = nil) {
        self.calendars = calendars
        self.defaultCalendarIdentifierForNewEvents = defaultCalendarIdentifierForNewEvents
    }
}

/// Spec 3.36's fake, extended to calendars: scriptable calendars, a scriptable device default,
/// injectable failure, and a count of how many times discovery actually reached the device.
final class FakeEventKitStore: FakeCalendarAuthorization, EventKitStore {
    var snapshot: DeviceCalendarSnapshot
    /// Spec 3.36: the device's events, scriptable between passes so "someone edited this in
    /// Apple Calendar" is a deterministic test step rather than a manual one.
    var deviceEvents: [DeviceEvent]
    /// Set to make the next discovery throw, for the failure paths spec 3.21 will classify.
    var discoveryError: Error?
    /// The same, for the event fetch.
    var eventFetchError: Error?
    private(set) var discoveryCount = 0
    private(set) var eventFetchCount = 0
    /// What the last fetch actually asked for, so a test can assert the *window* a caller used
    /// rather than only the rows it got back — the bounded-window rule is about the question,
    /// not the answer.
    private(set) var lastRequestedRange: DateInterval?
    private(set) var lastRequestedCalendarIdentifiers: Set<String> = []
    private var concurrentEventFetches = 0
    /// The most passes that were ever inside `events(in:)` at once. Must never exceed 1.
    private(set) var peakConcurrentEventFetches = 0

    init(
        status: CalendarAccessStatus = .fullAccess,
        grantResult: CalendarAccessStatus = .fullAccess,
        snapshot: DeviceCalendarSnapshot = .empty,
        deviceEvents: [DeviceEvent] = []
    ) {
        self.snapshot = snapshot
        self.deviceEvents = deviceEvents
        super.init(status: status, grantResult: grantResult)
    }

    func discoverCalendars() throws -> DeviceCalendarSnapshot {
        discoveryCount += 1
        if let discoveryError {
            throw discoveryError
        }
        return snapshot
    }

    /// Scriptable independently of `snapshot`, so a test can model an account that exists on the
    /// device with no calendars on it — which is exactly the shape the duplicate-connection rule
    /// has to compare and the calendar list cannot see.
    var extraSources: [DeviceCalendarSource] = []

    func sources() throws -> [DeviceCalendarSource] {
        if let discoveryError {
            throw discoveryError
        }
        let fromCalendars = snapshot.calendars.map(\.source)
        return (fromCalendars + extraSources).reduce(into: [DeviceCalendarSource]()) { unique, source in
            if !unique.contains(where: { $0.identifier == source.identifier }) {
                unique.append(source)
            }
        }
    }

    /// Filters the same way the real adapter's predicate does, rather than returning everything
    /// scripted: a fake that ignores the window would let a bounded-window bug pass CI, and the
    /// bounded-window rule is the one spec 3.24 calls the most dangerous line in the phase.
    func events(in range: DateInterval, calendarIdentifiers: Set<String>) async throws -> [DeviceEvent] {
        eventFetchCount += 1
        lastRequestedRange = range
        lastRequestedCalendarIdentifiers = calendarIdentifiers

        // Spec 3.23's "never run two passes concurrently", made observable. The suspension is
        // what gives a broken guard the chance to fail: without it every pass would complete
        // inside one actor hop and overlap would be impossible to produce, so a test asserting
        // the invariant would pass whether or not the guard existed.
        concurrentEventFetches += 1
        peakConcurrentEventFetches = max(peakConcurrentEventFetches, concurrentEventFetches)
        await Task.yield()
        defer { concurrentEventFetches -= 1 }

        if let eventFetchError {
            throw eventFetchError
        }

        return deviceEvents.filter { event in
            guard calendarIdentifiers.contains(event.calendarIdentifier) else { return false }
            // A repeating series is reported whenever it *reaches* the window, which the real
            // predicate resolves by expanding it. Approximated here as "starts before the window
            // ends", which over-reports rather than under-reports — the safe direction, since an
            // under-reporting fake would make a wrongly-inferred deletion look correct.
            if !event.recurrenceRules.isEmpty {
                return event.startDate < range.end
            }
            return event.startDate < range.end && event.endDate > range.start
        }
    }

    /// Someone added, removed, renamed or recoloured a calendar in Settings between passes.
    func simulateDeviceChange(to snapshot: DeviceCalendarSnapshot) {
        self.snapshot = snapshot
    }

    /// Someone created, edited or deleted an event in Apple Calendar between passes.
    func simulateDeviceEventChange(to events: [DeviceEvent]) {
        deviceEvents = events
    }

    // MARK: - Phase 3E: change observation

    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var refreshSourcesCount = 0

    func changeObservations() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            changeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeContinuations[id] = nil }
            }
        }
    }

    func refreshSources() async {
        refreshSourcesCount += 1
    }

    /// The device telling us something changed — one `EKEventStoreChanged`. Post several in a row
    /// to model the burst an account sync produces, which is the case coalescing exists for.
    func simulateExternalChangeNotification(count: Int = 1) {
        for _ in 0..<count {
            for continuation in changeContinuations.values {
                continuation.yield(())
            }
        }
    }

    // MARK: - Phase 3D: writes

    /// Spec 3.36: injectable failure **by class**, which is the whole point of the taxonomy —
    /// a fake that could only fail one way could not prove that a permission failure and a
    /// transient one are handled differently.
    var saveFailure: DeviceWriteFailure?
    var removeFailure: DeviceWriteFailure?
    /// Every write this store was asked to perform, in order. A test asserts on *what was asked*
    /// as much as on what came back — "the adapter patched only the title" is a claim about the
    /// request, and nothing in the response could reveal it.
    private(set) var writeLog: [DeviceEventWrite] = []
    private(set) var removeLog: [(identifier: String, span: DeviceEventSpan)] = []
    /// Runs immediately before a save is applied, so a test can simulate someone else editing
    /// the event between our fetch and our write — the race spec 3.22 exists for.
    var beforeSave: (() -> Void)?
    private var nextIdentifierNumber = 0

    func event(withIdentifier identifier: String) async throws -> DeviceEvent? {
        deviceEvents.first { $0.identifier == identifier && !$0.isDetached }
    }

    /// Applies exactly `write.fields`, the same discipline the real adapter follows, so a test
    /// that proves an unmodelled field survived is proving something about the contract rather
    /// than about this fake's laziness.
    func save(_ write: DeviceEventWrite) async throws -> DeviceWriteReceipt {
        writeLog.append(write)
        beforeSave?()
        if let saveFailure {
            throw saveFailure
        }

        guard let identifier = write.identifier else {
            nextIdentifierNumber += 1
            var created = write.event
            created.identifier = "fake-event-\(nextIdentifierNumber)"
            created.externalIdentifier = "fake-external-\(nextIdentifierNumber)"
            created.lastModified = Date(timeIntervalSinceReferenceDate: Double(800_000_000 + nextIdentifierNumber))
            deviceEvents.append(created)
            return DeviceWriteReceipt(identifier: created.identifier, externalIdentifier: created.externalIdentifier, lastModified: created.lastModified)
        }

        guard let index = deviceEvents.firstIndex(where: { $0.identifier == identifier && !$0.isDetached }) else {
            throw DeviceWriteFailure.permanent
        }

        // Spec 3.20's two spans, modelled the way EventKit behaves — because a fake that treated
        // an occurrence-addressed save as an ordinary one would let the bug it exists to catch
        // (a "this event only" edit creating a second event) pass CI.
        if let occurrenceDate = write.occurrenceDate {
            return try applySpan(write, to: index, occurrenceDate: occurrenceDate)
        }

        var updated = deviceEvents[index]
        updated.apply(write.event, fields: write.fields)
        updated.lastModified = (updated.lastModified ?? Date(timeIntervalSinceReferenceDate: 800_000_000)).addingTimeInterval(1)
        deviceEvents[index] = updated
        return DeviceWriteReceipt(identifier: updated.identifier, externalIdentifier: updated.externalIdentifier, lastModified: updated.lastModified)
    }

    /// `.thisEvent` on an occurrence **detaches** it — the series keeps its identifier and gains
    /// a detachment. `.futureEvents` **splits** the series: the master is truncated to end before
    /// the occurrence, and a new series takes over from there with its own identifier.
    private func applySpan(_ write: DeviceEventWrite, to index: Int, occurrenceDate: Date) throws -> DeviceWriteReceipt {
        let master = deviceEvents[index]

        switch write.span {
        case .thisEvent:
            if let existing = deviceEvents.firstIndex(where: { $0.identifier == master.identifier && $0.isDetached && $0.occurrenceDate == occurrenceDate }) {
                var detached = deviceEvents[existing]
                detached.apply(write.event, fields: write.fields)
                detached.lastModified = (detached.lastModified ?? Date(timeIntervalSinceReferenceDate: 800_000_000)).addingTimeInterval(1)
                deviceEvents[existing] = detached
                return DeviceWriteReceipt(identifier: detached.identifier, externalIdentifier: detached.externalIdentifier, lastModified: detached.lastModified)
            }

            var detached = master
            detached.apply(write.event, fields: write.fields)
            detached.isDetached = true
            detached.occurrenceDate = occurrenceDate
            detached.recurrenceRules = master.recurrenceRules
            detached.lastModified = (master.lastModified ?? Date(timeIntervalSinceReferenceDate: 800_000_000)).addingTimeInterval(1)
            deviceEvents.append(detached)
            // EventKit keeps the series' identifier on a detachment; the occurrence date is the
            // other half of its identity (spec 3C.1).
            return DeviceWriteReceipt(identifier: detached.identifier, externalIdentifier: detached.externalIdentifier, lastModified: detached.lastModified)

        case .futureEvents:
            nextIdentifierNumber += 1
            var truncated = master
            truncated.recurrenceRules = master.recurrenceRules.map { rule in
                var bounded = rule
                bounded.end = .endDate(occurrenceDate.addingTimeInterval(-1))
                return bounded
            }
            truncated.lastModified = (master.lastModified ?? Date(timeIntervalSinceReferenceDate: 800_000_000)).addingTimeInterval(1)
            deviceEvents[index] = truncated

            var newSeries = master
            newSeries.apply(write.event, fields: write.fields)
            newSeries.identifier = "fake-series-\(nextIdentifierNumber)"
            newSeries.externalIdentifier = "fake-series-external-\(nextIdentifierNumber)"
            newSeries.startDate = write.event.startDate
            newSeries.endDate = write.event.endDate
            newSeries.isDetached = false
            newSeries.occurrenceDate = nil
            newSeries.lastModified = truncated.lastModified
            deviceEvents.append(newSeries)
            return DeviceWriteReceipt(identifier: newSeries.identifier, externalIdentifier: newSeries.externalIdentifier, lastModified: newSeries.lastModified)
        }
    }

    func remove(identifier: String, span: DeviceEventSpan) async throws {
        removeLog.append((identifier, span))
        if let removeFailure {
            throw removeFailure
        }
        deviceEvents.removeAll { $0.identifier == identifier }
    }
}

extension DeviceEvent {
    /// Copies exactly `fields` across from `other`, leaving every other field — including every
    /// one Better Calendar does not model — untouched. Spec 3.17's rule, as one function.
    mutating func apply(_ other: DeviceEvent, fields: Set<DeviceEventField>) {
        for field in fields {
            switch field {
            case .title: title = other.title
            case .notes: notes = other.notes
            case .location: location = other.location
            case .url: urlString = other.urlString
            case .startDate: startDate = other.startDate
            case .endDate: endDate = other.endDate
            case .isAllDay: isAllDay = other.isAllDay
            case .timeZone: timeZoneIdentifier = other.timeZoneIdentifier
            case .availability: availability = other.availability
            case .alarms: alarms = other.alarms
            case .recurrence: recurrenceRules = other.recurrenceRules
            }
        }
    }
}
