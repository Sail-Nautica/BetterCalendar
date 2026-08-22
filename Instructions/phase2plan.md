# Phase 2 — Production-Quality Event Engine

## Context

`Instructions/phase2_specification.md` hardens the Phase 1 offline calendar into an event
engine that is safe to attach a provider to. Phase 3 (EventKit) will write through the
same outbox, journal, and tombstone mechanisms, so getting event identity, recurrence
scope, idempotency, and migrations right *now* is cheaper than retrofitting them after a
provider exists. Phase 2 adds no screens — its only user-visible effect is reliability.

**The blocking problem is persistence shape.** `SQLiteCalendarRepository.save(_:)` calls
`replaceDatabase`, which `DELETE`s all eleven tables and re-inserts the entire database on
every mutation (`Better Calendar/Data/SQLiteCalendarRepository.swift:347`). An append-only
change journal cannot live in a database that is wiped on every save, and §2.19's targets
(500 outbox mutations < 2s; 10,000-event calendars) are unreachable when one event move
rewrites 10,000 rows. Everything else in Phase 2 sits on top of fixing that.

### Decisions taken (confirmed with the user)

- **Incremental transactional write path** replaces whole-DB replacement for mutations.
- **"This and future" is engine-API only** — no third button on the `EventDetailsView`
  confirmation dialog. The split logic ships tested but unreachable from the UI until
  Phase 3.
- **CI is added** as a GitHub Actions workflow on `Sail-Nautica/BetterCalendar`.
- **Delivery is one branch/PR per milestone**, each green and self-contained, merged in
  order.

### What already exists (do not rebuild)

- `PendingMutation`, `DeletedEventTombstone`, `RecurrenceException`, `ProviderMetadata`
  in `Domain/CalendarModels.swift` — scaffolding to *extend*, not replace.
- `pending_mutations`, `deleted_objects`, `schema_metadata` tables (migration `v007`).
- Per-entity `insert(calendar:in:)`, `insert(event:in:)`, `insert(reminder:…)`,
  `insert(recurrence:…)`, `insert(exception:…)`, `insert(tombstone:…)`,
  `insertSearchRow(for:…)` in `SQLiteCalendarRepository.swift` — the incremental path
  reuses these as the upsert half.
- `RecurrenceExpander.occurrences(of:in:exceptions:)` and
  `RecurrenceException.matches(occurrenceStart:event:)` — the expander already honours
  EXDATE-equivalent semantics.
- `withPersistedMutation` / `apply(_:)` / `persist()` rollback pattern in
  `LocalCalendarStore.swift:750` — the transaction envelope keeps this shape.
- `CalendarOccurrence.occurrenceKey` (`Domain/CalendarEngine.swift:32`) — already
  `(masterID, originalStart)`; formalise it as a type rather than a string.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 90), so new
  files under `Better Calendar/` and `Tests/MyAppTests/` are picked up with **no
  `project.pbxproj` edits**.

### Layering

New pure planners go in `Better Calendar/Domain/Engine/` (no SwiftUI, no GRDB — the
invariant in CLAUDE.md holds). Anything touching the repository goes in
`Better Calendar/Data/Engine/`. `BetterCalendarStore` stays the single `@Observable`
façade every screen already injects; no `Features/` file changes except Settings
diagnostics.

---

## The central abstraction: `EngineTransaction`

One value type, produced by a pure planner, consumed twice — once against the in-memory
`LocalCalendarDatabase`, once against SQLite in a single GRDB write transaction. This is
what makes §2.13's "tombstone written in the same transaction as the delete" and §2.2's
pipeline literally true rather than incidental.

```
struct EngineTransaction {
    var entityChanges: [EntityChange]        // .upsert/.delete of event|calendar|reminder|recurrence|exception
    var journalEntries: [ChangeJournalEntry] // append-only
    var eventVersions: [EventVersion]
    var outboxRows: [PendingMutation]
    var outboxStatusUpdates: [(id: UUID, status: MutationStatus, nextRetryAt: Date?)]
    var tombstones: [DeletedObjectTombstone]
}
```

- `LocalCalendarDatabase.applying(_ transaction:)` — pure, in `Domain/`, used by the store
  and by `JSONCalendarRepository`/`StubCalendarRepository`.
- `LocalCalendarRepository.apply(_ transaction: EngineTransaction) throws` — new protocol
  method. `SQLiteCalendarRepository` implements it with per-row upsert/delete inside one
  `databaseQueue.write`; the JSON and stub repositories implement it as
  `save(database.applying(transaction))`, so every existing test keeps working unchanged.
- `save(_ database:)` survives **only** for bulk paths: seed, `deleteAllLocalData`,
  `loadSampleData`, `commitImport`, and the flat-file repository.

---

