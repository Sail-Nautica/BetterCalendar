# Better Calendar: Detailed Phase 3D Specification

Phase 3D is **writing local changes back out to EventKit** — sections 3.18 through 3.22 of
`Instructions/phase3_specification.md`. It is the phase in which Better Calendar stops being a
reader of the user's calendar and becomes a writer of it.

* **Phase 3A** built the permission model. **Phase 3B** discovered the device's calendars.
  **Phase 3C** filled them with events and proved the mirror can be rebuilt from nothing.
* **Phase 3D** (this document) attaches the far end of the outbox Phase 2 built and ran empty.
* **Phase 3E** observes external change and resolves the conflicts this phase makes possible.

Every phase so far has had one property that made it safe: nothing this app did could disagree
with the device. 3D removes that property deliberately. From here, a bug in Better Calendar can
destroy an event that exists on the user's phone, their laptop, and their employer's Exchange
server. Every rule below follows from that.

---

## 3D.0 Scope

### Included

* The **defect fix that has to land first** — see 3D.1. Today a local edit to a device calendar
  is marked synced without ever reaching EventKit.
* The mutation adapter behind `MutationProcessor`'s existing `validate` seam, and the three-phase
  plan/perform/commit shape that lets provider I/O happen without making `decide` impure or launch
  asynchronous
* Create, with the crash-idempotency search spec 3.19 requires
* Update as a **field-level patch** against a freshly fetched event — the half that makes 3C's
  preserved payload actually survive, closing BC-EK-017
* Delete, its span, and the tombstone that stops a late reconciliation resurrecting it
* Recurrence-scope writes: Better Calendar's three scopes onto EventKit's two spans, and the
  `.thisAndFuture` button Phase 2 deferred until "a provider justifies the complexity"
* The four-class failure taxonomy, and the rule that a permission failure does not burn retries
* Optimistic concurrency against the device's last-modified value, with a field-level diff before
  a mismatch is called a conflict
* `SRC-STAT-01`: pending, failed, parked and conflicted mutations, made findable rather than
  transient
* Migration `v021` for the outbox columns this phase needs

### Excluded

* **Conflict *resolution*.** 3D *detects* a concurrent external change and parks the mutation as
  `.conflicted`; deciding what to do about it — the merge rules, the "ask the user" cases, the
  resolution surface — is Phase 3E (spec 3.25). Shipping detection without resolution is
  deliberate and is the safe half: a parked mutation loses nothing.
* Change observation and coalescing (`EKEventStoreChanged`) — Phase 3E. 3D re-mirrors after its
  own writes, on its own trigger, which is a narrower thing.
* The duplicate-connection rule and cross-provider duplicate detection — Phase 3F
* Reminders — Phase 3G

### Requirement coverage

| ID | Statement | 3D delivers |
|---|---|---|
| BC-EK-007 | An event created in Better Calendar on a device calendar appears in Apple Calendar | Fully |
| BC-EK-008 | Editing a mirrored event writes the change back to EventKit | Fully |
| BC-EK-009 | Deleting a mirrored event removes it from EventKit and does not resurrect it | Fully |
| BC-EK-010 | A read-only calendar rejects edits at the model layer, not only in the UI | Completed: the model-layer gate has existed since the prerequisites, and this is the first phase where a write could otherwise have reached the device |
| BC-EK-014 | A "this event only" edit detaches exactly one occurrence | Fully |
| BC-EK-015 | A "this and future" edit splits the series the way EventKit splits it | Fully |
| BC-EK-017 | Provider fields we do not model survive a local edit round trip | Completed. 3C preserved the payload; the field-level patch is what stops a title-only edit stripping it |
| BC-EK-011 | An event edited externally between two launches is reconciled without losing local edits | The *detection* half. Resolution is 3E |

---

## 3D.1 The defect this phase must fix before it adds anything

Phase 3B made a writable device calendar selectable as a destination, and Phase 3C mirrored real
events onto it. Neither phase attached a writer. So today:

1. The user creates an event on their iCloud calendar in Better Calendar.
2. `EventMutationUseCases.createEvent` writes the row and enqueues a `pending` outbox mutation.
3. On the next launch, `LaunchRecovery` calls `MutationProcessor.reconcile` with the **default**
   `validate`, which returns `.valid` unconditionally.
4. The row is marked `.applied`.

