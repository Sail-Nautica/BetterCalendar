# Phase 0 / Phase 1 Completion Backlog

Source of truth for the Phase 1 completion effort. Derived from
`Instructions/phase0_phase1_specification.md`. Every item has a stable requirement
ID per spec 0.3 — use these IDs in commits, tests, and PR descriptions.

## Baseline (verified 2026-08-08, re-audited 2026-08-08)

The three "Done" rows below were re-verified against the actual code and tests
(not just re-read from this file): BC-NOT-001, BC-EVT-010, and BC-EVT-011 all
PASS their acceptance criteria. The "Not started" rows were spot-checked
against the actual implementation, not assumed — see per-item notes.

- 66 tests green via:
  `xcodebuild test -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17'`
- Sole dependency: GRDB 6.29.3. **No new third-party dependencies** without explicit approval.
- Test target `MyAppTests` was repaired (TEST_HOST + module name) as the first commit on this branch.

## Ratified scope decisions

- **SPM package restructure (spec 0.4): DEFERRED.** Code stays in one app target with
  `Domain/ Data/ Features/ Shared/` folders. The layering the packages would enforce is
  already respected (Domain imports neither SwiftUI nor GRDB). Revisit before Phase 3.
  This is a known, accepted deviation — see `Documentation/Decisions/`.
- **Done bar:** functional features + unit tests in the existing XCTest style.
  Snapshot/UI tests, the 10k-event stress fixture, and manual accessibility audit are
  explicitly out of scope for this run.
- Items requiring humans (wireframe approval, VoiceOver/Switch Control passes, real-device
  performance validation, TestFlight) are out of scope and tracked as residual risk.

---

## Status

Work happens on branch `phase1-completion`. Status is updated as each item lands
green; an item is only `Done` once the full suite passes and it has its own commit.

| ID | Item | Status | Commit |
| --- | --- | --- | --- |
| — | Test-target repair + backlog + ADR 0001 | Done — 28 tests green | `26de8db` |
| BC-NOT-001 | Multiple reminders per event | Done — 38 tests green | `aa83f18` |
| BC-EVT-010 | Field limit validation | Done — 43 tests green | `95c5f88` |
| BC-EVT-011 | Floating event model | Done — 50 tests green | `37b29ce` |
| BC-DEL-001 | Durable soft-delete / undo persistence | Done — 66 tests green | `c910492` |
| BC-CAL-001 | Calendar list completeness (reorder, counts) | Done — 66 tests green | `c910492` |
| BC-SET-001 | Settings persistence layer | Done — 66 tests green | `c910492` |
| BC-SET-002 | Settings screen | Done — 66 tests green | `c910492` |
| BC-VIEW-010 | Persist view state | Done — 66 tests green | `c910492` |
| BC-ONB-001 | First-launch onboarding | Done — 66 tests green | `c910492` |
| BC-TZ-001 | Time-zone settings (secondary zone, search, lock) | Not started | — |
| BC-REC-010 | Recurrence exceptions + edit/delete scope | Done — 81 tests green | `bc389ff` |
| BC-REC-011 | Full recurrence editor | Done — 81 tests green | `bc389ff` |
| BC-SRCH-001 | FTS5-backed search | Done — 88 tests green | `fb785d8` |
| BC-SRCH-002 | Search filters | Done — 88 tests green | `fb785d8` |
| BC-VIEW-011 | Agenda view completion | Done — 88 tests green | `fb785d8` |
| Milestone D | Interchange, detail actions, interaction | Not started | — |

Milestone A landed as one combined commit rather than six — the items share
the `AppSettings` type, the `LocalCalendarDatabase` schema, and the store's
persist/rollback machinery closely enough that separating them would mean
re-deriving the same plumbing repeatedly. All 66 tests (50 baseline + 16 new)
pass with every item included.

Full per-item detail for the new rows is under their milestones below; the
table only tracks status.

### Known gaps against the spec (deliberate, not defects)

- **Custom reminder durations (spec 1.12)** — the preset list is implemented in full,
  but arbitrary user-entered durations ("Custom": minutes/hours/days/weeks) are not.
  Deferred out of BC-NOT-001; no backlog item currently owns this.
- ~~**Configurable all-day alert time**~~ — resolved by BC-SET-001;
  `LocalNotificationPlanner.allDayAlertHour` is now sourced from
  `store.settings.allDayReminderHour`, editable in the new Settings screen.

