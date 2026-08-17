# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Better Calendar is a native SwiftUI iPhone app — an offline-first local calendar (Phase 0/1 of the roadmap in `Instructions/`). There is no backend, no account system, and no external calendar sync yet; everything lives in a local GRDB/SQLite database on-device. See `Instructions/roadmap.md` and `Instructions/phase0_phase1_specification.md` for the full product/technical spec this code implements, and `Instructions/ui_ux_design_document.md` for the screen-by-screen UX spec (screen IDs like `CAL-DAY-01` referenced there correspond to the views under `Better Calendar/Features/`).

Naming is inconsistent across the project and it will trip you up if you assume any one name applies everywhere. The actual values:

| Thing | Name |
| --- | --- |
| Project file | `Better Calendar.xcodeproj` |
| Shared scheme (`-scheme`) | `MyApp` |
| App target / product | `Better Calendar` → `Better Calendar.app` |
| Swift module (`@testable import`) | `Better_Calendar` |
| Test target / bundle (`-only-testing:`) | `MyAppTests` |
| Test sources | `Tests/MyAppTests/` |

So the scheme is `MyApp`, the tests are in `MyAppTests`, but the module they import is `Better_Calendar` — there is no module named `MyApp`.

## Commands

This is an Xcode/SwiftPM project; it must be built and tested with `xcodebuild` on macOS (not available in a Linux dev container).

If `xcodebuild` fails with *"requires Xcode, but active developer directory is a command line tools instance"*, `xcode-select` is pointed at the CLI tools rather than an Xcode install. Either fix it once with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (substitute `Xcode-beta.app` if that is what is installed), or prefix individual commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
# Build
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class or method
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' test \
  -only-testing:MyAppTests/CalendarEngineTests
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' test \
  -only-testing:MyAppTests/CalendarEngineTests/testWeeklyRecurrenceExpandsSelectedWeekdaysWithinRange
```

The simulator destinations only work if a matching iOS runtime is installed — check with `xcrun simctl list runtimes`, which can come back empty on a fresh or beta-only Xcode install. When it does, swap in `-destination 'platform=macOS,arch=arm64'`: the target supports macOS and the whole suite runs there, which is the fastest way to get a green signal without downloading a runtime. Use `-destination 'generic/platform=iOS Simulator'` to typecheck the iOS build without needing a booted device.

There is no lint/format tooling configured in the repo.

## Architecture

The codebase follows a strict one-way layering under `Better Calendar/`: **View → Store → Repository/Scheduler → Domain**. Views never touch SQL or recurrence math directly.

- **`Domain/`** — pure Swift/Foundation, no SwiftUI or persistence imports.
  - `CalendarModels.swift`: the core value types — `CalendarEvent`, `BetterCalendar`, `RecurrenceRule`, `EventReminder`, `ProviderMetadata` (tracks provider/sync-status fields in anticipation of future Google/Apple/U-M sync, per the roadmap's ownership model), `PendingMutation`/`DeletedEventTombstone` (outbox + tombstone scaffolding, currently mostly unused but part of the sync-ready schema), and `EventDraft` (the mutable form-state type used by the editor, converted to/from `CalendarEvent`).
  - `CalendarEngine.swift`: `RecurrenceExpander` turns a `CalendarEvent` + `RecurrenceRule` into concrete `CalendarOccurrence`s for a visible date range (daily/weekly/monthly/yearly, capped at `maximumGeneratedOccurrences`); calendar views never store expanded occurrences, they recompute them per visible range. Also holds time-zone/all-day date helpers (`LocalCalendarDate`, `calendarInOriginalTimeZone`) — timed events store UTC instants + an IANA zone id, all-day events compare on local calendar-date components rather than instants, matching the time-semantics rules in `Instructions/phase0_phase1_specification.md` §0.9.

- **`Data/`** — persistence, notifications, and import/export; the only layer allowed to talk to GRDB/UserNotifications.
  - `LocalCalendarStore.swift`: `BetterCalendarStore`, an `@Observable` class and the single source of truth injected into every screen. All mutations (`saveEvent`, `deleteEvent`, move/duplicate, etc.) go through `withPersistedMutation`, which applies the change in memory, persists via the repository, and rolls back in memory if persistence fails — this is what keeps the UI and the on-disk store consistent. It also owns the `PendingMutation` journal, soft-delete tombstones, notification reconciliation, and the single active `UndoAction` shown by the undo banner. Defines the `LocalCalendarRepository` protocol plus two implementations: `SQLiteCalendarRepository` (GRDB-backed, default/production) and `JSONCalendarRepository` (flat-file, used in `PersistenceTests`).
  - `SQLiteCalendarRepository.swift`: GRDB schema/migrations and queries backing `LocalCalendarRepository`.
  - `LocalNotificationScheduler.swift`: `LocalNotificationScheduling` protocol; `LocalNotificationPlanner` computes the diff between desired and currently-scheduled notifications (reconciliation, not a straight re-schedule) so permission changes/time-zone changes/edits don't leak stale notifications; `UserNotificationScheduler` is the real `UNUserNotificationCenter`-backed implementation, `NoopNotificationScheduler` a no-op for tests/previews.
  - `ICSCalendarCodec.swift`: RFC 5545 ICS import/export, independent of the store.

- **`Features/<Name>/`** — one SwiftUI screen per directory (`Calendar`, `Agenda`, `Calendars`, `Search`, `EventDetails`, `EventEditor`, `ImportExport`), each taking the shared `BetterCalendarStore` and reading/writing through it rather than owning their own state. `Features/Calendar/CalendarScreen.swift` is the largest file — it implements day/week/month rendering, drag-to-move, and resize directly against `RecurrenceExpander` output.

- **`App/`** — `BetterCalendarApp` (entry point) and `AppRootView` (the three-tab shell: Calendar/Agenda/Search, matching `Instructions/ui_ux_design_document.md` §5; also wires system time-zone/significant-time-change notifications to `store.refreshForSystemTimeChange()` and hosts the global undo banner and data-error alert).

- **`Shared/CalendarStyle.swift`** — maps `CalendarColorName` to the concrete SwiftUI `Color` values defined as design tokens in the UI/UX doc (Better Blue, Success, Warning, Destructive, Navy, Gray).

### Key invariants to preserve when editing

- Domain code must stay free of SwiftUI/GRDB imports so it stays independently testable.
- Store mutations must go through `withPersistedMutation` (or an equivalent persist-then-rollback-on-failure pattern) — don't mutate `events`/`calendars` arrays directly from a view or bypass the repository.
- All-day events are compared/stored via local date components, never UTC midnight instants; timed events carry both a UTC instant and the original IANA time zone identifier. Recurrence and date-range tests in `Tests/MyAppTests/RecurrenceRuleTests.swift` and `CalendarEngineTests.swift` encode these rules — check them before changing date/recurrence logic.
- Notification scheduling happens *after* a store mutation commits and goes through reconciliation (`LocalNotificationPlanner`), not ad hoc schedule/cancel calls.
- The app is designed for iPhone, but the target's `SUPPORTED_PLATFORMS` includes `macosx`, so every view must still *compile* for macOS. iOS-only SwiftUI API (`fullScreenCover`, `EditButton`, `.tabViewStyle(.page)`, `.navigationBarTitleDisplayMode`, `.textInputAutocapitalization`, `UIImpactFeedbackGenerator`, anything under `UIKit`) has to sit behind `#if canImport(UIKit)` with a macOS fallback where the behaviour matters. A build that is green on the simulator can still be broken on macOS — see the `onboardingCover` helper in `App/AppRootView.swift` for the pattern.
