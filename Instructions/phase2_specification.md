# Better Calendar: Detailed Phase 2 Specification

The purpose of this phase is to turn the offline event model built in Phase 1 into a **production-quality event engine** before any external provider — Apple Calendar, Google Calendar, or U-M — is allowed to touch it.

* **Phase 0** defined product scope and the initial local data model.
* **Phase 1** produced a complete offline iPhone calendar.
* **Phase 2** does not add new user-facing screens. It makes the event engine correct, durable, and safe to synchronize — so that Phase 3 (EventKit) and Phase 4 (Better Calendar cloud) can be built without redesigning event identity, recurrence, reminders, or time-zone handling.

Do not begin Phase 3 until every exit criterion in this document is met. Sync bugs are far more expensive to fix after a provider is attached than before.

---

# Phase 2 — Production-Quality Event Engine

## Phase 2 objective

At the end of Phase 2, the team should have:

* A recurrence-editing model that correctly distinguishes "this event," "this and future events," and "the entire series"
* Conflict detection and free/busy calculation available to any future screen or automation
* A durable, replayable local change journal
* An outbox pattern so no screen ever talks to a provider directly
* Idempotent, retryable save operations
* Deleted-object tombstones and optimistic concurrency
* Duplicate-event detection
* A recurrence and time-zone test suite that runs in CI
* Database migration and recovery tooling proven against every prior schema version

There does not need to be a Google or Apple account connected yet. Phase 2 should be fully exercised using only local Better Calendar events, including synthetic ones generated for testing.

---

## 2.0 Phase 2 boundaries

### Included

* Recurrence edit-scope model (this / future / all)
* Conflict detection between local events
* Free/busy computation over a date range
* Event version history
* Local change journal
* Outbox for offline and pending edits
* Idempotent save/update/delete operations
* Deleted-event tombstones
* Optimistic concurrency (version or ETag comparison)
* Automatic retry with backoff for failed local operations
* Duplicate-event detection heuristics
* Time-zone conversion test suite
* Recurrence test suite
* Database migration framework and crash recovery
* Internal diagnostics surfaces already scaffolded in Phase 1 Settings (schema version, journal depth, outbox depth)

### Explicitly excluded

* Any provider adapter (Apple, Google, U-M)
* Any network synchronization
* Better Calendar accounts or authentication
* Push notifications from a server
* Attendees, invitations, or sharing
* Conflict *resolution* across two providers (Phase 2 only detects conflicts within the local calendar; cross-provider conflict resolution is a Phase 3/4 concern)
* AI scheduling or suggestions

The outbox, journal, and tombstone tables introduced here must be **provider-agnostic**. They should not assume a specific remote system, because the same mechanism will later carry EventKit and Google mutations.

---

## 2.1 Establish Phase 2 requirement identifiers

Continue the identifier scheme established in Phase 0, using a new `ENG` (engine) prefix.

```text
BC-ENG-001: User's edit to a single recurring occurrence does not alter the series.
BC-ENG-002: User's edit to "this and future" splits the recurrence at the correct boundary.
BC-ENG-003: Two overlapping local events are flagged as a conflict in Day and Week view data.
BC-ENG-004: Free/busy query over a date range excludes cancelled and declined events.
BC-ENG-005: Every mutating operation is retried automatically after a simulated crash.
BC-ENG-006: A deleted event does not reappear after a delayed duplicate mutation is replayed.
BC-ENG-007: Importing the same ICS file twice does not create duplicate events.
BC-ENG-008: Database migration from any released Phase 1 schema succeeds without data loss.
```

Use these identifiers in engine unit tests, pull requests, and the Phase 2 QA checklist, exactly as Phase 0/1 identifiers were used for product requirements.

### Engine-level success criteria

* No mutation can be lost due to an app crash between database commit and provider sync (there is no provider yet, but the outbox must already behave as if there were one).
* No mutation can be applied twice due to retry.
* Recurrence-scope edits never silently affect the wrong set of occurrences.
* A conflict between two local events is always detectable from stored data alone, without recomputing the full calendar.
* Every schema migration is reversible in a recovery build or has a documented, tested forward-only path.

---

## 2.2 Architecture: the mutation pipeline

Phase 1 already established that screens write to the local database rather than to a remote system. Phase 2 formalizes that pipeline so it is ready to carry real provider traffic in Phase 3.

```text
User edit
   ↓
Local database transaction (event + recurrence + reminders + search index)
   ↓
Change journal entry (append-only, for version history and debugging)
   ↓
Pending mutation / outbox row (status: pending)
   ↓
Mutation processor (runs even with no provider configured)
   ↓
Success → mark mutation applied, prune outbox row
Retryable failure → backoff and retry
Conflict → hold for resolution, surface in diagnostics
```