### Resolved since last audit

- ~~**Force-quitting the app before Undo is tapped loses the deleted event permanently.**~~
  Resolved by BC-DEL-001: tombstones now carry a full JSON snapshot of the deleted event
  (migration `v008_add_deletion_snapshot`), restorable via `store.restoreDeletedEvent(_:)`
  and surfaced as "Recently Deleted" in the calendar manager, with a 30-day retention purge.

---

## Milestone A — Data & preference foundations

### BC-NOT-001 — Multiple reminders per event
- Spec 1.12, 0.11. `EventReminder`/`event_reminders` already model a list; `EventDraft`
  and the editor collapse it to a single `reminderOffset`.
- Add/remove multiple reminders in the editor; persist all; dedupe identical offsets.
- `LocalNotificationPlanner` already loops `event.reminders` — verify N reminders schedule N notifications.
- Acceptance: event with 3 reminders round-trips through SQLite and plans 3 distinct notification IDs.

### BC-EVT-010 — Field limit validation
- Spec 0.8: title ≤ 500, location ≤ 1,000, notes ≤ 50,000 characters.
- Enforce in `EventDraft.validationError` with inline errors; do not truncate silently.

### BC-EVT-011 — Floating event model
- Spec 0.9. Schema already permits `event_type = 'floating'`; the domain has no case.
- Model internally (same wall-clock time regardless of zone). UI exposure not required.
- Acceptance: floating event keeps its local clock time across a simulated zone change.

### BC-DEL-001 — Durable soft-delete / undo persistence
- Spec 0.12. **Highest-risk item in Milestone A** — the current implementation can
  silently lose user data, which spec 0.3 lists as a top engineering success criterion.
- `LocalCalendarStore.deleteEvent` (and move/duplicate undo paths) must persist enough
  of the deleted event to reconstruct it from disk, not just from an in-memory closure.
  The existing tombstone table needs the full record (or a serialized snapshot), not
  just `id`/`title`/`deletedAt`.
- Undo must survive the app being backgrounded or force-quit during the undo window;
  a cleanup pass (spec 0.12 "retain soft-deleted data for a cleanup period") should
  purge tombstones only after that period elapses, not immediately.
- Acceptance: delete an event, force-quit the app before tapping Undo, relaunch, and
  confirm the event is still recoverable (or, at minimum, its data was never destroyed
  before the retention period expired).

### BC-CAL-001 — Calendar list completeness
- Spec 1.3. `CalendarManagerView` is missing two listed actions: reorder calendars
  (schema already has `sortOrder`) and showing each calendar's count of future events.
- Acceptance: dragging a calendar row persists its new `sortOrder`; each row shows an
  accurate future-event count that updates after create/delete/move.

### BC-SET-001 — Settings persistence layer
- Spec 1.20. Wire the existing `application_settings` table through a repository API.
- Keys: default calendar, default event duration, default reminder, first day of week,
  show weekends, time format, default calendar view, all-day reminder time, snap interval,
  appearance, reduce calendar animation.

### BC-SET-002 — Settings screen
- Spec 1.20. Surface every BC-SET-001 key. Include "Export data" and "Delete all local data".
- Debug-only diagnostics: schema version, pending notification count, event/master/exception
  counts, reconcile notifications, load sample calendar, reset database.

### BC-VIEW-010 — Persist view state
- Spec 1.2: last selected view, last selected date, visible calendars, preferred week start,
  hour format survive relaunch.

### BC-ONB-001 — First-launch onboarding
- Spec 1.1. Local-only messaging: events live only on this device; Google/Apple/cloud come
  later; notification permission is requested only when a reminder is enabled.
- Must not imply local events are backed up. Shown once (flag via BC-SET-001).

---

## Milestone B — Recurrence correctness ✅ Done

### BC-REC-010 — Recurrence exceptions + edit/delete scope
- Spec 0.10, 1.11. New `RecurrenceException` domain type + `CalendarEvent.recurrenceMasterID`/
  `.recurrenceOriginalStart`, wired through the previously-unused `event_recurrence_exceptions`
  table and the `events.recurrence_master_id`/`.recurrence_original_start` columns.