The event now exists in Better Calendar, does not exist on the device, and the outbox says it
synced. That is silent data loss of exactly the kind spec 2.12 says this pipeline exists to
eliminate, and it is reachable in the shipped code today.

**The first milestone of this phase is the fix, and it lands before the adapter exists.**
`MutationProcessor.decide` gains one rule: a mutation whose target lives on a calendar with
`connectionMethod == .device` is **not this pass's to retire**. Without a provider result it
returns a new `.deferred` decision — the row stays `pending`, untouched, and waits for the
adapter.

That ordering is the same one Phase 2 used for the outbox and Phase 3B used for discovery: build
the mechanism that *refuses to do the wrong thing* first, attach the machinery afterwards. It also
means that if the rest of this phase slipped, the app would be conservative rather than wrong.

---

## 3D.2 Architecture: three phases, one seam

`MutationProcessor.decide` is pure and synchronous, and that property is load-bearing:
`LaunchRecovery` calls `reconcile` inline, and spec 2.18 forbids launch becoming asynchronous
because the first frame would render with no data. EventKit I/O cannot happen inside it.

Spec 3.18 says to supply a real implementation *behind* the existing `validate` seam rather than
rewriting the processor. Concretely, that is three phases:

```text
1. PLAN     (pure, sync)   Which due outbox rows target a device calendar, and what
                           device operation does each one imply?
                           → `DeviceWritePlanner.plan(...) -> [DeviceWrite]`

2. PERFORM  (async, off-main)  Issue each write against `EventKitStore`. Fetch first,
                               patch, save with the right span. Collect a receipt or a
                               classified failure.
                               → `DeviceMutationAdapter.perform(...) -> [DeviceWriteResult]`

3. COMMIT   (pure, sync)   Feed the results back through `decide` via `validate`, which
                           now just looks each row's result up. One `EngineTransaction`
                           carries the outbox status changes *and* the receipt written
                           onto the mirror row.
```

The `validate` closure stays exactly the shape Phase 2 gave it. It becomes a lookup into an
already-computed dictionary rather than a source of truth, which is why `decide` stays pure and
`LaunchRecovery` stays synchronous.

**Correction (as built).** Phases 1–3 are driven from `BetterCalendarStore.drainDeviceWrites`, not
from `MutationProcessorActor`. The actor loads and writes through the repository directly, behind
the store's back, so a receipt written that way leaves `events` stale and the user keeps seeing an
event marked pending after it synced. The property the actor exists to protect — that launch is not
blocked on EventKit — is supplied by the seam itself being `async` and by nothing calling the drain
from `load()`. `MutationProcessor.decide` stays pure and synchronous, which is the constraint that
actually mattered. See ADR 0009, Decision 1.

### The receipt

A create returns the device's new identifier and last-modified value. Those are written onto the
mirror row **in the same transaction that marks the mutation applied** — never in a follow-up
write, because a crash between the two is exactly the state that produces a duplicate on the next
attempt.

---

## 3D.3 Create

* Save to the target device calendar; persist the returned `eventIdentifier`,
  `calendarItemExternalIdentifier` and `lastModified` onto the local row.
* Until the receipt lands the row's `syncStatus` is `pendingCreate` — a value the schema has
  carried since Phase 0 and that finally means something.
* The local row's id does **not** change. Phase 3C derives mirrored ids from provider identity,
  but a Better Calendar-created event already has a local id that views, undo actions and the
  conflict index all reference. Re-keying it on receipt would invalidate every one of them. The
  row is therefore matched by `providerObjectID` from then on, and `DeviceEventMirror` must treat
  a row it did not name as its own — see 3D.9.

### Idempotency across a crash

A create that succeeded in EventKit but crashed before the receipt was persisted must not create a
second device event on retry. Before re-issuing a create, the adapter:

1. Fetches the target calendar over a narrow window around the event's own start.
2. Runs the outbox row's payload through `DuplicateDetector` against what came back.
3. Adopts a **high-confidence** match as the receipt instead of creating again.

This is the concrete provider-side realisation of spec 2.11, and it is the single most valuable
test in this phase: 1,000 simulated create-crash-retry cycles must produce zero duplicate device
events (spec 3J).

Only a create needs the search. An update or delete already knows the device identifier it is
addressing.

---

## 3D.4 Update, as a patch and not a save

Spec 3.17's other half. A whole-object save writes back every field of *our* model of the event,
which means every field we do not model is written back as absent. That is how a title-only edit
strips the Google Meet link off a meeting.