## Milestones

Each milestone is its own branch off `main`, its own PR, and must leave
`xcodebuild … test` green before the next starts.

### M1 — Schema, incremental writes, migration framework
*Covers §2.10 (schema), §2.14 (version columns), §2.17, BC-ENG-008.*

- Migrations `v011`–`v016` in `SQLiteCalendarRepository.makeMigrator()`:
  - `v011` — `change_journal` table (§2.8 fields; `entity_type`, `operation`,
    `field_diff` JSON, `source`, `occurred_at`, `applied_mutation_id`).
  - `v012` — `event_versions` table (§2.9).
  - `v013` — extend `pending_mutations` with `payload`, `idempotency_key` (UNIQUE),
    `status`, `attempt_count`, `last_attempt_at`, `next_retry_at`,
    `change_journal_entry_id`; backfill existing rows to `status='pending'` with fresh keys.
  - `v014` — extend `deleted_objects` with `deleted_by`, `purge_after`; backfill
    `purge_after = deleted_at + 30d` (matches the existing
    `tombstoneRetentionInterval` at `LocalCalendarStore.swift:769`).
  - `v015` — `version_number INTEGER NOT NULL DEFAULT 1` on `events` and `calendars`.
  - `v016` — covering index `(calendar_id, start_instant, end_instant)` on `events` for the
    §2.6 interval query, plus a `migration_checksum` row in `schema_metadata`.
- Add `EngineTransaction` + `EntityChange` (`Domain/Engine/EngineTransaction.swift`) and
  `LocalCalendarDatabase.applying(_:)`.
- Add `apply(_:)` to `LocalCalendarRepository` and all three implementations.
- Reconcile the two schema-version notions: `LocalCalendarDatabase.currentSchemaVersion`
  (still `1`) vs. `migrationIdentifiers.count` written into `schema_metadata`. Make the
  migration count the single reported number; keep `currentSchemaVersion` for the JSON
  repository's own format only, and document the split.
- **Tests** (`MigrationTests.swift`, new): build a fixture database at each released
  identifier with GRDB's `migrator.migrate(queue, upTo: "v0NN_…")`, populate it with
  production-shaped rows, migrate forward, assert zero data loss (BC-ENG-008). Assert a
  deliberately failing migration leaves the database at its pre-migration state.

### M2 — Mutation pipeline: journal, versions, outbox, idempotency, concurrency
*Covers §2.2, §2.8, §2.9, §2.10, §2.11, §2.14.*

- `Domain/Engine/ChangeJournal.swift` — `ChangeJournalEntry`, `JournalSource`
  (`userEdit|undo|importICS|migration|reconciliation|recovery`), `EntityType`, and a
  `fieldDiff(from:to:)` helper producing before/after only for changed fields.
- `Domain/Engine/EventVersion.swift` — snapshot rows; reuse
  `CalendarEvent.encodedSnapshotJSON()` (`CalendarModels.swift:403`), already proven by
  the tombstone path.
- Extend `PendingMutation` with the §2.10 fields; add `MutationStatus`.
- Add `versionNumber: Int` to `CalendarEvent` and `BetterCalendar`, decoded tolerantly in
  the same style as the existing `settings`/`recurrenceExceptions` `decodeIfPresent`
  handling.
- `Data/Engine/EventMutationUseCases.swift` — one entry point per logical user action
  (create, update, delete, move, resize, duplicate, moveToCalendar, restoreTombstone,
  importCommit). Each: mints one `idempotencyKey`, short-circuits if that key is already
  `pending`/`applied`, checks `expectedVersionNumber` and returns `.conflicted` on
  mismatch, and returns exactly one `EngineTransaction` carrying **one** journal entry.
- Rewrite `withPersistedMutation` to take an `EngineTransaction`: apply in memory →
  `repository.apply` → restore the previous in-memory database on failure. The existing
  rollback semantics and `lastError` copy are preserved.
- `BetterCalendarStore` public methods keep their exact signatures — every `Features/`
  call site is untouched. `recordMutation` (`LocalCalendarStore.swift:765`) is deleted;
  outbox rows now come from the use cases.
- **Tests**: same mutation applied twice → one event, one journal entry, one reminder
  (§2.11); stale `versionNumber` update rejected as conflict, loser preserved in
  `EventVersion` (§2.14); every write path produces exactly one journal entry.

### M3 — Mutation processor, retry, tombstones, launch recovery
*Covers §2.12, §2.13, §2.18, BC-ENG-005, BC-ENG-006.*

- `Domain/Engine/RetryPolicy.swift` — pure `nextRetryDate(attemptCount:now:jitter:)`,
  exponential with jitter, 24-hour ceiling then `.failed`. Injectable jitter source so
  tests are deterministic.