- A modified occurrence becomes its own standalone replacement `CalendarEvent` (so the existing
  `EventEditorView` edits it with zero new editor UI) plus a `.modified` exception; a deleted
  occurrence becomes a `.cancelled` exception. `RecurrenceExpander.occurrences(of:in:exceptions:)`
  skips both — modified occurrences' replacements surface "for free" via the store's existing
  non-recurring event pass. `LocalNotificationPlanner`/`LocalNotificationScheduling.reconcile`
  thread exceptions through too, so cancelled occurrences stop notifying.
- `EventDetailsView` shows a "This Event"/"All Events" `confirmationDialog` for Edit and Delete
  when the occurrence recurs; store gains `deleteOccurrence(_:)`, `eventForEditingOccurrence(_:)`,
  `existingReplacementEvent(forOccurrenceOf:occurrenceStartDate:)`. Re-editing an already-modified
  occurrence updates the existing replacement rather than creating a second one.
- Move/resize on a recurring occurrence still apply to the whole series (pre-existing behavior,
  unchanged) — per-occurrence move/resize was scoped out; only Edit/Delete needed scope per spec
  1.11's explicit "This Event"/"All Events" dialogs.
- Schema already has room for future "this and future" splitting (per-occurrence exception rows).

### BC-REC-011 — Full recurrence editor
- Spec 1.11. `RecurrenceRule` gains `daysOfMonth`/`setPositions` (columns already existed in
  `event_recurrence_rules`, previously always written `NULL`). `RecurrenceExpander`'s
  `monthlyDates`/`yearlyDates` gained a shared `nthWeekdayDates` helper for positional rules
  ("last Friday" = `setPositions: [-1], weekdays: [.friday]`) and multi-value day-of-month
  support, with the empty-arrays case byte-identical to the old single-day behavior.
- `EventEditorView`'s Repeat section now has all 8 presets (a view-only `RecurrencePreset` enum
  layered over the raw rule fields — "Every 2 Weeks"/"Every Weekday" aren't real
  `RecurrenceFrequency` cases), a Custom mode with weekday multi-select, day-of-month vs.
  day-of-week pattern picker, and an Ends picker (Never/After/On Date) shown for any active
  recurrence, not just Custom.
- `summary` extended to describe positional ("on the last Fri") and explicit-day-of-month
  ("on the 15th") rules.

Landed as one commit (both items touch the same expander/schema/editor files closely enough
that separating them would mean re-deriving the same plumbing). 81 tests green (66 baseline +
15 new): exception round-tripping/skip-behavior, positional/multi-day recurrence expansion,
this-event edit/delete/re-edit flows, and recurrence-rule Codable tolerance.

---

## Milestone C — Search & agenda ✅ Done

### BC-SRCH-001 — FTS5-backed search
- Spec 1.13. `event_search` now indexes `calendar_name`/`url_host` too (migration
  `v009_extend_search_index` — FTS5 tables can't have columns added in place, so this drops
  and recreates the previously-unqueried table under the same name).
- `LocalCalendarRepository` gains `searchEventIDs(matching:) throws -> [UUID]`: an indexed
  FTS5 prefix-per-word query for recall (`SQLiteCalendarRepository`), with an equivalent
  substring-scan fallback in `JSONCalendarRepository`/`StubCalendarRepository` so ranking
  behaves identically regardless of which repository backs the store.
- `BetterCalendarStore.searchEvents(matching:filters:now:)` does the actual ranking in Swift
  (it already holds every event in memory) against the FTS-narrowed candidate set: exact title
  → title prefix → title contains → location → notes → calendar name, future before past on
  ties. `SearchScreen` now calls this instead of scanning in-memory itself.
- Search terms are never logged (no logging exists yet at all — BC-PRIV-001 is Milestone D).

### BC-SRCH-002 — Search filters
- Spec 1.13. New `SearchFilters` domain type (calendar, date range, past/future/all timeframe,
  all-day-only, recurring-only), applied inside `searchEvents(matching:filters:now:)`.
  `SearchScreen` gained a Filters section exposing all five dimensions.

### BC-VIEW-011 — Agenda view completion
- Spec 1.9. `AgendaScreen` rewritten: occurrences grouped into per-date `Section`s (sticky via
  `.listStyle(.plain)`) with all-day occurrences sorted before timed ones within a day; days
  with zero occurrences are simply omitted rather than shown empty; past occurrences render at
  reduced opacity; a toolbar "Today" button scrolls to today's section via `ScrollViewReader`.