So an update is:

1. **Fetch** the device event fresh by identifier.
2. **Check** its last-modified against the value the local edit was based on (3D.6).
3. **Patch** only the fields that actually changed — and the source of "what changed" is not a
   diff computed at write time against a possibly-stale local copy. It is the **change journal's
   `FieldDiff`**, which the outbox row already points at through `changeJournalEntryID`. The
   journal has recorded exactly this since Phase 2 §2.8; this is the first consumer that needs it.
   A mutation with no journal entry, or an entry with no diff, falls back to writing every
   modelled field — the pre-journal shape, still correct, just less surgical.
4. **Save** with the correct span (3D.5).

Fields Better Calendar does not model are never written. They are not ours to write, and the
freshly fetched `EKEvent` still carries them.

### Alarms

A mirrored event's alarms are display state in 3C. From 3D an edit to them is written back as an
alarm change on the device event — not taken over by `LocalNotificationPlanner`, which continues
to schedule nothing for a `.device` calendar. The exclusion is unchanged; the write-back is new.

---

## 3D.5 Recurrence-scope writes

Phase 2 defined three edit scopes. EventKit offers **two** spans, and there is no "all events"
span. The mapping is the thing most likely to be got wrong in this phase, so it is stated as a
table and tested as a matrix.

| Better Calendar scope | Device write |
|---|---|
| `thisEventOnly` | Save with the this-event span. EventKit detaches the occurrence; mirror the detachment into the `RecurrenceException` + replacement-event model 3C already builds (BC-EK-014). |
| `thisAndFuture` | Save with the future-events span, from the target occurrence. **EventKit performs its own split**, which need not match `RecurrenceSplitter`'s. Issue one future-span write and **re-mirror the resulting series from the device** (BC-EK-015). |
| `allEvents` | Address the **series master** and save with the this-event span *on the master* — which is how EventKit expresses a whole-series change. |

Two rules that are easy to state and easy to violate:

* **Do not split locally and then also split remotely.** For `.thisAndFuture`, the local
  projection `RecurrenceSplitter` produces is a *prediction*. Issue the device write, then
  re-mirror the affected series and let the device's answer win.
* **After any scope write to a mirrored series, re-mirror that series** rather than trusting the
  local projection. The device is the authority; we are reconciling to it, not asserting over it.

### The third button

Phase 2's backlog notes `.thisAndFuture` is engine-API only, with no third option in
`EventDetailsView`'s confirmation dialog, deliberately deferred until "Phase 3 has a provider to
justify the added complexity." **That condition is now met.** Phase 3D ships the third option, for
local *and* mirrored series — the engine has supported it since Phase 2 M4 and only the UI was
withheld.

---

## 3D.6 Failure taxonomy

`RetryPolicy` is reused unchanged. Phase 2 had one failure class; Phase 3 has four, and they must
not be collapsed.

| Class | Examples | Handling |
|---|---|---|
| **Transient** | Store busy, account temporarily unavailable | Retry on the existing backoff. `attemptCount` increments. |
| **Permission** | Access revoked, write-only, calendar became read-only | **Park.** Status `.parked`, `attemptCount` untouched, no `nextRetryAt`. Resumed when access returns. |
| **Permanent** | Calendar deleted, event gone, data the provider rejected | `.failed`. Journalled, surfaced in `SRC-STAT-01`, never silently dropped. |
| **Conflict** | The device event changed underneath us | `.conflicted`. Routed to Phase 3E, never to retry. |

`MutationStatus` gains `.parked`. `pending_mutations.status` carries no `CHECK` constraint (it
arrived by `ALTER TABLE` in `v013`), so this is additive — no table rebuild, and ADR 0003's
deferred rebuild concerns `operation` and stays deferred.

**A permission failure must not consume a retry attempt.** A user who denies access for a week and
re-grants it should find their queued edits waiting, not a queue of mutations that exhausted their
24-hour window while nothing was being attempted. This is why parking is a distinct status rather
than "a retryable failure with a long delay".

A parked mutation is un-parked — back to `.pending` — when calendar authorization returns to full
access, which is a signal `refreshDeviceCalendarAccess` already computes on every foreground.

---

## 3D.7 Optimistic concurrency against the device

Phase 2 §2.14 gives every entity a local `versionNumber`. This adds the provider's side.