In Phase 2, the "mutation processor" has nothing to synchronize to remotely, so it simply validates, applies idempotency checks, and marks mutations as locally applied. This proves the pipeline works before Phase 3 adds a real provider on the other end.

### Rules

* A SwiftUI view or view model must never call a repository's "save" method directly for anything that will eventually be synchronized — it calls a use case, which writes the transaction and enqueues the mutation.
* The outbox is the single choke point through which all provider-bound changes flow. This rule from the roadmap architecture is treated as non-negotiable starting in Phase 2.
* Journal entries are append-only and are never edited after being written; corrections are made by writing a new entry.

---

# Phase 2A — Recurrence editing model

## 2.3 Occurrence identity

Formalize what Phase 1 sketched:

```text
OccurrenceKey
- recurrenceMasterID: UUID
- originalStart: Date   // identifies the occurrence within the series
```

* Calendar views continue to display expanded occurrences, never raw masters (per Phase 1 IA rules).
* An occurrence is addressed by `(recurrenceMasterID, originalStart)`, not by a derived integer index, because insertion or deletion of exceptions must not shift the identity of unrelated occurrences.

## 2.4 Edit-scope resolution

```text
EditScope
- thisEventOnly
- thisAndFuture
- allEvents
```

| Scope | Storage behavior |
|---|---|
| This event only | Create or update a `RecurrenceException` row tied to the `(masterID, originalStart)` pair. The master's `RRULE` is untouched. |
| This and future | Split the series: truncate the original master's recurrence with an `UNTIL` immediately before the edited occurrence, and create a new master beginning at the edited occurrence carrying the new field values and the remaining recurrence pattern. |
| All events | Update the master directly. Existing per-occurrence exceptions that are no longer compatible (e.g., an exception for a weekday the new rule no longer includes) must be flagged for review rather than silently discarded. |

### Split-series requirements

* The new master receives a new `internalID`; the `recurrenceMasterID` referenced by future occurrences changes accordingly.
* Reminders and calendar assignment are copied to the new master unless explicitly changed as part of the same edit.
* Deleting "this and future" from an occurrence uses the same split logic, replacing the create-new-master step with simply not creating one.
* Every split operation is a single transaction; a partially split series must never be visible.

## 2.5 Recurrence rule engine correctness

* Support `RRULE` frequencies: daily, weekly, monthly (by day-of-month and by weekday-ordinal), yearly.
* Support `EXDATE` and `RECURRENCE-ID` semantics consistent with RFC 5545, since ICS import/export from Phase 1 depends on this.
* Expand recurrence lazily and only for the visible date range plus a small prefetch window; never materialize an unbounded series.
* Cache expansion results per visible range and invalidate the cache precisely — only for the affected master — when any occurrence in that series changes.

---

# Phase 2B — Conflict detection and free/busy

## 2.6 Conflict detection

* Two events conflict when their `[startInstant, endInstant)` intervals overlap and both have `availability == busy`.
* All-day events participate in conflict detection against other all-day events on the overlapping local dates, but do not by default conflict with timed events (configurable later; document the default explicitly in UI copy).
* Conflict computation must be incremental: inserting, moving, or resizing one event should only re-evaluate events that intersect its new and previous time ranges, not the entire calendar.
* Store a lightweight conflict index (e.g., an interval tree or sorted-range query against the existing date-range index) rather than performing a full table scan per edit.

## 2.7 Free/busy calculation

```text
FreeBusyQuery
- rangeStart: Date
- rangeEnd: Date
- calendarIDs: [UUID]?   // nil = all visible calendars
- includeTentative: Bool
```

* Returns a merged list of busy intervals, collapsing overlapping and adjacent events from the requested calendars.
* Cancelled and declined events are excluded regardless of `includeTentative`.
* This API has no UI in Phase 2 — it exists so Phase 11 (scheduling pages) and Phase 12 (intelligence) can be built without touching the event engine again.

---

# Phase 2C — Version history and change journal

## 2.8 Change journal

```text
ChangeJournalEntry
- id: UUID
- entityType: event | recurrenceRule | reminder | calendar
- entityID: UUID
- operation: create | update | delete
- fieldDiff: JSON            // before/after for changed fields only
- source: userEdit | undo | importICS | migration | reconciliation
- occurredAt: Date
- appliedMutationID: UUID?   // links to the outbox row that carried it, once applied
```

* Append-only; never mutated or deleted except by an explicit, logged retention policy.
* Every write path identified in 0.15 (Phase 0 test infrastructure) must produce exactly one journal entry per logical user action, even when it spans multiple table writes.
* The journal is the source of truth for Undo (extending the Phase 1 undo banner) and for future "event history" UI in Phase 11.

