# Phase 2 Engine Backlog

Source of truth for the Phase 2 event-engine effort. Derived from
`Instructions/phase2_specification.md` and `Instructions/phase2plan.md`. Every item has a
stable `BC-ENG-` requirement ID per spec 2.1 — use these IDs in commits, tests, and PR
descriptions, matching the Phase 0/1 backlog's own convention.

## Baseline (verified 2026-09-02)

- 263 tests green via:
  `xcodebuild test -project "Better Calendar.xcodeproj" -scheme MyApp -destination 'platform=macOS,arch=arm64'`
  (147 tests at the start of Phase 2; M1–M7 added 116 more net of two fixture corrections —
  see the "Fixed along the way" note under M6/M7 below.)
- Sole dependency remains GRDB. No new third-party dependencies were added across Phase 2.
- Unlike Phase 1 (`phase1-completion`, one PR per milestone into `main`), M1–M4 shipped as
  four separate PRs (#8–#11) merged into `main`, then the workflow changed: **M5, M6, and M7
  are staged directly on `phase2-staged`** (no per-milestone PR) per a mid-phase decision —
  see the branch-routing note below. A PR from `phase2-staged` into `main` happens only when
  asked for.

## Ratified scope decisions

- **`.thisAndFuture` recurrence edit scope is engine-API only in Phase 2** (M4). `EditScope`
  reaches `BetterCalendarStore` as a parameter defaulted to today's behavior; there is
  deliberately no third button on `EventDetailsView`'s confirmation dialog until Phase 3 has a
  provider to justify the added complexity.
- **`ConflictIndex` indexes stored event rows, not expanded occurrences** (M5) — for a
  recurring master this is its first occurrence only. See
  `Documentation/Decisions/0002-conflict-and-freebusy-apis.md`. Revisit when Phase 11
  specifies a real conflict-warning screen.
- **`FreeBusy.Query.includeTentative` and attendee-"declined" exclusion are reserved no-ops**
  (M5) — Phase 2 has no attendee or tentative-availability model to exclude by. Same ADR.
  Revisit once Phase 3/4 add one.
- **Duplicate-detection decisions log through the existing privacy-log line, not a new
  `change_journal` operation** (M6). See
  `Documentation/Decisions/0003-duplicate-detector-logging-scope.md` — widening the
  `operation` column's `CHECK` constraint needs a table-rebuild migration that would also have
  to fix up `event_versions`' foreign key (SQLite rewrites FK clauses on `RENAME TO`), real
  schema risk for a feature with no UI consumer in Phase 2.
- **The 1,000-cycle stress loops (spec 2.20) run a 50-cycle PR/push smoke variant; the full
  1,000 runs only in the nightly `BC_STRESS=1` CI job** (M7) — this was `phase2plan.md`'s own
  pre-flagged assumption, not a new deviation.
- **Done bar unchanged from Phase 1:** functional engine code + unit tests in the existing
  XCTest style. No snapshot/UI tests. Real lower-end-device performance validation and a
  from-every-released-beta migration corpus remain out of scope — tracked as residual risk.

---

## Status

| ID | Milestone | Verifying test | Status | Commit |
| --- | --- | --- | --- | --- |
| — | M1 | Schema, incremental writes, migration framework | Done — 147 tests green | `0542561` |
| — | M2 | Mutation pipeline: journal, versions, outbox, idempotency | Done | `b14ac7e` |
| — | M3 | Mutation processor, retry, tombstones, launch recovery | Done | `e3bc438` |
| BC-ENG-001 | M4 | `RecurrenceMatrixTests.testThisEventOnlyLeavesSeriesUnchanged` | Done | `3592456` |
| BC-ENG-002 | M4 | `RecurrenceMatrixTests.testThisAndFutureSplitsAtCorrectBoundaryPreservingTotalOccurrenceCount` | Done — 3 review-fixes: `069cc5a` | `3592456` |
| BC-ENG-003 | M5 | `ConflictDetectionTests.testOverlappingBusyEventsFlagged` | Done — 24 tests | `badd196` |
| BC-ENG-004 | M5 | `FreeBusyTests.testCancelledAndDeclinedExcluded` | Done (same commit) | `badd196` |
| BC-ENG-007 | M6 | `DuplicateDetectionTests.testReimportingSameICSCreatesNothing` | Done — 12 tests | `2ffef11` |
| BC-ENG-005 | M3 (single-cycle) / M7 (stress) | `LaunchRecoveryTests.testBC_ENG_005_...` / `CrashRecoveryStressTests.testZeroDataLossAcrossManySimulatedCrashAndRestartCycles` | Done | `e3bc438` / this PR |
| BC-ENG-006 | M3 | `TombstoneTests` coverage folded into `EventMutationUseCasesTests`/`MutationProcessorTests`' resurrection-guard cases | Done | `e3bc438` |
| BC-ENG-008 | M1 | `MigrationTests.testMigrationFromEachReleasedSchemaVersion` | Done | `0542561` |
| — | M7 | Test matrix, performance, CI, diagnostics (this document) | Done — 263 tests green | (uncommitted at time of writing) |

M2/M3 have no `BC-ENG-` ID of their own — they build the pipeline BC-ENG-005/006 depend on,
per `phase2plan.md`'s own requirement-to-test mapping table, which only names eight IDs total.

---

## M1 — Schema, incremental writes, migration framework

`EngineTransaction`/`EntityChange` (`Domain/Engine/EngineTransaction.swift`) replaced
`SQLiteCalendarRepository.replaceDatabase`'s whole-database rewrite with incremental per-row
upserts inside one GRDB write transaction — the precondition for an append-only change journal
to mean anything (a journal erased by the next save is not a journal). Migrations `v011`–`v017`
add `change_journal`, `event_versions`, extend `pending_mutations`/`deleted_objects`, add
`version_number` columns, and the engine-query covering indexes. `MigrationTests` proves every
released schema version migrates forward with zero data loss (BC-ENG-008).

## M2 — Mutation pipeline

`Data/Engine/EventMutationUseCases.swift`: one entry point per logical user action, each
minting an idempotency key, checking `expectedVersionNumber` for optimistic concurrency (spec
2.14), and returning exactly one `EngineTransaction` carrying one journal entry (spec 2.8/2.11).
`withPersistedMutation` in `BetterCalendarStore` applies in memory, persists, and rolls back
in-memory state on failure.

## M3 — Mutation processor, retry, tombstones, launch recovery

`Domain/Engine/RetryPolicy.swift` (exponential backoff with jitter, 24h ceiling),
`Data/Engine/MutationProcessor.swift` (drains the outbox; with no provider yet it validates,
checks idempotency, marks `applied`), `DeletedObjectTombstone` generalized from
`DeletedEventTombstone` with a resurrection guard (BC-ENG-006), and
`Data/Engine/LaunchRecovery.swift`'s ten-step launch sequence (spec 2.18), replacing
`BetterCalendarStore.load()`'s old body.

## M4 — Recurrence edit scope and occurrence cache

`Domain/Engine/OccurrenceKey.swift` + `RecurrenceSplitter.swift`: a pure planner for
`EditScope { thisEventOnly, thisAndFuture, allEvents }`. `.thisAndFuture` truncates the
original master, creates a new master carrying the remaining pattern, and transfers exceptions
at/after the split point in one transaction. `Data/Engine/OccurrenceCache.swift` memoizes
`RecurrenceExpander` output per `(event id, visible range)` behind
`BetterCalendarStore.visibleOccurrences(in:)`.

Three review findings were fixed post-merge (`069cc5a`), all in the same family — the version
number checked before an edit/delete didn't always match the entity actually being written:
`editSeries(.thisEventOnly)` checked the master's version instead of an existing replacement's
own; `deleteSeries(.thisEventOnly)` ignored the caller's expected version entirely; a
this-and-future split left a transferred replacement's `recurrenceMasterID` pointing at the
truncated old master.

## M5 — Conflict detection and free/busy

`Domain/Engine/ConflictIndex.swift`: a sorted-interval structure over busy events'
`[start, end)`, incremental (`reindex(movedFrom:to:)` touches only the entries a move's old and
new ranges affect), all-day events compared via `LocalCalendarDate` against other all-day
events only. `Domain/Engine/FreeBusy.swift`: `FreeBusy.query` merges busy intervals
(collapsing overlapping *and* adjacent runs) over a date range, expanding recurring series via
`RecurrenceExpander`. `BetterCalendarStore.conflictingEventIDs(for:)`/`.freeBusy(_:)` expose
both as engine-API-only methods, same pattern as M4's `editSeries`/`deleteSeries`. See the
Ratified scope decisions above for the two deliberate scope boundaries.

## M6 — Duplicate detection

`Domain/Engine/DuplicateDetector.swift`: `candidates(for:among:timeTolerance:)` never merges
silently, only returns confidence-scored candidates. A provider UID match takes precedence
over everything else; a per-occurrence replacement matches by `(recurrenceMasterID,
originalStart)`; everything else matches by `(calendarID, normalizedTitle, startInstant,
endInstant)` within a 5-minute tolerance. `BetterCalendarStore.commitImport` now calls it
instead of its old ad-hoc UID/title+start check, keeping the exact same UID-first precedence
and master→replacement skip cascade.

**Fixed along the way:** `testStoreImportCountsDuplicateEventsAsSkippedWithoutSaving`'s
`existingEvent` fixture relied on `TestData.event`'s independent `startDate`/`endDate`
defaults and ended up a zero-duration event that didn't actually share an end time with the
imported one — harmless under the old title+start-only check, exposed once `endInstant`
became part of the match per spec 2.15's literal four-field description. Corrected to give it
an explicit matching `endDate`.

## M7 — Test matrix, performance, CI, diagnostics

- `Tests/MyAppTests/TestFixtures.swift` gained `largeEventSet(count:calendarCount:)` (a
  deterministic 10,000-event production-shaped mix: 70% plain timed, 10% all-day, 20%
  recurring with a scattering of exceptions) and `threeZoneTravelEvents()`.
- `EnginePerformanceTests.swift`: five wall-clock-bound assertions (`XCTAssertLessThan`, per
  spec 2.19's own instruction to avoid XCTest baselines) — conflict recompute <50ms, free/busy
  query <100ms, 500-mutation outbox drain <2s, two-year recurrence expansion <100ms/series,
  10,000-event migration <5s.
- **Real finding, not just a test:** the free/busy query initially measured 416ms against its
  100ms target at 10k events — `RecurrenceExpander` walks a series occurrence-by-occurrence
  from its own start with no way to skip ahead, so every irrelevant recurring series in a large
  calendar got fully expanded regardless of the query range. Fixed with a conservative,
  provably-safe pre-filter local to `FreeBusy.query` (`couldIntersect`/
  `latestPossibleOccurrenceEnd`) rather than touching the shared, heavily-tested
  `RecurrenceExpander` — see the doc comments in `Domain/Engine/FreeBusy.swift`. Five new
  correctness tests guard the filter's edge cases (a bounded series entirely before the range,
  `.onDate`-bounded, never-ending, and the boundary case where a series' last occurrence lands
  right at the range's edge).
- **Real bug found and fixed:** `EventMutationUseCases.importCommit`'s per-event outbox rows
  each got a fresh random idempotency key, so the function's own outer `idempotencyKey`
  parameter — the one its doc comment says "guards the batch as a whole" — was checked on
  entry but never actually stored anywhere, meaning a genuine replay could never be detected.
  `EngineIdempotencyTests.testImportCommitReplayWithTheSameKeyCommitsTheBatchOnlyOnce` caught
  it; fixed by having the first row in the batch carry the outer key verbatim.
- `TimeZoneMatrixTests.swift`: a genuine three-zone travel scenario (not the single hand-picked
  pair `CalendarEngineTests` already covered) and `refreshForSystemTimeChange`'s
  `environmentRevision` bump — the mechanism spec 2.16's device-time-zone-change requirements
  actually depend on, since a stored event's fields never change on a zone change.
- `EngineIdempotencyTests.swift`: a systematic one-test-per-use-case replay matrix (update,
  delete, move, resize, moveToCalendar, duplicate, restoreTombstone, cancelOccurrence,
  restoreOccurrence, importCommit) — previously only `createEvent` and one `RecurrenceSplitter`
  path had a dedicated replay test.
- `CrashRecoveryStressTests.swift`: multi-cycle crash-and-restart and forced-retry loops (spec
  2.20), 50 cycles by default, 1,000 behind `BC_STRESS=1`.
- `.github/workflows/ci.yml`: a fast gate (macOS) and platform gate (iOS Simulator) on every PR
  and push to `main`, plus a nightly `schedule` job with `BC_STRESS=1`. **Unverified
  assumption:** this repo's local development machine only has a beta Xcode installed
  (`MACOSX27.0`/`IPHONEOS27.0` SDKs); the workflow targets GitHub's `macos-15` runner image
  with no explicit Xcode pin. The app target's own real deployment minimums (`iOS 17`/
  `macOS 14`, `SWIFT_VERSION 5.0`) are old enough that a stable Xcode should build it, but this
  has not been verified against an actual GitHub Actions run — worth watching the first real
  CI run closely.
- `Features/Settings/SettingsScreen.swift`'s `#if DEBUG` Diagnostics section gained outbox
  depth, failed-mutation count, journal size, and last-applied-migration identifier + checksum.
  `LocalCalendarRepository` gained `diagnostics() throws -> RepositoryDiagnostics`, reading
  live `change_journal`/`schema_metadata` state (not recomputing what the current build
  expects) — `nil` fields signal "not applicable" for the flat-file/stub repositories rather
  than throwing.

---

## Residual risk (out of scope, needs a human)

- Real lower-end-device performance validation against the spec 2.19 targets — `EnginePerformanceTests`
  proves the targets on the development machine only.
- A migration corpus built from every actually-released beta (none exist yet, same caveat
  Phase 1's backlog carried forward).
- The first real GitHub Actions run of `ci.yml` — see M7's unverified-assumption note above.
- Snapshot/UI test suite — unchanged from Phase 1's own residual risk, still out of scope.
- `ConflictIndex`'s occurrence-level scope gap (Ratified scope decisions, M5) — revisit once
  Phase 11 specifies a real conflict-warning screen.