* An update mutation records the device event's last-modified value **it was based on**, in a new
  `pending_mutations.base_provider_version` column.
* Before writing, the adapter re-fetches and compares.
* A mismatch is a **signal, not a verdict.** Last-modified granularity is coarse — whole seconds
  on some sources — so the adapter confirms with a field-level diff: if the fields the device
  changed and the fields this mutation changes are **disjoint**, it is a merge, and the patch
  proceeds. Two writes in the same second that touched different fields are not a conflict.
* An overlapping change is a real conflict: the row moves to `.conflicted` and stops. The local
  edit is not lost — it is in the outbox payload, in the journal's `FieldDiff`, and in
  `EventVersion` history — and Phase 3E decides what happens to it.

Spec 3.25's merge and "ask the user" policy is 3E's. 3D's job is to be sure that nothing is
overwritten and nothing is thrown away while it waits.

---

## 3D.8 Surfaces

| Screen | ID | This phase |
|---|---|---|
| Sync status | `SRC-STAT-01` | **New.** Outbox depth by status: pending, parked, failed, conflicted. Last write-back attempt and its result, as counts. A failed or conflicted mutation names its event and offers "try again"; a parked one says what is blocking it and links to Settings. |
| Full Event Editor | `EVT-EDIT-01` | Unchanged. A mirrored event that cannot be edited still does not open (3C.9). |
| Event Detail | `EVT-DETAIL-01` | The `.thisAndFuture` option in the scope confirmation dialog (3D.5). A pending or conflicted write shows an indicator — and, per spec 3.25, the event displays its **device** state while a local edit is pending, because that is what everyone else can see. |
| Settings | `SET-01` | Entry point to `SRC-STAT-01`, beside the existing device-calendar diagnostics. |

Per spec 3.35, each new state needs real copy, not a generic failure message: an edit that could
not be saved to the device (with "try again" and "keep my copy"), a conflict awaiting resolution,
and a calendar that became read-only while an edit was queued.

**A failed mutation must remain findable.** Spec 3.21 is explicit that a conflict the user
dismisses by accident must still be reachable, which is why this is a screen and not only a
banner.

---

## 3D.9 What the mirror has to learn

Phase 3C's `DeviceEventMirror` assumes every mirrored row was named by it — its local id is a pure
function of the provider identifier. A Better Calendar-created event that has just been pushed to
the device breaks that assumption: it has a local id of its own *and* a provider identifier.

The mirror therefore matches on `providerObjectID` **first**, falling back to the derived id, and
must never delete or re-key a row whose id it did not derive. Concretely:

* Matching becomes: by `providerObjectID`, then by `providerExternalID`, then by derived id.
* A row that matches by identifier keeps its existing local id, whatever that id is.
* The bounded-window deletion rule (3C.8) is unchanged, and still requires a row to carry provider
  identity — which a pushed create now does, from the moment its receipt lands.

This is the one place where 3D reaches back into 3C's code, and it is the reason the receipt must
be written in the same transaction as the status change: a row with a device identifier and no
`applied` mutation, or the reverse, is a state the mirror would have to guess about.

---

## 3D.10 Migration `v021`

Following the Phase 2 §2.17 framework: numbered, forward-only, transactional, checksummed, and
tested against fixture databases from every previously released version.

```sql
ALTER TABLE pending_mutations ADD COLUMN base_provider_version TEXT;
ALTER TABLE pending_mutations ADD COLUMN failure_class TEXT;
ALTER TABLE pending_mutations ADD COLUMN last_failure_at TEXT;
```

* `base_provider_version` is 3D.7's concurrency anchor.
* `failure_class` is what `SRC-STAT-01` reads to say *why* something is stuck, and what the
  un-parking pass filters on. Nullable: a row that never failed has no class.
* No column is added for the status itself — `pending_mutations.status` already exists and carries
  no `CHECK`.
* **No index is added either.** `v016_add_engine_indexes` already created
  `pending_mutations_status_idx` on `(status, next_retry_at)`, which serves both queries this
  phase adds: the drain pass filtering on status and due time, and `SRC-STAT-01` filtering on
  status alone. A second index over the same leading column would cost every outbox write and buy
  nothing.

---

## 3D.11 Test matrix

Runs on the macOS destination against `FakeEventKitStore`, extended with a writable event store:
scriptable failures by class, a recorded write log, and simulated external mutation between the
fetch and the save.