## 2.9 Event version history

```text
EventVersion
- id: UUID
- eventID: UUID
- versionNumber: Int
- snapshot: JSON       // full event state at this version
- createdAt: Date
- changeJournalEntryID: UUID
```

* A new version row is written on every committed update, not only on provider sync — this must work identically whether or not a provider is ever connected.
* Version pruning (e.g., keep the last N versions locally) is acceptable, but the *current* version and the *most recent version before the last provider sync* must always be retained once Phase 3 exists.

---

# Phase 2D — Outbox and idempotent operations

## 2.10 Outbox schema

Extend the `pending_mutations` table introduced in Phase 0:

```text
PendingMutation
- id: UUID
- entityType: event | recurrenceRule | reminder | calendar
- entityID: UUID
- operationType: create | update | delete
- payload: JSON
- idempotencyKey: UUID        // stable across retries of the same logical mutation
- status: pending | inFlight | applied | failed | conflicted
- attemptCount: Int
- lastAttemptAt: Date?
- nextRetryAt: Date?
- createdAt: Date
- changeJournalEntryID: UUID
```

* `idempotencyKey` is generated once when the mutation is first enqueued and never regenerated on retry, so a future provider adapter can safely resend the same request without creating a duplicate.
* Applying a mutation whose `idempotencyKey` has already been marked `applied` must be a no-op that still returns success — this is what makes the pipeline safe for provider outages simulated later in Phase 3.

## 2.11 Idempotent save operations

* Every use case that writes an event (create, update, delete, move, resize, duplicate, recurrence split) must be safe to invoke twice with the same input and produce the same end state.
* Implement idempotency by checking the outbox for an existing `pending` or `applied` mutation with the same `idempotencyKey` before writing.
* Duplicate invocation must not create two events, schedule two reminders, or write two journal entries.

## 2.12 Retry policy

* Exponential backoff with jitter, bounded by a maximum retry window (e.g., 24 hours) after which the mutation moves to `failed` and surfaces in diagnostics rather than retrying forever silently.
* Retries must not run on the main thread and must not block calendar rendering.
* A `failed` mutation must never be dropped without user-visible or diagnostic-visible notice — silent data loss is the one failure mode Phase 2 exists to eliminate.

---

# Phase 2E — Tombstones and optimistic concurrency

## 2.13 Deleted-object tombstones

```text
DeletedObjectTombstone
- id: UUID
- entityType: event | recurrenceRule | reminder | calendar
- entityID: UUID
- deletedAt: Date
- deletedBy: userEdit | recurrenceSplit | calendarDeletion | reset
- purgeAfter: Date
```

* A tombstone is written in the same transaction as the delete, never afterward.
* Tombstones prevent a delayed or replayed mutation (e.g., an old outbox retry, or later a delayed provider push) from resurrecting a deleted object.
* Tombstones are purged only after `purgeAfter`, which must be long enough to outlast plausible retry and reconciliation windows established in 2.12.

## 2.14 Optimistic concurrency

* Every mutable entity carries a local `versionNumber` (independent from the provider `providerVersion`/ETag field reserved in Phase 0).
* An update mutation must include the `versionNumber` it was based on; if the current stored version does not match, the write is rejected as a conflict rather than silently overwritten.
* Local-only conflicts (e.g., an Undo racing a new edit) are resolved with a clear, deterministic rule: the most recent user-initiated write wins, and the loser is preserved in `EventVersion` history rather than discarded.

---

# Phase 2F — Duplicate-event detection

## 2.15 Duplicate heuristics

Used both for ICS re-import (already required in Phase 1) and as a general safety net:

* Match candidates by `(calendarID, normalizedTitle, startInstant, endInstant)` within a small tolerance window.
* For recurring events, compare `(recurrenceMasterID` equivalent fields`, originalStart)` rather than per-occurrence fields.
* Provide a `DuplicateCandidate` result with a confidence score, never an automatic silent merge — the user or a later provider-sync policy decides whether to merge, keep both, or replace.
* Log duplicate-detection decisions to the change journal for auditability.

---

# Phase 2G — Time-zone and recurrence test suite

## 2.16 Required automated coverage

This suite must run in CI on every pull request, not only before release.

**Time zone**

* Timed event displays correctly after a device time-zone change.
* All-day event date does not shift after a device time-zone change.
* Event created near a DST transition retains the intended local time on both sides of the transition.
* Dual-time display computes correctly for a travel scenario spanning three time zones.

**Recurrence**

