# ADR 0010 — How long a hidden mirror row lives, and which conflicts the engine may decide (spec 3.23–3.27)

- **Status:** Accepted
- **Date:** 2026-09-05
- **Scope:** Phase 3E
- **Relates to:** `Instructions/phase3e_specification.md`, `Instructions/phase3_specification.md`
  §3.23–§3.27,
  `Better Calendar/Domain/Engine/ConflictResolver.swift`,
  `Better Calendar/Domain/Engine/DeviceEventMirror.swift`,
  `Better Calendar/Domain/DeviceEvent.swift` (`CalendarReconciliationState`)

## Context

Phase 3E gives the mirror a trigger it reacts to automatically and gives conflicts an answer.
Three decisions had to be made that spec 3.23–3.27 either left open or explicitly deferred to an
ADR.

## Decision 1 — Mirrored events for a calendar unavailable more than 90 days are purged; the
calendar row is not

Spec 3.26 requires access loss never be treated as deletion, and then asks for a bound: "define a
retention limit for hidden mirror rows … Record N in an ADR; do not leave it implicit." Without
one, an account removed from the device and never re-added keeps every event it ever mirrored,
forever.

**N is 90 days**, measured from `BetterCalendar.unavailableSince`, which Phase 3B has been
recording since `v019`.

* It has to comfortably exceed any plausible sync outage, a long holiday, or a phone left in a
  drawer. Days would be wrong. Weeks are marginal — a term abroad is longer than a month.
* It is only ever allowed to remove rows that are **reconstructible**, which is exactly ADR 0008's
  second property: deleting the mirror and re-mirroring produces the same calendar. Re-adding the
  account brings everything back.
* A Better Calendar-owned event on that calendar is never purged, whatever it is doing there. It
  is not reconstructible and nothing would bring it back.

**The calendar row survives.** It carries the user's own choices — visibility, sort order, whether
it was the default (spec 3.8) — and those are the one thing here that re-mirroring cannot
reconstruct. Keeping them is what makes re-adding an account feel like reconnecting rather than
starting over.

**No tombstones are written.** A tombstone exists to stop a late change resurrecting something the
user deleted (spec 2.13); this is housekeeping on a calendar nobody is reporting anything about,
and writing thousands of them would leave a bigger database than the one being trimmed. If the
account comes back, re-mirroring is the correct outcome, not a suppressed one.

The purge runs from the drain rather than inside the mirror pass, deliberately. The pass's whole
discipline is being conservative about absence; this is the one rule that acts on it, and the two
do not belong on the same code path.

### Revisit trigger

Revisit if a support case shows a real user losing mirrored data to this. The failure mode would
be an account absent for a season and then restored on a device with no network — where
re-mirroring cannot immediately refill what was purged.

## Decision 2 — The conflict line is drawn at reversibility, not importance

Spec 3.25 lists which conflicts resolve themselves and which are asked about. Implementing it
required saying *why* that list looks the way it does, because the list will need extending.

The rule is **reversibility**. A title resolved the wrong way is retyped in seconds, and the losing
version is in `EventVersion` either way. A time resolved the wrong way sends somebody to a meeting
that moved, and no amount of preserved history gets them back that hour.

So `ConflictResolver.lowRiskFields` is `title`, `notes`, `location`, `url`, and everything else —
time, recurrence, availability, and anything added later — asks the user. Two consequences that
follow from stating it this way rather than as a list:

* One high-risk field in the overlap is enough, however many low-risk ones travel with it.
* A field added to `DeviceEventField` in a later phase is asked about by default. The set names
  what may be decided automatically, not what must be asked, so forgetting to update it fails
  toward asking.

A **delete** always asks, whatever the other side changed. Deleting something somebody else just
edited is the case where guessing wrong is least recoverable.

## Decision 3 — Nothing is discarded, including by the user's own choice

Spec 3.25 says "never discard" about the automatic case. It is applied to the manual one too:
"Keep Theirs" snapshots the local edit into `EventVersion` before retiring the mutation.

The user choosing which version to *show* is not the same as choosing which to forget, and the
cost of keeping it is one row. The snapshot is taken from the **outbox payload** rather than from
the local row, because by the time a conflict is resolved the row has already been mapped back to
the device's state by a mirror pass — the payload is the only place the edit still exists exactly
as it was made.

## Non-decisions

- **The window is state, but the deletion permission is not.** `CalendarReconciliationState`
  records what has been reconciled so a widening pass knows what it has not seen. A row may still
  only be deleted when its start lies inside the range *that pass actually fetched* — unchanged
  from ADR 0008, Decision 4, and tested to hold the two apart.
- **`BetterCalendarStore` is now `@MainActor`.** Spec 3.23's "never run two passes concurrently"
  is a guard flag, and a flag can only promise that on an isolated type. The isolation was already
  true of every caller; making it explicit is what makes the guarantee real rather than incidental.
- **Coalescing is 1 second.** Long enough to absorb an account sync's burst, short enough that a
  change made in Apple Calendar appears while the user is still looking for it. Not recorded as a
  decision worth defending — it is a tuning constant, and the property that matters (a burst costs
  one pass) is tested independently of its value.