**The deferral rule (3D.1)**
* A pending mutation on a device calendar is not retired by a pass with no provider result
* Launch performs no provider I/O, and leaves device rows pending
* A mutation on a local calendar is retired exactly as it is today — the fix changes nothing for
  Phase 1/2 behaviour

**Create**
* Create → receipt persisted → the mirror row carries the device identifier and version
* A create that succeeded but crashed before the receipt is **adopted, not duplicated**
* The adoption search is bounded, and a low-confidence match creates rather than adopts
* The local row id is unchanged by the receipt

**Update**
* An update patches only the fields the journal's `FieldDiff` names
* A title-only edit leaves the preserved provider payload intact (BC-EK-017, end to end)
* An update to a read-only calendar is rejected before any local write (BC-EK-010)

**Delete**
* Delete removes the device event and the tombstone prevents resurrection (BC-EK-009)
* A delete for an event already gone from the device is a success, not a failure

**Recurrence scopes**
* `.thisEventOnly` detaches exactly one occurrence and leaves the rest untouched
* `.thisAndFuture` issues one future-span write and re-mirrors; no local split is written first
* `.allEvents` addresses the master, and every non-detached occurrence follows
* A detached occurrence deleted externally does not remove its siblings

**Failures**
* Each class routes to its specified handling
* A permission failure does not increment `attemptCount`, and does not set `nextRetryAt`
* A parked mutation returns to `pending` when access is restored, with its retry budget intact
* A failed mutation is never deleted and is visible to diagnostics

**Concurrency**
* A last-modified mismatch on disjoint fields merges rather than conflicting
* A mismatch on an overlapping field conflicts, and writes nothing to the device
* The local edit survives a conflict in the outbox payload and in `EventVersion`

**Stress** (reduced smoke on every PR, full loop before release, per the Phase 2 precedent)
* Zero duplicate device events across 1,000 create-crash-retry cycles
* Zero lost local edits across 1,000 concurrent-external-edit cycles
* Zero resurrections across 1,000 delete-then-delayed-reconcile cycles

---

## 3D.12 Milestones

| Milestone | Contents |
|---|---|
| **3D-M1** | The deferral rule and the safety it buys: `decide` refuses to retire a device-calendar mutation without a provider result; launch does no provider I/O; `MutationStatus.parked`; migration `v021`. No writer yet. **Landed.** |
| **3D-M2** | The adapter: `EventKitStore.save`/`remove`, the writable fake, `DeviceWritePlanner`, `DeviceMutationAdapter`, create with crash-idempotency, delete. **Landed.** |
| **3D-M3** | Update as a patch, the failure taxonomy, optimistic concurrency, and un-parking. **Landed.** |
| **3D-M4** | Recurrence scopes and the third button; `SRC-STAT-01`; the mirror's identifier-first matching; the stress loops; ADR. **Landed.** |

Migration `v022` was not anticipated by 3D.10 and is required by 3D.5: the scope of an edit has to
be recorded on the outbox row, because nothing in the local transaction a scope edit produces
distinguishes it from an ordinary create or update. See ADR 0009, Decision 5.

M1 is the whole of the *safety*, and it is the part that fixes a defect that exists today, so it
lands first and alone — the same order Phase 2 used for the outbox, the prerequisites used for
provider identity, and 3B used for discovery. Every milestone after it adds capability to a
pipeline that is already refusing to lie about what it has done.

## 3D.13 Exit criteria

**Every criterion below is met.** Phase 3D is complete when:

* An event created in Better Calendar on a device calendar appears in Apple Calendar, and one
  edited or deleted there is edited or deleted in Apple Calendar
* No sequence of crash and retry produces a second device event
* A title-only edit leaves a video-conference link, structured location and every other unmodelled
  field intact
* Each of the three edit scopes produces the occurrence set Apple Calendar produces for the same
  edit
* A read-only calendar refuses a write before anything is written locally
* Every failure class routes to its specified handling, a permission failure burns no retries, and
  no failed mutation is ever dropped silently
* A concurrent external edit to a different field merges; one to the same field conflicts, writes
  nothing, and preserves the local edit for Phase 3E to resolve
* Every pending, parked, failed and conflicted mutation is visible in `SRC-STAT-01`
* Every Phase 1, 2, 3A, 3B and 3C test passes unchanged, and `v021` is proven against fixtures from
  every released schema version
