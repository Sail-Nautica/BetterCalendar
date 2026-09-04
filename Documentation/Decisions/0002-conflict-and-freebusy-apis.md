# ADR 0002 — Conflict detection and free/busy: API surface and scope (spec 2.6/2.7)

- **Status:** Accepted; Decision 2 superseded by the Phase 3C amendment below
- **Date:** 2026-09-02, amended 2026-09-04 (Phase 3C)
- **Scope:** Phase 2 M5; amended in Phase 3C M4
- **Relates to:** `Instructions/phase2_specification.md` §2.6, §2.7 (BC-ENG-003, BC-ENG-004),
  `Instructions/phase2plan.md`'s M5 section

## Context

Spec 2.6/2.7 ask for conflict detection and free/busy as internal engine APIs, with **no UI in
Phase 2** — they exist so Phase 11 (scheduling pages) and Phase 12 (intelligence) can be built
later without reopening the event engine. That "no consumer yet" framing means the two decisions
below can't be settled by "what does the screen need," and were made instead against the letter of
the spec and the shape of the existing engine.

## Decision 1 — `ConflictIndex` indexes stored rows, not expanded occurrences

`Domain/Engine/ConflictIndex.swift` indexes each `CalendarEvent` row's own `startDate`/`endDate`.
For a recurring master, that is its **first occurrence only** — an unmodified future occurrence of
a weekly series has no row of its own and is not separately checked for conflicts. A per-occurrence
replacement event (from a "This Event" edit, BC-REC-010) *is* its own stored row and is fully
covered, since it is a plain non-recurring `CalendarEvent` like any other.

This mirrors the type signature the plan describes — `reindex(movedFrom: CalendarEvent?, to:
CalendarEvent?)` — which only makes sense for an entity with one stable id and one current
interval. `RecurrenceExpander` output has neither: a single master can produce any number of
occurrences over a range, none of which own a persisted id `reindex` could key off, and the whole
point of the incremental (not O(n) rescan) design is a stable one-entry-per-indexed-thing mapping.

`FreeBusy`, by contrast, *does* expand recurring events (`Domain/Engine/FreeBusy.swift` calls
`RecurrenceExpander` directly) — see Decision 2 for why that asymmetry is intentional rather than
an oversight.

### Consequences

- "Is this specific occurrence of my Monday standup double-booked" is not answerable by
  `ConflictIndex` today unless that occurrence has its own replacement row.
- A conflict-warning UI (Phase 11) checking a *specific slot* — the shape BC-ENG-003's "flagged in
  Day and Week view data" wording implies — will need occurrence-aware conflict checking that
  doesn't exist yet. The cheapest path when that lands is combining `ConflictIndex`'s interval
  machinery with `OccurrenceCache`'s already-expanded output for the visible range, rather than
  reinventing either.

### Revisit trigger

Revisit when Phase 11 actually specifies a conflict-warning screen — build occurrence-level
conflict checking against the real screen's requirements rather than speculatively now.

## Decision 2 — `includeTentative` and "declined" are reserved no-ops

Spec 2.7 says free/busy "excludes cancelled and declined events" regardless of
`includeTentative`. Phase 2 explicitly excludes attendees and invitations (spec 2.0), and
`EventAvailability` is only `.busy`/`.free` — there is no tentative state and no attendee-response
concept anywhere in the domain model to exclude by.

`FreeBusy.Query.includeTentative` is kept on the query shape (default `true`) but is currently
unread by `FreeBusy.query` — a no-op, documented as such on the property itself. "Cancelled" *is*
implemented: `RecurrenceException.exceptionType == .cancelled` occurrences are excluded, because
`RecurrenceExpander` already skips any excepted slot for both `.cancelled` and `.modified` (the
same mechanism `RecurrenceSplitter` relies on).

This is the same pattern `ProviderMetadata`'s already-scaffolded-but-unused fields follow
(CLAUDE.md) — keeping the parameter on the shape now means Phase 3/4 (which do add attendees) only
have to change this function's body, not every call site.

### Revisit trigger — fired in Phase 3C

Revisit once Phase 3/4 add an attendee/RSVP model or a tentative `EventAvailability` case —
`includeTentative` should stop being a no-op at that point, not stay one out of inertia.

## Amendment (Phase 3C, 2026-09-04) — Decision 2 is retired

Phase 3C supplies both things Decision 2 was waiting on: `EventAttendee` with a
`participationStatus` and an `isCurrentUser` flag (spec 3C.5), and `EventStatus` on
`ProviderMetadata`, which is what the `events.status` column has been carrying since `v001`
without anyone reading it. So the reservations become behaviour:

* **Declined is implemented.** An event whose current-user attendee answered `.declined`
  contributes no busy time. The user is not busy at a meeting they said no to.
* **Cancelled is implemented at the event level too.** Decision 2's "cancelled *is* implemented"
  referred only to cancelled *occurrences* of a series, via `RecurrenceException`. An event the
  organizer cancelled outright is now excluded from free/busy **and** from `ConflictIndex`, while
  still being displayed with its status shown — it is information, not a commitment.
* **`includeTentative` is no longer a no-op.** With it `false`, an event whose status is
  `.tentative`, or on which the current user answered "maybe", stops occupying time.

The rule lives in one place — `CalendarEvent.occupiesTime(includeTentative:)` — which both
`FreeBusy.query` and `ConflictIndex.insert` call, so the two cannot drift apart about what "busy"
means. They differ in exactly one respect, deliberately: `ConflictIndex` always passes the
default `true`, because a "maybe" on the calendar is still worth warning about, whereas an
explicit free/busy query is entitled to ask for firm commitments only.

Decision 1 is unchanged and its own revisit trigger (Phase 11 specifying a conflict-warning
screen) still stands.

Covered by `FreeBusyTests` and `ConflictDetectionTests`.

## Non-decisions

- Both types are pure `Domain/Engine/` code with no `Features/` call site — `BetterCalendarStore`
  exposes them (`conflictingEventIDs(for:)`, `freeBusy(_:)`) the same engine-API-only way M4
  exposed `editSeries`/`deleteSeries`.
- No perf test backs the "sorted-interval structure" claim yet — `ConflictIndex`'s query path
  early-exits a sorted scan (O(log n + k) in spirit), but insertion is a plain linear insert-to-
  keep-sorted. Spec 2.19's actual wall-clock targets (conflict recompute < 50ms at 10k events) are
  M7's job (`EnginePerformanceTests`), not asserted here.