* Daily, weekly, monthly (by date and by weekday-ordinal), and yearly rules expand correctly across a two-year window.
* Recurrence crossing a DST boundary preserves the intended local time, not the UTC offset.
* February 29 yearly recurrence behaves correctly in non-leap years.
* Monthly recurrence anchored on the 29th, 30th, or 31st behaves correctly in short months.
* `EXDATE` correctly removes a single occurrence without affecting others.
* "This and future" split correctly transfers exceptions that occur after the split point and correctly drops the ones before it.
* Editing "all events" after prior per-occurrence exceptions exist flags incompatible exceptions instead of discarding them silently.

**Engine**

* Idempotent replay of the same mutation twice produces one resulting change.
* A simulated crash between transaction commit and outbox enqueue does not lose the mutation on next launch.
* A conflicted mutation (version mismatch) surfaces rather than overwriting.
* Deleting an event with a `pending` outbox mutation cancels the pending mutation rather than leaving it orphaned.

---

# Phase 2H — Migrations and recovery

## 2.17 Migration framework

* Every schema change ships as a numbered, forward-only migration with an automated test that runs it against a fixture database from each previously released schema version.
* Migrations run inside a transaction; a failed migration must leave the database in its pre-migration state, not a partially migrated one.
* `schema_metadata` (introduced in Phase 0) records the applied migration number and a checksum of the migration set, so a corrupted or partial migration can be detected on next launch.

## 2.18 Crash and corruption recovery

Extend the Phase 1 launch sequence (1.23):

```text
1. Open the database.
2. Verify schema_metadata checksum; halt into recovery mode if mismatched.
3. Run pending migrations transactionally.
4. Run SQLite integrity check.
5. Recover incomplete import operations.
6. Reconcile the outbox: resume pending mutations, expire stale in-flight ones.
7. Prune expired tombstones and undo records.
8. Reconcile local notifications against current reminder state.
9. Refresh current date/time zone.
10. Load only the initial visible date range.
```

* If integrity check fails, the app must offer export-then-reset rather than silently discarding data.
* A recovery event must always be written to the change journal with `source: migration` or a new `source: recovery` value, so support and diagnostics can see it happened.

---

# Phase 2I — Performance and reliability targets

## 2.19 Engine performance targets

* Conflict recomputation after a single event move: under 50 milliseconds for a calendar with 10,000 events.
* Free/busy query over a one-week range: under 100 milliseconds.
* Outbox drain of 500 queued mutations (simulated, no real provider): under 2 seconds.
* Recurrence expansion for a two-year visible window: under 100 milliseconds per series.
* Migration of a 10,000-event database from the earliest supported schema: under 5 seconds.

## 2.20 Reliability targets

* Zero data loss across 1,000 simulated crash-and-restart cycles during active editing, in automated testing.
* Zero duplicate application of any mutation across 1,000 simulated forced-retry cycles.
* Zero incorrect recurrence-scope edits across the full recurrence test matrix in 2.16.

---

# Phase 2J — Quality and release criteria

## Required test scenarios

Before Phase 2 is complete, verify, in addition to the Phase 1 scenario list:

* This-event, this-and-future, and all-events edits each produce the correct resulting set of occurrences, verified against a snapshot of the full series.
* A conflict between two events is detected immediately after either event is created, moved, or resized.
* Free/busy output matches hand-computed expectations for a fixture calendar with overlapping, adjacent, and disjoint events.
* A mutation retried after a simulated crash is applied exactly once.
* A deleted event does not reappear after its tombstone's mutation is replayed.
* Re-importing the same ICS file is detected as a duplicate and does not create new events.
* Every schema migration path from a prior Phase 1 TestFlight build succeeds against production-shaped fixture data.
* Undo continues to work correctly when built on top of the change journal and version history introduced in this phase.

## Phase 2 exit criteria

Phase 2 is complete when:

* All Phase 1 functionality continues to work unchanged from the user's perspective — Phase 2 must be invisible to end users except through improved reliability.
* Every screen-originated mutation flows through the outbox pipeline; no code path writes to a "remote" concept directly (there is still no remote, but the pipeline behaves as though there will be one).
* Recurrence edit-scope behavior passes the full test matrix in 2.16.
* Conflict detection and free/busy queries are available as internal APIs, documented for use by later phases.
* No known bug can cause silent event loss, duplication, or a mutation applied more than once.
* Database migrations are proven against every previously released schema version.
* CI runs the full time-zone, recurrence, and engine test suite on every pull request.
* The diagnostics surface in Settings (from Phase 1) reports outbox depth, journal size, and last migration version, for use in later beta and support work.

Once this foundation is stable, Phase 3 can connect Apple Calendar through EventKit by writing a provider adapter that reads from and writes to the same outbox, journal, and tombstone mechanisms — without forcing any change to event identity, recurrence, reminders, or time-zone handling.
