# Better Calendar: Detailed Phase 3E Specification

Phase 3E is **noticing that the device changed, and deciding what to do when both sides changed
at once** — sections 3.23 through 3.27 of `Instructions/phase3_specification.md`.

* **Phase 3C** built the mirror and ran it on explicit triggers. **Phase 3D** attached the writer
  and, deliberately, stopped at *detecting* a concurrent external edit: it parks the mutation as
  `.conflicted`, writes nothing, and loses nothing.
* **Phase 3E** (this document) supplies the trigger 3C withheld and the resolution 3D withheld.
* **Phase 3F** then handles a calendar reachable two ways at once.

The two halves are one phase because neither is safe alone. Reacting to every device change
without a conflict policy means overwriting the user's queued edits at machine speed; a conflict
policy with no trigger means the user only finds out they have a conflict the next time they
happen to foreground the app.

---

## 3E.0 Scope

### Included

* `EKEventStoreChanged` observation for the lifetime of the app, coalesced, with no two passes
  running concurrently
* The remaining reconciliation triggers spec 3.23 names: calendar-selection change, and the
  visible date range moving outside the mirrored window
* `refreshSourcesIfNecessary`, on the passes where it earns its network cost and not on the others
* A **reconciliation-state table** — per calendar, the window last reconciled and when — which is
  what makes a moving window safe (3E.3)
* The conflict resolution policy of spec 3.25: automatic merge, newest-wins for low-risk fields,
  and asking the user for the rest
* The resolution surface, extending `SRC-STAT-01` rather than adding a second place to look
* A retention limit for mirrored events on a calendar that has been unavailable for a long time,
  with the number recorded in an ADR
* Migration `v023`

### Excluded

* The duplicate-connection rule and cross-provider duplicate detection — Phase 3F
* Reminders — Phase 3G
* Any change to what a *write* does. Phase 3D owns create, update, delete and the scopes; 3E only
  decides what happens after one is refused.

### Requirement coverage

| ID | Statement | 3E delivers |
|---|---|---|
| BC-EK-006 | An event created in Apple Calendar appears in Better Calendar after reconciliation | Completed: 3C delivered it on an explicit trigger, and this makes the trigger automatic |
| BC-EK-011 | An event edited externally between two launches is reconciled without losing local edits | Completed. 3D detected the collision; this resolves it |
| BC-EK-012 | An event deleted externally is removed locally and does not reappear | Reinforced: the bounded-window rule gets a persisted window to be bounded *by*, rather than a fixed span around now |

---

## 3E.1 Observation

`EKEventStoreChanged` carries no payload. It means "something changed, re-query" — never "this
event changed" — so it triggers a pass, and a pass is the bounded range diff 3C already built.

* Subscribed for the lifetime of the app, through the `EventKitStore` seam rather than
  `NotificationCenter` directly, so `FakeEventKitStore` can post one and CI can prove the wiring
  without a device (BC-EK-024).
* **Coalesced.** The notification arrives in bursts during account sync — a dozen in a second is
  ordinary. A burst must produce one pass, so notifications are debounced.
* **Never concurrent.** Two passes running at once would each diff against a database the other is
  writing, and the loser's deletions would be computed from a window the winner had already
  changed. One pass at a time, and a notification that arrives during a pass schedules exactly one
  more.

### `refreshSourcesIfNecessary`

Asks the device to pull from the server rather than only reporting what it already has. It
triggers network activity, so it runs on **foreground and on an explicit user refresh only** —
never on an `EKEventStoreChanged` pass, which by definition is reacting to something the device
already knows.

---

## 3E.2 The remaining triggers

3C wired the pass to Phase 3B's triggers: foreground, fresh grant, device-calendar surface
appearing. This adds the two spec 3.23 names that need state 3C did not have:

* **Calendar-selection change.** Turning a calendar on means its events have never been fetched;
  turning one off means the next pass must not treat its rows as deletable. Both are already
  correct in 3C's planner — this only adds the trigger, so the events appear on toggle rather than
  on next foreground.
* **The visible range moving outside the mirrored window.** This is the one that needs 3E.3.

---

## 3E.3 The reconciliation-state table, and why a moving window needs one

3C's window is a fixed span around *now*, and its deletion rule is the strict reading of spec
3.24: a row is deleted only when its own start lies inside the window that was actually fetched.
That is safe precisely because the window never moves.

A window driven by the visible range moves constantly, and the danger is immediate: scroll to next
March, fetch a window around next March, and every mirrored event in *this* month is now "absent
from the fetch". Nothing in 3C's model stops that from reading as a mass deletion except the fact
that its window never went anywhere.

