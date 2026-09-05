# Better Calendar: Detailed Phase 3F Specification

Phase 3F is **the duplicate-connection rule** — sections 3.28 through 3.30 of
`Instructions/phase3_specification.md`. It is the phase that exists almost entirely for a problem
Phase 5 will create.

* **Phases 3A–3E** connected the device, mirrored it, wrote back to it, and learned to notice it
  changing underneath us.
* **Phase 3F** (this document) makes sure that when Phase 5 adds a *second* way to reach the same
  calendar, the app does not end up mirroring it twice.
* **Phase 3G** then adds Reminders, and Phase 3 is done.

The roadmap states the problem directly: a Google calendar may already appear in EventKit because
the user added their Google account in iOS Settings, and in Phase 5 Better Calendar may *also*
connect to that account directly. Synchronising both copies independently produces duplicate
events, duplicate notifications, and edits that fight each other.

Phase 3 cannot fully solve this — the direct connection does not exist yet. It must build the
detection and the storage now, because retrofitting them after Phase 5 means migrating live user
data on a schema that was never designed for it.

---

## 3F.0 Scope

### Included

* A **connection identity**: what makes two calendar rows the same underlying calendar even when
  every identifier they carry is different
* `EventKitStore.sources()`, which spec 3.2 reserved for exactly this phase
* Detection of duplicate connections, and the storage of the user's choice
* Honouring that choice: the non-chosen transport does not mirror, does not write, and does not
  appear as a separate calendar
* `SRC-CONN-01`, and the calendar-manager entry point to it
* A **designed migration path** for changing the choice later — specified and implemented as a
  pure planner, even though nothing in Phase 3 can trigger it
* `DuplicateDetector` extended with a "same event, different transport" match reason, and the
  ICS-import-versus-mirror overlap that is a real case *today*
* Migration `v024`

### Excluded

* The Google Calendar API and any direct connection — Phase 5. Phase 3F builds the seam the
  choice is made *through*, and ships with only one transport able to answer.
* Reminders — Phase 3G
* Any change to how a single connection mirrors or writes. 3C and 3D own that.

### Requirement coverage

| ID | Statement | 3F delivers |
|---|---|---|
| BC-EK-020 | A calendar reachable both through the device and directly prompts a connection choice | The detection, the storage, the surface, and the prompt — exercised against fixtures and reachable today only in the degenerate case (3F.4) |
| BC-EK-021 | The same underlying event never appears twice from two connection methods | The calendar-level half in full: a superseded connection contributes no events at all. The event-level half is the new `DuplicateDetector` reason, which is what catches the case the calendar rule cannot |

---

## 3F.1 Connection identity: what "the same calendar" means

The hard part is that **none of the identifiers we store survive a change of transport.**
EventKit's `calendarIdentifier` is EventKit's; Google's calendar id is Google's; the two have
nothing to do with each other even when they name the same calendar. Neither does the account
identifier — `EKSource.sourceIdentifier` is a device-local value.

So connection identity is composed from the things that *are* stable across transports:

```text
CalendarConnectionIdentity
- provider     — who owns the data (`EventProvider`, from ADR 0004's two-axis model)
- accountKey   — the account's email or title, normalised
- calendarKey  — the calendar's own name, normalised
```

This is deliberately **not** a strong identity, and that shapes everything downstream:

* Two calendars sharing one is a *candidate*, never a conclusion. Spec 2.15's "never merge
  silently" applies with more force here than anywhere else in Phase 3, because the thing being
  merged is a whole calendar.
* `provider` is part of the key, which is why ADR 0007 was so careful to attribute CalDAV
  narrowly: a calendar wrongly attributed to `.google` becomes a false match here, and a false
  match hides a calendar the user still has.
* Normalisation is case- and whitespace-folding only. Nothing clever — "Work" and "work" are the
  same calendar, "Work" and "Work Calendar" are not.

An identity is only computed for a calendar that has an account. A local Better Calendar calendar
has no connection to duplicate.

## 3F.2 Detection

`DuplicateConnectionDetector` answers this at two levels, and shipped as two functions rather than
the single `candidates(among:sources:)` this document first named — the two questions have
different inputs and different answers, and one signature returning both would have to be
destructured at every call site anyway.

Two levels, because spec 3.29 asks for both:

* **Account level.** Two `EKSource`s with different identifiers and the same normalised title are
  the same account configured twice — the degenerate case that makes this reachable in Phase 3 at
  all. This is what `sources()` is for, and why 3B was right to defer it: a source with no
  calendars has nothing to toggle, but it does have something to *compare*.
