# Phase 0 / Phase 1 Completion Backlog

Source of truth for the Phase 1 completion effort. Derived from
`Instructions/phase0_phase1_specification.md`. Every item has a stable requirement
ID per spec 0.3 — use these IDs in commits, tests, and PR descriptions.

## Baseline (verified 2026-08-08)

- 28 tests green via:
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

| ID | Item | Status |
| --- | --- | --- |
| BC-NOT-001 | Multiple reminders per event | In progress |
| BC-EVT-010 | Field limit validation | Not started |
| BC-EVT-011 | Floating event model | Not started |
| BC-SET-001 | Settings persistence layer | Not started |
| BC-SET-002 | Settings screen | Not started |
| BC-VIEW-010 | Persist view state | Not started |
| BC-ONB-001 | First-launch onboarding | Not started |
| Milestone B–D | Recurrence, search, interchange | Not started |

### Known gaps against the spec (deliberate, not defects)

- **Custom reminder durations (spec 1.12)** — the preset list is implemented in full,
  but arbitrary user-entered durations ("Custom": minutes/hours/days/weeks) are not.
  Deferred out of BC-NOT-001; no backlog item currently owns this.
- **Configurable all-day alert time** — hard-coded to 09:00 local in
  `LocalNotificationPlanner.allDayAlertHour`. Becomes user-configurable in BC-SET-001.

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

## Milestone B — Recurrence correctness

### BC-REC-010 — Recurrence exceptions + edit/delete scope
- Spec 0.10, 1.11. **Highest-risk item.** `event_recurrence_exceptions` exists but is never
  read or written; all edits currently hit the whole series.
- Implement "This Event" vs "All Events" for both edit and delete.
- A modified occurrence becomes an exception attached to the master; a deleted occurrence
  becomes a cancelled exception. Expander must skip cancelled and substitute modified.
- Schema must keep room for future "this and future" splitting.
- Acceptance: edit one occurrence leaves siblings untouched; delete one occurrence removes
  only it; both survive a save/load round trip.

### BC-REC-011 — Full recurrence editor
- Spec 1.11. Presets: Never, Daily, Weekly, Every 2 Weeks, Monthly, Yearly, Every Weekday, Custom.
- Custom: frequency, interval, weekday multi-select, day-of-month, monthly positional rule
  ("last Friday"), end Never / after N occurrences / on date.
- Requires extending `RecurrenceRule` with `daysOfMonth` and `setPositions` (columns already
  exist in `event_recurrence_rules`) and teaching `RecurrenceExpander` to honour them.
- Keep the human-readable `summary` accurate for every combination.

---

## Milestone C — Search & agenda

### BC-SRCH-001 — FTS5-backed search
- Spec 1.13. `event_search` (fts5) is populated but never queried; `SearchScreen` does an
  in-memory substring scan.
- Query through SQLite. Ranking: exact title → title prefix → title contains → location →
  notes → calendar name; future before past on ties.
- Index calendar name and URL host in addition to current columns.
- Search terms must never reach logs or analytics (spec 1.13 privacy).

### BC-SRCH-002 — Search filters
- Spec 1.13: date range, calendar, past/future, all-day, recurring.

### BC-VIEW-011 — Agenda view completion
- Spec 1.9: sticky date headers, grouping by date, all-day before timed, empty-day handling,
  past-event de-emphasis, "Today" jump, paginated range loading (drop the fixed 90-day window).

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
- Spec 1.7: drag events between days in week view. Month view long-press to create already exists.

### BC-PRIV-001 — Privacy logging wrapper
- Spec 0.13: logging wrapper with privacy classifications; never log event title, notes,
  location, or search query. Analytics limited to the allow-listed event names.

---

## Residual risk (out of scope, needs a human)

- Wireframe approval; VoiceOver / Voice Control / Switch Control passes.
- Real lower-end-device performance validation against the 1.21 targets.
- Snapshot/UI test suite; 10,000-event stress fixture.
- Migration-from-every-previous-beta testing (no released betas exist yet).
