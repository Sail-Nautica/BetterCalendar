# ADR 0009 — Writing back to EventKit: where the I/O runs, what a patch is made of, and what a scope means (spec 3.18–3.22)

- **Status:** Accepted
- **Date:** 2026-09-05
- **Scope:** Phase 3D
- **Relates to:** `Instructions/phase3d_specification.md`, `Instructions/phase3_specification.md`
  §3.18–§3.22,
  `Better Calendar/Domain/DeviceEventWrite.swift`,
  `Better Calendar/Domain/Engine/DeviceWritePlanner.swift`,
  `Better Calendar/Domain/Engine/DeviceWriteCommitter.swift`,
  `Better Calendar/Data/Engine/DeviceMutationAdapter.swift`

## Context

Phase 3D attaches a writer to the far end of the outbox Phase 2 built and ran empty. Every phase
before it had one property that made it safe: nothing this app did could disagree with the device.
3D removes that deliberately, and five questions had to be answered before the first byte reached
EventKit.

## Decision 1 — The drain is driven by the store, not `MutationProcessorActor`

Spec 3.18 says EventKit I/O runs "through `MutationProcessorActor`, off the main thread, not
inside launch", and the Phase 3D specification repeated it. The implementation does not, because
the actor loads and writes through the repository *directly* — behind the store's back. A receipt
written that way leaves `BetterCalendarStore.events` stale until the next full reload, so the user
keeps seeing an event marked pending after it has synced, and the mirror pass that runs next reads
a database the store does not agree with.

The property the actor exists to protect is that launch is not blocked on EventKit. That is
supplied instead by the seam itself: `EventKitStore.save`/`remove`/`events(in:)` are `async`, the
real adapter runs its EventKit work in a detached task, and nothing calls the drain from `load()`.
`MutationProcessor.decide` stays pure and synchronous, which is the constraint that actually
mattered.

The three phases are still separate and still mostly pure: `DeviceWritePlanner` (pure) decides
what to write, `DeviceMutationAdapter` (async) performs it and performs no local writes at all,
`DeviceWriteCommitter` (pure) turns each answer into one `EngineTransaction`.

## Decision 2 — The patch set comes from the change journal

An update fetches the live device event and applies exactly `DeviceEventWrite.fields` onto it. The
alternative — constructing an event from our model and saving it — writes every field we do not
model as *absent*, which is how a title-only edit strips the video-call link off a meeting.

The subtler question is where "what changed" comes from. Not from a diff computed at write time
against the local row: by the time a queued mutation drains, that row may already carry a later
edit or an update from a mirror pass. The only record of what the *user's edit* touched is the
change journal's `FieldDiff`, written when they made it, and the outbox row already points at it
through `changeJournalEntryID`. Phase 2 §2.8 has recorded this since M2; this is its first reader.

`DeviceEventField` has no attendee case. EventKit exposes no setter, so a field for one would be a
promise this app cannot keep — and its absence means no code path can try.

## Decision 3 — `.inFlight` is written before the device is touched

Spec 3.19 requires that a create which succeeded in EventKit but crashed before its receipt was
persisted must not create a second device event on retry. Those two situations — "never attempted"
and "may already have landed" — are indistinguishable on a `pending` row.

So the drain marks its rows `.inFlight` in a local transaction *before* issuing anything, and the
adoption search runs only for a create that is already `.inFlight`. One cheap local write buys the
distinction; the alternative is a device fetch before every create, paid by every user for a case
that happens to almost none of them.

The search itself defers to Phase 2's `DuplicateDetector` rather than growing a second heuristic
(spec 3.30's rule, applied early), and adopts only a high-confidence match. A weaker match creates:
a visible duplicate is a better failure than silently binding the user's local row to somebody
else's meeting.

## Decision 4 — Concurrency is measured from the edit's base, not from its intent

Spec 3.22 says a last-modified mismatch is a signal, not a verdict, and should be confirmed with a
field-level diff: disjoint fields merge, an overlap conflicts.

The specification did not say what to diff *against*, and the obvious reading — the state we
intend to write — is wrong. It finds every field the mutation is about to change and calls all of
them conflicts, which makes the merge rule unreachable and stalls every concurrent edit.

The comparison has to be against the state the edit was **based on**. Phase 2's `EventVersion` has
snapshotted exactly that on every committed update since M2, keyed by the same journal entry id
the outbox row carries. The adapter reads it back and compares device-now against edit-base. A
mutation with no recorded base conflicts rather than guessing: a conflict costs the user a
decision, a wrong merge costs them a field.

## Decision 5 — A scope is carried on the outbox row, because the local shape does not imply it

Spec 3.20's table maps three edit scopes onto EventKit's two spans. Two of the three have a device
shape that does not resemble the local transaction that produces them:

* **This event only** creates a replacement event locally; on the device it is a save of one
  *occurrence*, which detaches it. Read literally, the planner creates a new event — a duplicate
  beside the occurrence the series still generates.
* **This and future** truncates one master and creates another locally; on the device it is a
  single future-span write that EventKit splits for itself. Issuing both rows leaves a truncated
  series *and* a separate new one EventKit never made.
* **All events** needs no special case: editing the master with the this-event span *is* how
  EventKit changes a whole series.

Nothing in the local transaction distinguishes the first two from an ordinary create or update, so
the scope is stored on the row (`v022`) and read by the planner. Both rows of a split carry it: one
becomes the write, the other is **retired locally** rather than skipped — a row nobody will ever
process is a queue that never drains.

A scoped write's receipt is not applied to the local row. A split returns the identifier of the new
series and a detachment returns the series' own; binding either to the edited row would bind it to
the wrong thing. The series is re-mirrored instead, and the device's answer wins, which is what
spec 3D.5 asks for.

### Consequence for Phase 3C's mirror

The mirror could previously assume every mirrored row was named by it, because the local id was a
pure function of the provider identifier. That stops being true here: an event created in Better
Calendar and pushed has a local id of its own *and* a provider identifier. So matching became
identifier-first — provider identifier, then external identifier, then the derived id — and a
detachment is matched to the local replacement sitting in its slot, which is how a "this event
only" edit and the detachment it causes end up as one row instead of two.

## Non-decisions

- **Conflict *resolution* is not here.** 3D detects and parks; the merge rules, the "ask the user"
  cases and the resolution surface are Phase 3E (spec 3.25). Detection without resolution is the
  safe half — a parked mutation loses nothing.
- **Parking is a distinct status, not a long retry.** A permission failure leaves `attemptCount`
  untouched, so a week of denied access does not exhaust a queue that was never attempted.
- **The full stress loops are selected by test name, not by `BC_STRESS`.** xcodebuild does not
  forward its environment to the macOS test runner, so the existing variable never reaches
  `ProcessInfo` — see `DeviceWriteStressTests`.
