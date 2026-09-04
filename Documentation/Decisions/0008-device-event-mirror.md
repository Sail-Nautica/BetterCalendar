# ADR 0008 — Mirroring device events: identity, the seam's shape, and what "deleted" is allowed to mean (spec 3.11–3.17)

- **Status:** Accepted
- **Date:** 2026-09-04
- **Scope:** Phase 3C
- **Relates to:** `Instructions/phase3c_specification.md`, `Instructions/phase3_specification.md`
  §3.11–§3.17, §3.24,
  `Better Calendar/Domain/DeviceEvent.swift`,
  `Better Calendar/Domain/Engine/DeviceEventMapper.swift`,
  `Better Calendar/Domain/Engine/DeviceEventMirror.swift`,
  `Better Calendar/Data/EventKit/EventKitDeviceStore.swift`

## Context

Phase 3C fills the calendars Phase 3B discovered with the user's real events. It is the first
phase where a bug in this app can damage data the user did not create in it, and four questions
had to be answered before the first row could be written. Each is expensive to change afterwards,
because the answer ends up on disk in every installed database.

## Decision 1 — Local ids are derived from provider identity, not minted

A mirrored event's local `UUID` is a **pure function** of what the device calls it: RFC 4122
version 5, over a fixed namespace, with the name `event:<eventIdentifier>` — or
`event:<eventIdentifier>@<occurrenceDate>` for a detached occurrence, because every detachment of
one series shares the identifier and neither EventKit identifier is unique on its own (spec
3C.1). Reminder, attendee, exception and tombstone ids are derived the same way.

`DeviceCalendarMirror` mints calendar ids with an injected `makeIdentifier` instead. That is not
an inconsistency: a calendar row is *marked* unavailable rather than deleted, so it survives to be
matched again, and there are dozens of them. Events are deleted, and there are thousands.

Three things fall out of derivation that a random id would each have to be engineered:

* **Idempotence.** A second pass over an unchanged device maps to byte-identical rows and writes
  nothing — spec 3C.8's requirement becomes structural rather than something the diff has to be
  careful about.
* **Reconstructibility.** Deleting the entire local database and re-mirroring produces the same
  calendar, which is spec 3C.1's second property and what makes the mirror safe to throw away.
* **A working resurrection guard.** Tombstones are keyed by local id (spec 2.13). With minted
  ids, an event deleted here and re-reported by the device would arrive under a *new* id and walk
  straight past the guard.

### Consequences

The namespace constant can never change. Every mirrored row in every installed database is
derived from it, and a new one would re-key the entire mirror and orphan every tombstone. It is
commented as such at the declaration.

A device that recycles an `eventIdentifier` for a genuinely different event would collide. EventKit
does not do this in practice, and the alternative — matching on title and time — is the failure
mode spec 3C.1 explicitly forbids.

## Decision 2 — The seam returns a series' master, not its expanded occurrences

`EventKitStore.events(in:calendarIdentifiers:)` returns one `DeviceEvent` per **master** plus one
per **detached occurrence**, never the expansion.

`EKEventStore.events(matching:)` expands recurrence: a weekly series over a month-long window
comes back as four or five `EKEvent`s sharing one identifier. Mirroring those directly would
write one row per occurrence and discard the rule, which contradicts spec 3C.1 (the local engine
stores a master and expands through `RecurrenceExpander`) and would make every window change
rewrite the calendar.

So `EventKitDeviceStore` collapses them: each distinct identifier is re-fetched once through
`event(withIdentifier:)`, which returns the series master carrying its own start date and rules.
That needs a live `EKEventStore`, so it belongs on the EventKit side of the seam — and everything
after it stays pure and testable with no device (BC-EK-024).

The fetch is also `async`, unlike `discoverCalendars()`. It is bounded by the size of the user's
calendar rather than by a handful of calendars, and spec 3.27 requires that rendering never block
on it; the real adapter runs its EventKit work in a detached task, capturing only value types.

## Decision 3 — The device wins by *content*, not by timestamp

The mirror updates a row when the mapped device event differs from the stored one — not when
`lastModified` is newer.

`providerVersion` still carries the device's last-modified value, because Phase 3D needs it for
the optimistic-concurrency check spec 3.22 describes. But using it as the *change detector* would
mean trusting a coarse, provider-supplied timestamp (whole seconds on some sources) to decide
whether to look at the fields at all.

Comparing content instead does two things at once. It makes idempotence structural — an unchanged
device maps to an equal row, so there is nothing to write — and it makes spec 3C.1's "nothing
this app does can disagree with the device" true rather than hoped for: anything that diverged
locally is mapped back on the next pass. `updatedAt` and `versionNumber` are excluded from the
comparison, since those are bookkeeping the pass itself writes.

This is also why the mapping has to be *deterministic* to the byte: `providerRawFields` is
serialised with sorted keys, `providerVersion` is formatted without a `DateFormatter`, and every
derived id is stable. An unstable encoding anywhere would make every pass look like a change and
the mirror would rewrite itself forever.

## Decision 4 — A row is deleted only when its own start is inside the fetched window

Spec 3.24 calls the bounded-window rule the single most dangerous line in the phase. The
implementation requires three independent conditions before removing a row: it is mirrored and
carries provider identity; its calendar was in the fetch; and **its own start date lies inside
the fetched window**.

The third is the strict reading, and it was chosen deliberately over the looser "the row's
interval intersects the window". A series that began before the window and recurs into it is
reported by the fetch while it exists, so it is matched normally — but if it were deleted
externally, this pass does *not* remove it. A later pass whose window covers its start does.

Erring toward a stale row that a wider window cleans up is the right direction to be wrong in.
Erring the other way deletes calendars.

An external deletion writes a tombstone with the new `TombstoneCause.providerDeletion`, so the
journal distinguishes "the user deleted this here" from "it went away out there", and so Phase 3D
does not later try to delete an event that is already gone.

### Consequences

Until Phase 3E persists per-calendar reconciliation state and widens the window with the visible
range, an external deletion of a long-running series is detected only when a pass happens to
cover the series' start. The window is 60 days back and 180 days forward, which covers the
overwhelming majority of what a user is looking at.

## Non-decisions

- **Nothing in this phase writes to EventKit.** The adapter still has no `save` or `remove`
  member; the pass emits no outbox row, exactly as Phase 3B's discovery does.
- **A local edit to a mirrored event is not gated.** Spec 3C.0 asserts there are no local edits
  to mirrored events until Phase 3D, and the model layer already refuses the two cases that would
  do damage — a read-only calendar (spec 3.10) and a repeat pattern the engine cannot express
  (spec 3C.3). A blanket "mirrored events are read-only" gate would have to be torn out in 3D,
  and Decision 3 already makes a stray local edit self-correcting.
- **Alarms are mirrored but never scheduled.** The exclusion is the prerequisite work in
  `LocalNotificationPlanner`, unchanged; 3C is only the first phase with real events for it to
  exclude (BC-EK-016).