* **Calendar level.** Two calendar rows sharing a `CalendarConnectionIdentity`, whatever accounts
  they came from.

A group with fewer than two members is not a group. A group whose members are all the same
`connectionMethod` **is** still a group in Phase 3 — that is precisely the degenerate case — and
the choice it offers is which of them to keep rather than which transport to use.

## 3F.3 The choice, and honouring it

The user's answer is stored on the calendar row, as spec 3.29 requires. Two fields do it, because
one cannot:

* `connectionMethod` already records *how* a calendar is reached (ADR 0004). It is the axis the
  choice is made along, and in Phase 5 it is the whole answer.
* `isSupersededByDuplicateConnection` records that this row **lost** a choice. It is needed
  because in Phase 3's degenerate case both rows have the same `connectionMethod`, so that field
  alone cannot say which one won.

A superseded calendar:

* **Does not mirror.** `DeviceEventMirror.fetchableCalendars` excludes it, so no pass fetches it
  and — by the bounded-window rule — no pass deletes from it either. Its existing events are
  retained and hidden, exactly as spec 3.26 requires of any calendar that stops being fetched.
* **Does not write.** It is not a writable destination, and `EventMutationUseCases` refuses it at
  the model layer with its own `CapabilityViolation` reason, so a queued edit cannot reach the
  device through a connection the user has switched off.
* **Does not appear as a separate calendar.** It is absent from the calendar list and from every
  picker; `SRC-CONN-01` is where it remains visible and reversible.

The rows are never deleted. Superseding is a choice, and a choice the user can change.

## 3F.4 What is reachable in Phase 3

Only the degenerate case: the same account configured twice on the device. That is rare but real —
it happens when someone adds a Google account both as "Google" and as a generic CalDAV account.

So this phase ships the **mechanism** and exercises the prompt with fixtures, exactly as spec 3.29
instructs. The honest statement of what that means: `SRC-CONN-01` will not appear for most users
in Phase 3, and the code path that presents it is proven by tests rather than by use. That is the
same trade Phase 2 made with the outbox and the prerequisites made with provider identity, and it
is the right one — the alternative is discovering the design is wrong while migrating live data in
Phase 5.

## 3F.5 Changing the choice is a migration, not a toggle

Spec 3.29 is explicit: re-key mirrored events to the new transport's identifiers rather than
deleting and re-importing. The difference matters because deleting and re-importing loses every
local id — and with it every undo action, every conflict-index entry, and the identity every
`EventVersion` row points at.

`ConnectionMethodMigrationPlanner` produces that re-keying as a pure `EngineTransaction`:

```text
For each event on the losing calendar:
  match it against the winning calendar's events by provider external identifier,
  then by the Phase 2 duplicate heuristics
  → matched:   the winning row keeps its own local id and adopts nothing; the losing
               row is deleted, with a tombstone whose cause says why
  → unmatched: the event is *moved* to the winning calendar — its local id, and every
               reference to it, survives
```

Nothing in Phase 3 calls it: there is no second transport to migrate to. It ships tested so Phase 5
inherits a designed path rather than an improvised one, which is the whole reason spec 3.29 asks
for it now.

## 3F.6 Cross-provider duplicate detection

Spec 3.30: extend Phase 2's `DuplicateDetector` rather than writing a second one.

**A new match reason, `sameEventDifferentTransport`**, scored on account identity plus the
provider's own event identifier. The insight it encodes: the same underlying event reached two
ways carries the same *account-level* identifier even when the local ones differ. For EventKit
that is `calendarItemExternalIdentifier` — which for a CalDAV or Google calendar is derived from
the iCalendar UID, and is therefore the same string a direct connection would see.

**And the case that is real today, with no second transport at all:** an ICS file re-imported over
events already mirrored from the device. Phase 1's import path sets `providerObjectID` from the
RFC 5545 `UID`; the mirror sets `providerExternalID` from `calendarItemExternalIdentifier`, which
for those calendars *is* that UID. The existing detector compares only `providerObjectID` against
`providerObjectID`, so it misses the match entirely and the user gets two of everything.

Comparing the external identifier as well closes it. This is not a Phase 5 hypothetical — Phase 1's
import and Phase 3's mirror overlap now.

**Never merge silently** (spec 2.15) is unchanged and matters more here. The detector returns
candidates with confidence; `commitImport`'s existing skip-on-duplicate policy decides.

