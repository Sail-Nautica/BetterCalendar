import XCTest
@testable import Better_Calendar

/// Spec 3C.11's "The pass" block: `DeviceEventMirror` in isolation.
///
/// The deletion tests are the point of this file. Spec 3.24 calls the bounded-window rule the
/// single most dangerous line in the phase — a window computed slightly wrong turns into silent
/// deletion of events the user still has — so every one of its three preconditions is asserted
/// separately, and each is asserted by showing that violating it deletes *nothing*.
final class DeviceEventMirrorTests: XCTestCase {

    // MARK: - Inserts

    func testAnExternalCreateAppears() {
        let plan = DeviceEventMirror.plan(DeviceTestData.input(devices: [DeviceTestData.event()]), now: DeviceTestData.now)

        let inserted = DeviceTestData.upsertedEvents(plan)
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted.first?.title, "Standup")
        XCTAssertEqual(inserted.first?.calendarID, DeviceTestData.personalRowID)
        XCTAssertEqual(inserted.first?.versionNumber, 1)
        XCTAssertEqual(plan.summary.inserted, 1)
    }

    /// Spec 3C.2: an event whose calendar is not mirrored is skipped, not orphaned onto whatever
    /// calendar happens to be first.
    func testAnEventOnAnUnmirroredCalendarIsSkippedRatherThanOrphaned() {
        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [DeviceTestData.event(calendarIdentifier: "cal-not-mirrored")]),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary.skippedUnmirroredCalendar, 1)
    }

    /// Spec 3.2/3B: an inbound change carries no outbox row. One here would mean Phase 3D started
    /// writing to EventKit by accident.
    func testAPassEnqueuesNoOutboundMutation() {
        let plan = DeviceEventMirror.plan(DeviceTestData.input(devices: [DeviceTestData.event()]), now: DeviceTestData.now)

        XCTAssertTrue(plan.transaction.outboxRows.isEmpty)
        XCTAssertEqual(plan.journalEntries.map(\.source), [.reconciliation])
    }

    // MARK: - Updates and idempotence (spec 3C.8)

    func testAnExternalUpdateUpdatesInPlaceWithTheSameRowID() {
        let existing = mirrored(DeviceTestData.event())
        let renamed = DeviceTestData.event(title: "Standup (moved)", lastModified: TestData.date("2026-09-03T08:00:00Z"))

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [renamed], existingEvents: [existing]),
            now: DeviceTestData.now
        )

        let updated = DeviceTestData.upsertedEvents(plan)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.id, existing.id, "the row must be updated, not replaced")
        XCTAssertEqual(updated.first?.title, "Standup (moved)")
        XCTAssertEqual(updated.first?.versionNumber, existing.versionNumber + 1)
        XCTAssertEqual(updated.first?.createdAt, existing.createdAt, "first-seen date must not jump on every edit")
        XCTAssertEqual(plan.summary.updated, 1)
    }

    func testRunningThePassTwiceChangesNothingTheSecondTime() {
        let devices = [
            DeviceTestData.event(),
            DeviceTestData.event(identifier: "evt-2", calendarIdentifier: "cal-work", title: "1:1", attendees: [
                DeviceEventAttendee(name: "Dana", email: "dana@example.com", participationStatus: .accepted, isOrganizer: true)
            ]),
            DeviceTestData.event(identifier: "evt-3", title: "Weekly", recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)])
        ]

        let first = DeviceEventMirror.plan(DeviceTestData.input(devices: devices), now: DeviceTestData.now)
        XCTAssertEqual(first.summary.inserted, 3)

        let second = DeviceEventMirror.plan(
            DeviceTestData.input(devices: devices, existingEvents: DeviceTestData.upsertedEvents(first)),
            now: DeviceTestData.now.addingTimeInterval(3_600)
        )

        XCTAssertTrue(second.isEmpty, "a pass over an unchanged device must produce an empty transaction")
        XCTAssertTrue(second.transaction.isEmpty)
        XCTAssertEqual(second.summary.unchanged, 3)
        XCTAssertTrue(second.summary.isNoOp)
    }

    /// Spec 3C.1: the device is authoritative. A row that diverged locally is mapped back rather
    /// than left disagreeing with the device nobody else can see.
    func testALocallyDivergedMirrorRowIsBroughtBackToTheDeviceState() {
        var diverged = mirrored(DeviceTestData.event())
        diverged.title = "Renamed locally"

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [DeviceTestData.event()], existingEvents: [diverged]),
            now: DeviceTestData.now
        )

        XCTAssertEqual(DeviceTestData.upsertedEvents(plan).first?.title, "Standup")
    }

    // MARK: - Deletions and the bounded-window rule (spec 3C.8 / 3.24)

    func testAnExternalDeleteInsideTheWindowRemovesTheRowAndWritesAProviderTombstone() {
        let existing = mirrored(DeviceTestData.event())

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [], existingEvents: [existing]),
            now: DeviceTestData.now
        )

        XCTAssertEqual(DeviceTestData.deletedEventIDs(plan), [existing.id])
        XCTAssertEqual(plan.tombstones.count, 1)
        XCTAssertEqual(plan.tombstones.first?.entityID, existing.id)
        XCTAssertEqual(plan.tombstones.first?.deletedBy, .providerDeletion, "the journal must tell 'deleted here' from 'gone out there'")
        XCTAssertNotNil(plan.tombstones.first?.eventSnapshotJSON)
        XCTAssertEqual(plan.summary.deleted, 1)
    }

    /// Precondition 3, and the one spec 3.24 warns about by name.
    func testAnEventOutsideTheFetchedWindowIsNeverInferredToBeDeleted() {
        let outside = mirrored(
            DeviceTestData.event(
                startDate: TestData.date("2026-11-10T14:00:00Z"),
                endDate: TestData.date("2026-11-10T15:00:00Z")
            )
        )

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [], existingEvents: [outside]),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty, "absence outside the queried range says nothing at all")
        XCTAssertEqual(plan.summary.deleted, 0)
    }

    /// Precondition 2. BC-EK-005: toggling a calendar off removes its events from every view
    /// without deleting them — which only holds if a pass that did not fetch a calendar cannot
    /// delete from it.
    func testACalendarExcludedFromTheFetchNeverHasItsEventsDeleted() {
        let onWork = mirrored(DeviceTestData.event(calendarIdentifier: "cal-work"), calendarID: DeviceTestData.workRowID)

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(
                devices: [],
                fetchedCalendarIDs: [DeviceTestData.personalRowID],
                existingEvents: [onWork]
            ),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty)
    }

    /// Precondition 1. A Better Calendar-owned event is never this pass's business, and a local
    /// calendar is never fetched from in the first place.
    func testABetterCalendarOwnedEventIsNeverTouchedByAPass() {
        let localEvent = TestData.event(startDate: TestData.date("2026-09-12T14:00:00Z"), endDate: TestData.date("2026-09-12T15:00:00Z"))
        let calendars = DeviceTestData.mirroredCalendars + [TestData.calendar()]

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(
                devices: [],
                fetchedCalendarIDs: [DeviceTestData.personalRowID, DeviceTestData.workRowID, TestData.calendarID],
                calendars: calendars,
                existingEvents: [localEvent]
            ),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty, "a local event inside the window is still not ours to delete")
    }

    /// A row on a mirrored calendar that carries no provider identity was not written by this
    /// pass, so it is not this pass's to remove either.
    func testARowWithoutProviderIdentityIsNotDeleted() {
        var strayLocalRow = TestData.event(startDate: TestData.date("2026-09-12T14:00:00Z"), endDate: TestData.date("2026-09-12T15:00:00Z"))
        strayLocalRow.calendarID = DeviceTestData.personalRowID

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [], existingEvents: [strayLocalRow]),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty)
    }

    /// Spec 3C.8: the existing resurrection guard applies to inbound changes too — a delayed
    /// device report for an event with a live tombstone must not re-create it (BC-ENG-006).
    func testAnEventWithALiveTombstoneIsNotResurrectedByAPass() {
        let device = DeviceTestData.event()
        let localID = DeviceEventIdentity.eventID(for: device.key)
        let tombstone = DeletedObjectTombstone(
            id: UUID(),
            entityType: .event,
            entityID: localID,
            title: "Standup",
            deletedAt: DeviceTestData.now,
            deletedBy: .userEdit
        )

        let plan = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [device], tombstones: [tombstone]),
            now: DeviceTestData.now
        )

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary.skippedTombstoned, 1)
    }

    /// Deselecting a calendar and reselecting it must not duplicate its events — which is what
    /// derived identity buys: the second pass recognises the rows it wrote the first time.
    func testDeselectingAndReselectingACalendarDoesNotDuplicateItsEvents() {
        let device = DeviceTestData.event()
        let first = DeviceEventMirror.plan(DeviceTestData.input(devices: [device]), now: DeviceTestData.now)
        let rows = DeviceTestData.upsertedEvents(first)

        // Off: not fetched, nothing deleted.
        let hidden = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [], fetchedCalendarIDs: [], existingEvents: rows),
            now: DeviceTestData.now
        )
        XCTAssertTrue(hidden.isEmpty)

        // On again: recognised, not re-imported.
        let reselected = DeviceEventMirror.plan(
            DeviceTestData.input(devices: [device], existingEvents: rows),
            now: DeviceTestData.now
        )
        XCTAssertTrue(reselected.isEmpty)
    }

    // MARK: - Series and detachments (spec 3C.3)

    func testADetachedOccurrenceBecomesAReplacementEventPlusAModifiedException() {
        let master = DeviceTestData.event(
            identifier: "series",
            title: "Weekly sync",
            startDate: TestData.date("2026-09-03T14:00:00Z"),
            endDate: TestData.date("2026-09-03T15:00:00Z"),
            recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)]
        )
        let detachment = DeviceTestData.event(
            identifier: "series",
            title: "Weekly sync (moved)",
            startDate: TestData.date("2026-09-17T16:00:00Z"),
            endDate: TestData.date("2026-09-17T17:00:00Z"),
            recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)],
            isDetached: true,
            occurrenceDate: TestData.date("2026-09-17T14:00:00Z")
        )

        let plan = DeviceEventMirror.plan(DeviceTestData.input(devices: [detachment, master]), now: DeviceTestData.now)

        let events = DeviceTestData.upsertedEvents(plan)
        XCTAssertEqual(events.count, 2)

        // Spec 3C.3: the master must be emitted before its detachments, or the detachment has no
        // master to point at.
        let masterRow = events[0]
        let replacement = events[1]
        XCTAssertNotNil(masterRow.recurrence)
        XCTAssertNil(replacement.recurrence, "a detachment is one occurrence, never a series of its own")
        XCTAssertEqual(replacement.recurrenceMasterID, masterRow.id)
        XCTAssertEqual(replacement.recurrenceOriginalStart, TestData.date("2026-09-17T14:00:00Z"))

        let exceptions = DeviceTestData.upsertedExceptions(plan)
        XCTAssertEqual(exceptions.count, 1)
        XCTAssertEqual(exceptions.first?.exceptionType, .modified)
        XCTAssertEqual(exceptions.first?.masterEventID, masterRow.id)
        XCTAssertEqual(exceptions.first?.replacementEventID, replacement.id)
    }

    /// The exception hides the master's own slot, so the occurrence is shown once — as the
    /// replacement — rather than twice.
    func testTheDetachedOccurrenceReplacesRatherThanDuplicatesTheGeneratedOne() {
        let master = DeviceTestData.event(
            identifier: "series",
            startDate: TestData.date("2026-09-03T14:00:00Z"),
            endDate: TestData.date("2026-09-03T15:00:00Z"),
            timeZoneIdentifier: "UTC",
            recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)]
        )
        let detachment = DeviceTestData.event(
            identifier: "series",
            startDate: TestData.date("2026-09-17T16:00:00Z"),
            endDate: TestData.date("2026-09-17T17:00:00Z"),
            timeZoneIdentifier: "UTC",
            recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)],
            isDetached: true,
            occurrenceDate: TestData.date("2026-09-17T14:00:00Z")
        )

        let plan = DeviceEventMirror.plan(DeviceTestData.input(devices: [master, detachment]), now: DeviceTestData.now)
        let events = DeviceTestData.upsertedEvents(plan)
        let exceptions = DeviceTestData.upsertedExceptions(plan)

        let occurrences = RecurrenceExpander().occurrences(
            of: events[0],
            in: DateInterval(start: TestData.date("2026-09-01T00:00:00Z"), end: TestData.date("2026-10-01T00:00:00Z")),
            exceptions: exceptions
        )

        XCTAssertFalse(
            occurrences.contains { $0.occurrenceStartDate == TestData.date("2026-09-17T14:00:00Z") },
            "the master's own slot at the detached occurrence must be hidden"
        )
        XCTAssertEqual(
            occurrences.map(\.occurrenceStartDate),
            [
                TestData.date("2026-09-03T14:00:00Z"),
                TestData.date("2026-09-10T14:00:00Z"),
                TestData.date("2026-09-24T14:00:00Z")
            ],
            "every other Thursday in the series is untouched"
        )
    }

    func testDetachmentsAreIdempotentAcrossPasses() {
        let master = DeviceTestData.event(identifier: "series", recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)])
        let detachment = DeviceTestData.event(
            identifier: "series",
            startDate: TestData.date("2026-09-17T16:00:00Z"),
            endDate: TestData.date("2026-09-17T17:00:00Z"),
            recurrenceRules: [DeviceRecurrenceRule(frequency: .weekly)],
            isDetached: true,
            occurrenceDate: TestData.date("2026-09-17T14:00:00Z")
        )

        let first = DeviceEventMirror.plan(DeviceTestData.input(devices: [master, detachment]), now: DeviceTestData.now)
        let second = DeviceEventMirror.plan(
            DeviceTestData.input(
                devices: [master, detachment],
                existingEvents: DeviceTestData.upsertedEvents(first),
                existingExceptions: DeviceTestData.upsertedExceptions(first)
            ),
            now: DeviceTestData.now.addingTimeInterval(3_600)
        )

        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - Helpers

    /// The local row a previous pass would have written for `device`.
    private func mirrored(_ device: DeviceEvent, calendarID: UUID = DeviceTestData.personalRowID) -> CalendarEvent {
        var event = DeviceEventMapper.map(
            device,
            in: DeviceTestData.context(calendarID: calendarID, localID: DeviceEventIdentity.eventID(for: device.key)),
            now: DeviceTestData.now
        )
        event.versionNumber = 1
        return event
    }
}