- `Data/Engine/MutationProcessor.swift` — an `actor` that drains the outbox off the main
  thread. With no provider it validates, applies the idempotency check, marks `applied`,
  and prunes. Never touches the `@Observable` store from a background context except
  through a `@MainActor` hop.
- Generalise `DeletedEventTombstone` → `DeletedObjectTombstone` with `entityType`,
  `deletedBy`, `purgeAfter` (keep a typealias so existing call sites and the persisted
  snapshot format survive). Resurrection guard: applying a mutation for an entity with a
  live tombstone is a no-op that returns success (BC-ENG-006). Deleting an entity with a
  `pending` outbox row cancels that row rather than orphaning it.
- `Data/Engine/LaunchRecovery.swift` — the §2.18 ten-step sequence, replacing the current
  `BetterCalendarStore.load()` body: checksum verify → migrate → `PRAGMA integrity_check`
  → recover incomplete imports → reconcile outbox (expire stale `inFlight`) → prune
  tombstones → reconcile notifications → refresh time zone → load visible range. Integrity
  failure offers export-then-reset rather than discarding; a `source: .recovery` journal
  entry is always written.
- **Tests**: simulated crash between commit and enqueue → mutation replayed exactly once
  on next launch (BC-ENG-005); backoff schedule; `failed` mutations surface rather than
  vanish.

### M4 — Recurrence edit scope and expansion cache
*Covers §2.3, §2.4, §2.5, BC-ENG-001, BC-ENG-002.*

- `Domain/Engine/OccurrenceKey.swift` — `OccurrenceKey(recurrenceMasterID:originalStart:)`
  as a real type replacing the string `CalendarOccurrence.occurrenceKey`; plus
  `EditScope { thisEventOnly, thisAndFuture, allEvents }`.
- `Domain/Engine/RecurrenceSplitter.swift` — pure planner:
  `plan(scope:master:occurrenceKey:edits:exceptions:) -> EngineTransaction`.
  - `thisEventOnly` — today's replacement-event + `.modified` exception behaviour, moved
    out of `saveEvent(from:)` unchanged in effect.
  - `thisAndFuture` — truncate the original master with `RecurrenceEnd.onDate` immediately
    before the edited occurrence, create a new master (new `internalID`) carrying the
    remaining pattern, copy reminders and calendar assignment, **transfer exceptions after
    the split point and drop those before it**. One transaction; a partially split series
    must never be observable.
  - `allEvents` — update the master; exceptions incompatible with the new rule are
    returned as `flaggedExceptions` for review, never silently dropped.
  - Delete uses the same splitter with the create-new-master step omitted.
- `Data/Engine/OccurrenceCache.swift` — memoise `RecurrenceExpander` output per
  `(masterID, range)`, invalidated for the affected master only. Wire into
  `BetterCalendarStore.visibleOccurrences(in:)` (`LocalCalendarStore.swift:549`), which
  today re-expands every series on every call from three `CalendarScreen` sites and one
  `AgendaScreen` site.
- **No `Features/` changes.** `EditScope` reaches the store as a parameter defaulted to
  today's behaviour, so the two-button dialog keeps working identically.
- **Tests**: full §2.16 recurrence matrix, each asserted against a snapshot of the whole
  series, not a spot check.

### M5 — Conflict detection and free/busy
*Covers §2.6, §2.7, BC-ENG-003, BC-ENG-004.*

- `Domain/Engine/ConflictIndex.swift` — sorted-interval structure over
  `[startInstant, endInstant)` for `availability == .busy` events. Incremental:
  `reindex(movedFrom:to:)` re-evaluates only events intersecting the old and new ranges.
  All-day events conflict only with other all-day events on overlapping local dates —
  compared via `LocalCalendarDate`, never UTC midnights, per the CLAUDE.md invariant.
- `Domain/Engine/FreeBusy.swift` — `FreeBusyQuery(rangeStart:rangeEnd:calendarIDs:includeTentative:)`
  → merged busy intervals, collapsing overlapping *and adjacent* runs; cancelled and
  declined excluded regardless of `includeTentative`.
- Both are internal APIs with no UI. Document them in
  `Documentation/Decisions/` so Phase 11/12 can consume them without reopening the engine.
- **Tests**: hand-computed fixture calendar with overlapping, adjacent, and disjoint
  events; conflict detected immediately after create, move, and resize.

### M6 — Duplicate detection
*Covers §2.15, BC-ENG-007.*

- `Domain/Engine/DuplicateDetector.swift` — `DuplicateCandidate` with a confidence score,
  matching on `(calendarID, normalizedTitle, startInstant, endInstant)` within a tolerance
  window, and on `(recurrenceMasterID, originalStart)` for recurring series. **Never merges
  silently** — it returns candidates.