## 3F.7 Surfaces

| Screen | ID | This phase |
|---|---|---|
| Connection choice | `SRC-CONN-01` | **New.** Names the duplicated calendar and its accounts, presents the trade-off spec 3.29 states honestly, and records the answer. Also lists choices already made, so one can be changed. |
| Device calendars | `SRC-LIST-01` (extended) | A banner when a duplicate connection is detected and unanswered, linking to `SRC-CONN-01`. Superseded calendars are not listed. |
| Calendar Manager | `CAL-MGR-01` (extended) | The same entry point, since spec 3.29 names the calendar manager specifically. |

Copy follows spec 3.35: what happened, why, and what to do next. The trade-off is presented as
spec 3.29 writes it — device connection needs no extra sign-in and is limited to what EventKit
exposes; direct connection is richer and needs a separate sign-in — with the honest note that the
second option is not available yet.

## 3F.8 Migration `v024`

```sql
ALTER TABLE calendars ADD COLUMN is_superseded_by_duplicate_connection INTEGER NOT NULL DEFAULT 0;
ALTER TABLE calendars ADD COLUMN duplicate_connection_resolved_at TEXT;
```

Nothing is added for the identity itself: `provider`, `provider_account_id`, `account_name` and
the calendar's own `name` have all been carried since `v018`, and the identity is computed from
them. That is what spec 3.29 meant by "record enough identity at discovery" — the recording
already happened, in the prerequisites.

`duplicate_connection_resolved_at` exists so the detector can tell "not yet asked" from "asked and
the user kept both", and not re-prompt for a choice already made.

## 3F.9 Test matrix

**Identity**
* Two calendars from the same account and name share an identity; different names do not
* Identity folds case and whitespace and nothing else
* A local calendar has no identity

**Detection**
* Two sources with the same title and different identifiers are detected as one account
* Two calendar rows sharing an identity are detected as a duplicate connection
* A single calendar is not a group
* A resolved duplicate is not re-detected
* A false-attribution guard: two calendars with the same name on genuinely different accounts are
  not a duplicate

**Honouring the choice**
* A superseded calendar is not fetched by a mirror pass
* Its existing events are retained and hidden, not deleted
* It is refused as a write destination at the model layer
* It does not appear in the calendar list or in a destination picker
* Un-superseding it restores all of the above

**The Phase 5 migration path**
* A matched event on the losing calendar is deleted with a tombstone, and the winner keeps its id
* An unmatched event is moved rather than recreated — its local id survives
* The plan is one transaction

**Cross-provider duplicates**
* An event carrying the same external identifier as a mirrored one is a duplicate
* An ICS re-import over mirrored events is skipped rather than duplicated
* A different event with a similar title is not
* The match reason is reported, so diagnostics can say *why*

**Persistence**
* `v024` round-trips, and is proven against fixture databases from every released version

## 3F.10 Milestones

| Milestone | Contents |
|---|---|
| **3F-M1** | Identity, detection, `sources()`, and migration `v024`. No UI, nothing honoured yet. **Landed.** |
| **3F-M2** | Honouring the choice: mirroring, writing, listing, and the model-layer refusal. **Landed.** |
| **3F-M3** | `SRC-CONN-01` and its entry points. **Landed.** |
| **3F-M4** | The cross-provider match reason, the ICS overlap, the Phase 5 migration planner, and the ADR. **Landed.** |

Landed as one change rather than four commits: M1 is the only part with a false-positive risk
worth isolating, and it is pure and fully tested before anything acts on it — the milestones after
it are consumers of that one decision rather than independent risks. See ADR 0011.

M1 first and alone, on the same reasoning every phase in Phase 3 has used: the detection is where
a false positive hides a calendar the user still has, and it is entirely testable before anything
acts on it.

## 3F.11 Exit criteria

**Every criterion below is met.** Phase 3F is complete when:

* Two connections to the same underlying calendar are detected, the user is asked which to keep,
  and the answer is stored on the calendar row
* A superseded connection mirrors nothing, writes nothing, and appears nowhere except the screen
  where the choice can be changed — and loses no data
* The choice is changeable, and changing it re-keys rather than re-imports, with the path proven
  by tests even though nothing in Phase 3 can trigger it
* An event reached two ways is detected as one event, and an ICS re-import over mirrored events is
  skipped rather than duplicated
* No duplicate is ever merged silently
* Every Phase 1, 2, 3A–3E test passes unchanged, and `v024` is proven against fixtures from every
  released schema version