So the window becomes state rather than a computation:

```sql
CREATE TABLE calendar_reconciliation_state (
    calendar_id TEXT PRIMARY KEY NOT NULL REFERENCES calendars(id) ON DELETE CASCADE,
    window_start TEXT,
    window_end TEXT,
    last_reconciled_at TEXT
);
```

* A pass fetches the range it needs and records it.
* A row may be deleted only if its start lies inside **the range this pass actually fetched** —
  unchanged from 3C. The stored window does not widen that permission; it exists so a pass can
  tell whether a range has *ever* been covered, and so the next pass can fetch the union of what
  is newly visible and what was mutated since.
* `last_reconciled_at` is what `SRC-STAT-01` reads to say when a calendar was last checked, and
  what a future backoff would measure from.

The table is per calendar because visibility is per calendar: a calendar toggled on this morning
has been reconciled over a different range than one that has been on for a week.

---

## 3E.4 The conflict model

Phase 3D leaves a conflicted mutation carrying everything a decision needs: the local edit in the
outbox payload, the fields it touched in the change journal's `FieldDiff`, and the state it was
based on in `EventVersion`. 3E is the policy that reads them.

A row only reaches `.conflicted` when the two sides overlap — 3D already merges disjoint edits
without asking. So the classification is over the **overlapping** fields:

| Overlap | Resolution |
|---|---|
| Low-risk only — title, notes, location, url | **Newest write wins**, automatically. The loser is snapshotted into `EventVersion` before it is dropped. Never discarded. |
| Time (start, end, all-day, time zone), recurrence, or availability | **Ask the user.** Both versions preserved until they answer. |
| A local delete against an external edit | **Ask the user.** Deleting something that someone else just changed is the case where guessing wrong is least recoverable. |

"Newest" compares the local edit's journal timestamp against the device event's last-modified.
Both are recorded; neither is inferred.

### What the user sees before they answer

Spec 3.25: the event displays its **device** state — the shared truth other people and other
devices already see — with an indicator that a local edit is pending. Not the local state, which
nobody else can see and which may never survive.

This falls out of the mirror rather than needing its own mechanism: the device wins by content
(ADR 0008, Decision 3), so the next pass maps the device state back onto the row, and the local
edit continues to live in the outbox payload. 3E's job is to make that *legible* — an indicator on
the event, and the conflict listed where the user can find it — not to build a second copy of the
event to show.

### Resolving

Two actions, in `SRC-STAT-01` beside the mutation:

* **Keep mine** — re-base the mutation on the device's current version and re-queue it. The next
  drain writes it, and the device's competing change is superseded by an explicit choice.
* **Keep theirs** — snapshot the local edit into `EventVersion` and retire the mutation. The row
  already shows the device state, so nothing changes on screen; what changes is that the queue
  stops carrying an edit the user has abandoned.

Neither action discards anything. "Keep theirs" is the closest thing to a discard, and it still
writes the losing version into history first, because spec 3.25's "never discard" does not have an
exception for the case where the user said so.

---

## 3E.5 Access loss, and how long a hidden mirror row lives

Spec 3.26's rules are already implemented and unchanged: access loss is not deletion, a
deselected calendar's rows are retained and hidden, and re-granting reconnects by provider
identifier rather than re-importing.

What is missing is the bound. A calendar that has been unavailable for months — an account removed
from the device and never re-added — keeps every event it ever mirrored, forever.

**A mirrored calendar unavailable for more than 90 days has its mirrored events purged**, and the
calendar row itself is kept. The number is recorded in ADR 0010 rather than left implicit, and the
reasoning is:

* It must comfortably exceed any plausible sync outage, a holiday, or a phone left in a drawer.
  Days would be wrong; weeks are marginal.
* It only ever removes rows that are **reconstructible** — that is the whole point of ADR 0008's
  second property, and re-adding the account re-mirrors everything.
* The calendar row survives because it carries the user's own choices: visibility, sort order,
  and whether it was the default (spec 3.8). Those are not reconstructible, and they are what
  makes re-adding an account feel like reconnecting rather than starting over.

A Better Calendar-owned event is never purged by this, whatever calendar it is on.

---

## 3E.6 Cost

Spec 3.27, and the reason coalescing is not optional:

* A pass fetches only its window, never the whole calendar — unchanged from 3C.
* Fetches run off the main thread; the seam has been `async` since 3C for this reason.
* **A pass that finds nothing changed writes nothing and costs one comparison per event in the
  window.** Idempotence is what makes reacting to every `EKEventStoreChanged` affordable, and it
  is already proven; 3E adds the perf assertion that the no-op pass stays under spec 3J's
  100-millisecond budget for a one-month window.