- Replace the ad-hoc UID/title-and-start check inside
  `BetterCalendarStore.commitImport` (`LocalCalendarStore.swift:696`) with it, keeping the
  existing UID-first precedence. Log every decision to the change journal.
- **Tests**: re-importing the same ICS file creates nothing new and is reported as
  duplicate, including the recurring-master case.

### M7 — Test matrix, performance, CI, diagnostics
*Covers §2.16, §2.19, §2.20, and the remaining exit criteria.*

- New test files alongside the existing XCTest suite:
  `TimeZoneMatrixTests`, `RecurrenceMatrixTests`, `EngineIdempotencyTests`,
  `EnginePerformanceTests`, `CrashRecoveryStressTests`.
- Extend `Tests/MyAppTests/TestFixtures.swift` with a deterministic 10,000-event generator
  and a three-time-zone travel fixture.
- Performance assertions use explicit wall-clock bounds (`XCTAssertLessThan` on a measured
  interval) rather than XCTest baselines, which are machine-specific and unusable in CI.
- **Assumption to flag:** §2.20's 1,000-cycle crash and forced-retry loops run against a
  temp-file SQLite repository. The PR job runs a 50-cycle smoke variant; the full 1,000
  runs behind `BC_STRESS=1` in a nightly job. Running 2,000 full cycles on every PR would
  dominate CI time for no added signal.
- `.github/workflows/ci.yml` — on `pull_request` and `push` to `main`:
  1. fast gate — `xcodebuild test -scheme MyApp -destination 'platform=macOS,arch=arm64'`
  2. platform gate — the same on `platform=iOS Simulator,name=iPhone 16`
  3. nightly `schedule` job with `BC_STRESS=1`
- `Features/Settings/SettingsScreen.swift` — extend the existing `#if DEBUG` Diagnostics
  section (line 112) with outbox depth, failed-mutation count, journal size, and last
  applied migration + checksum. Kept DEBUG-gated to honour "no user-facing change";
  un-gating for TestFlight is a Phase 3 call.
- `Documentation/ProductRequirements/phase2-backlog.md` mapping BC-ENG-001…008 to their
  tests, in the same format as the Phase 1 backlog.

---

## Requirement → test mapping

| ID | Milestone | Verifying test |
| --- | --- | --- |
| BC-ENG-001 | M4 | `RecurrenceMatrixTests.testThisEventOnlyLeavesSeriesUnchanged` |
| BC-ENG-002 | M4 | `RecurrenceMatrixTests.testThisAndFutureSplitsAtCorrectBoundary` |
| BC-ENG-003 | M5 | `ConflictDetectionTests.testOverlappingBusyEventsFlagged` |
| BC-ENG-004 | M5 | `FreeBusyTests.testCancelledAndDeclinedExcluded` |
| BC-ENG-005 | M3 | `CrashRecoveryStressTests.testMutationReplayedExactlyOnceAfterCrash` |
| BC-ENG-006 | M3 | `TombstoneTests.testDeletedEventDoesNotResurrectFromReplayedMutation` |
| BC-ENG-007 | M6 | `DuplicateDetectionTests.testReimportingSameICSCreatesNothing` |
| BC-ENG-008 | M1 | `MigrationTests.testMigrationFromEachReleasedSchemaVersion` |

## Verification

Per milestone, before opening its PR:

```bash
# fast full-suite signal (no iOS runtime needed on this machine)
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp \
  -destination 'platform=macOS,arch=arm64' test

# iOS typecheck
xcodebuild -project "Better Calendar.xcodeproj" -scheme MyApp \
  -destination 'generic/platform=iOS Simulator' build
```

Both must pass. The existing ~116 Phase 1 tests must stay green *unmodified* — any Phase 1
test needing an edit is a signal that Phase 2 leaked into user-visible behaviour, which the
exit criteria forbid.

End-to-end, after M7: launch the macOS build, create and edit a recurring event, force-quit
mid-edit, relaunch, and confirm via the Settings diagnostics rows that the outbox drained
and the journal recorded one entry per action. (macOS is the only runnable target here — no
iOS runtime is installed.)

## Risks

- **M2 is the widest blast radius.** It rewrites the store's mutation plumbing while every
  screen keeps calling the same methods. Mitigation: signatures frozen, Phase 1 tests
  unmodified as the regression net.
- **`versionNumber` on `CalendarEvent`** touches `Codable`, the SQLite mapper, the ICS
  codec, and the tombstone snapshot format. Follow the existing tolerant-decode pattern so
  old snapshots still restore.
- **Migration fixtures are only as good as their data.** Fixtures must carry recurrence
  rules, exceptions, replacement events, multi-reminder events, and floating events — the
  shapes Phase 1 actually shipped — not just plain timed events.