- Replaced the fixed `-1 day…+90 day` window with a growing forward horizon (starts at 30
  days, extends by 30-day pages via `.onAppear` on the last row, capped at 365 days) — the
  past side stays a fixed 7-day window since an agenda's job is showing what's coming up, not
  unbounded scrollback; this is a deliberate scope decision, not an oversight.

Landed as one commit (all three touch the same search/store/agenda surface closely enough
that separating them would add little). 88 tests green (81 baseline + 7 new): FTS5 recall
across all five indexed fields, ranking-tier ordering, future-before-past tie-breaking, and
each filter dimension. Agenda's grouping/sticky-header/pagination behavior itself is UI-level
and follows the project's existing "Done bar" (functional + unit tests; snapshot/UI tests
out of scope) — verified by build success and code review, not a dedicated test.

---

## Milestone D — Interchange, detail actions, interaction

### BC-ICS-001 — ICS import completeness
- Spec 1.18. Currently: SUMMARY/DTSTART/DTEND/LOCATION/DESCRIPTION only, paste-only.
- Add: RRULE, EXDATE, RECURRENCE-ID, VALARM, UID, DURATION, TZID (incl. unknown-zone fallback),
  line unfolding per RFC 5545.
- UID-based duplicate detection (current check is title+start).
- Import preview with destination-calendar picker; imported/skipped/failed counts; one transaction.
- Preserve unrecognised properties in raw metadata so export is non-destructive.

### BC-ICS-002 — ICS export completeness
- Spec 1.19. Export one event, one series, a date range, or a whole calendar.
- Emit VALARM for reminders, EXDATE/RECURRENCE-ID for exceptions, correct TZID handling,
  and RFC 5545 line folding at 75 octets.

### BC-ICS-003 — File-based import/export
- Spec 1.18/1.19: open/share `.ics` files rather than paste-only text.

### BC-EVT-020 — Event detail actions
- Spec 1.10: Share as text, Export as ICS, Move to calendar, Open location (Maps), Open URL.
- Show created/last-edited times where useful; recurrence summary; time zone when relevant.

### BC-VIEW-012 — Week/Month drag-and-drop
- Spec 1.7: drag events between days in week view. `WeekCalendarView` currently renders
  each day as a vertical card list (not an hourly timeline) with zero drag gesture code.
  Month view long-press to create already exists.
- Spec 1.6: also add the still-missing haptic feedback at 15/30-minute snap boundaries
  and auto-scroll while dragging near the top/bottom edge for the existing day-view
  drag/resize gestures (`CalendarScreen.swift` overlap-column algorithm and drag/resize
  gestures themselves are already implemented correctly — this item is just the
  haptics/auto-scroll polish called out in spec 1.6).

### BC-TZ-001 — Time-zone settings
- Spec 1.17. The editor currently offers only a flat hardcoded list of ~6 time zones.
- Add: optional secondary time-zone display, time-zone search, and a "lock event to
  this time zone" toggle (view model should support dual-time display even if hidden
  by default per spec).

### BC-PRIV-001 — Privacy logging wrapper
- Spec 0.13: logging wrapper with privacy classifications; never log event title, notes,
  location, or search query. Analytics limited to the allow-listed event names.
- No `print`/`os_log`/`Logger` calls exist anywhere in the app target today, so there
  are no current violations to fix — this is new-build work, not cleanup.

### Resolved during BC-SET-001

- ~~**Quick-create default start time (spec 1.4)**~~ — confirmed and fixed: `EventDraft.init`
  was rounding to the next hour; it now rounds to the next 30-minute mark by default (and
  accepts a `roundingMinutes` parameter so a configured snap interval can override it).
  `testEventDraftRoundsInitialStartToNextHour` was replaced with
  `testEventDraftRoundsInitialStartToNextThirtyMinuteMark`.

---

## Residual risk (out of scope, needs a human)

- Wireframe approval; VoiceOver / Voice Control / Switch Control passes.
- Real lower-end-device performance validation against the 1.21 targets.
- Snapshot/UI test suite; 10,000-event stress fixture.
- Migration-from-every-previous-beta testing (no released betas exist yet).