---

## 3E.7 Surfaces

| Screen | ID | This phase |
|---|---|---|
| Sync status | `SRC-STAT-01` (extended) | Conflicts gain **Keep Mine** / **Keep Theirs**. The list already exists and already survives being dismissed, which is what spec 3.25 asks for — this adds the answer, not a second place to look. |
| Event Detail | `EVT-DETAIL-01` (extended) | An indicator when a local edit is pending or conflicted on this event, with the same "you are seeing the device's version" explanation the conflict list gives. |
| Settings | `SET-01` (extended) | Last reconciliation time, from the new state table. |

---

## 3E.8 Migration `v023`

```sql
CREATE TABLE calendar_reconciliation_state (
    calendar_id TEXT PRIMARY KEY NOT NULL REFERENCES calendars(id) ON DELETE CASCADE,
    window_start TEXT,
    window_end TEXT,
    last_reconciled_at TEXT
);
```

No column is added to `events` or `pending_mutations`: everything the conflict policy reads was
already recorded by Phase 2 (`change_journal.field_diff`, `event_versions.snapshot_json`) or by
Phase 3D (`pending_mutations.base_provider_version`, `failure_class`).

---

## 3E.9 Test matrix

Runs on the macOS destination against `FakeEventKitStore`.

**Observation**
* A posted change notification triggers exactly one pass
* A burst of ten notifications produces one pass, not ten
* A notification arriving during a pass schedules exactly one more, not one per notification
* `refreshSourcesIfNecessary` runs on foreground and not on a change-notification pass

**Triggers**
* Toggling a calendar on mirrors its events without waiting for a foreground
* Toggling one off deletes nothing
* Moving the visible range beyond the mirrored window widens it and fetches the new range

**The window**
* A pass records the range it fetched, per calendar
* A row outside the range a pass fetched is never deleted, even when the stored window covers it
* Scrolling forward a year and back does not delete the events in between

**Conflicts**
* Overlapping low-risk fields resolve to the newest write, and the loser is in `EventVersion`
* A time conflict is not resolved automatically
* A recurrence conflict is not resolved automatically
* A local delete against an external edit is not resolved automatically
* "Keep mine" re-bases and re-queues, and the next drain writes it
* "Keep theirs" retires the mutation and snapshots the local edit first
* A conflicted event displays the device's state, not the local one

**Retention**
* A calendar unavailable past the limit has its mirrored events purged and its row kept
* One inside the limit keeps everything
* A Better Calendar-owned event on a device calendar is never purged

**Cost**
* A no-op pass over a one-month window stays inside spec 3J's budget

---

## 3E.10 Milestones

| Milestone | Contents |
|---|---|
| **3E-M1** | Observation and coalescing: the seam's change stream, the fake's ability to post one, the debounce, the single-pass guarantee, `refreshSourcesIfNecessary`, and the selection-change trigger. |
| **3E-M2** | The window as state: migration `v023`, the reconciliation-state table, the visible-range trigger, and the widened-window safety rules. |
| **3E-M3** | The conflict policy: classification, automatic resolution, and the `EventVersion` preservation that makes "never discard" true. |
| **3E-M4** | The surfaces, the retention limit and its ADR, and the cost assertion. |

M1 first because it is the trigger, and a trigger that fires too often is the thing most likely to
turn a small bug into a fast one — coalescing and the single-pass guarantee are what keep the rest
of the phase debuggable.

## 3E.11 Exit criteria

Phase 3E is complete when:

* An event created, edited or deleted in Apple Calendar reaches Better Calendar without the user
  foregrounding the app, and a burst of changes produces one pass rather than a storm
* Two passes never run concurrently
* The reconciliation window is driven by what the user is looking at, is recorded per calendar,
  and no widening of it can delete an event that was outside the range actually fetched
* A concurrent edit to different fields merges; to the same low-risk field resolves to the newest
  write with the loser in history; to time, recurrence or a deletion waits for the user
* A conflicted event shows the device's state with a visible indication that a local edit is
  pending, and the conflict is findable in `SRC-STAT-01` until it is answered
* No resolution, including "keep theirs", discards a version without first writing it to history
* Mirrored events for a long-unavailable calendar are purged, its row and the user's choices are
  kept, and the number is in an ADR
* A no-op pass is cheap enough to run on every foreground
* Every Phase 1, 2, 3A–3D test passes unchanged, and `v023` is proven against fixtures from every
  released schema version
