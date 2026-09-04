# Better Calendar: Detailed Phase 3C Specification

Phase 3C is **reading EventKit events into the local database** — sections 3.11 through 3.17 of
`Instructions/phase3_specification.md`. It is the phase where the user's real schedule appears
inside Better Calendar, and therefore the first phase where a bug can damage data the user did
not create in this app.

* **Phase 3A** built the permission model. **Phase 3B** discovered the device's calendars and
  mirrored them as rows the user can show, hide, and write to.
* **Phase 3C** (this document) fills those calendars with events.
* **Phase 3D** writes local changes back out. **Phase 3E** observes external change and resolves
  conflict.

Until 3D exists, the mirror is read-only from Better Calendar's side: every mirrored event's
content comes from the device, and nothing this app does can disagree with it. That is what makes
3C's conflict rule trivially "the device wins" and lets the hard cases wait for the phase that
creates them.

---

## 3C.0 Scope

### Included

* `DeviceEvent` and its satellites — Better Calendar's own value types for what EventKit reports
* The field mapping of spec 3.12, as a pure function, round-trip tested field by field
* Recurrence translation, and the explicit rule for rules the engine cannot express
* Time-zone, all-day and floating semantics preserved through the mirror
* Attendees, the organizer, and event status — a new `event_attendees` table and the domain model
  for it
* Cancelled and declined events excluded from free/busy and conflict detection, closing the
  no-op ADR 0002 reserved for this phase
* Preservation of provider fields Better Calendar does not model (spec 3.17)
* `EventKitStore.events(in:calendarIDs:)`, its EventKit translation, and the fake's support for it
* `DeviceEventMirror` — the pass that turns fetched device events into `EntityChange`s
* Deletion of a mirrored event that has vanished **from inside the fetched window**, with the
  bounded-window safety rule spec 3.24 states
* Store wiring on the triggers Phase 3B already established
* Event detail showing owning account, calendar, read-only state, status, and attendees
* Migration `v020` for everything above

### Excluded

* **Any write to EventKit.** The adapter still has no `save` or `remove` member. Phase 3D.
* Change observation, coalescing, and the reconciliation-state table — Phase 3E. Discovery and
  event fetching run on 3B's explicit triggers, not on `EKEventStoreChanged`.
* Conflict detection and resolution between a local edit and an external one — Phase 3E. There
  are no local edits to a mirrored event until 3D exists.
* Recurrence-scope *writes* (3.20) — Phase 3D. 3C reads a series and its detachments; it does not
  create one.
* The duplicate-connection rule and cross-provider duplicate detection — Phase 3F
* Reminders — Phase 3G

### Requirement coverage

| ID | Statement | 3C delivers |
|---|---|---|
| BC-EK-006 | An event created in Apple Calendar appears in Better Calendar after reconciliation | Fully, on 3B's triggers; 3E adds observation so it happens without a foreground |
| BC-EK-012 | An event deleted externally is removed locally and does not reappear | Within the fetched window. The bounded-window rule is what makes the "does not reappear" half safe |
| BC-EK-013 | A recurring EventKit series expands identically to the same series in Apple Calendar | Fully, for the rules the engine expresses; unrepresentable rules are mirrored intact and marked |
| BC-EK-016 | Mirrored events do not produce duplicate local notifications | Proven against real mirrored events, where the prerequisites could only prove it against a shaped fixture |
| BC-EK-017 | Provider fields Better Calendar does not model survive a local edit round trip | The preservation half. The round trip completes in 3D |
| BC-EK-018 | Every event displays its owning account and calendar in the detail view | Fully |
| BC-EK-003 | Write-only never claims to display device events | Completed: write-only fetches nothing, and says so |

---

## 3C.1 The mirror model

Better Calendar keeps a **local mirror** of device events rather than querying EventKit on every
render. Spec 3.11 gives the reason and it is worth restating, because every rule below follows
from it: calendar views read from the store, recurrence expands through `RecurrenceExpander`,
search reads the FTS index, conflicts read `ConflictIndex`. None of those can be reimplemented
against a live EventKit query without discarding the engine Phase 2 built.

Four properties the mirror must have:

1. **Every mirrored event is an ordinary `CalendarEvent` row.** No parallel table, no special
   case in the view layer. A screen cannot tell a mirrored event from a local one except by
   asking its calendar.
2. **It is not authoritative, and it is reconstructible.** Deleting the entire local database and
   re-mirroring produces the same calendar. This is what makes the mirror safe: no user data
   lives only in it.
3. **Only the mirror pass writes mirrored rows.** In 3C that is the only writer at all; from 3D
   it shares the job with the outbound adapter's receipt handling, and with nothing else.
4. **Identity is the provider's, not ours.** A mirrored row is found again by what the device
   calls it, never by title or time.

### Identity

Spec 3.11 requires both identifiers EventKit offers, because they answer different questions:

| | Stored in | Answers |
|---|---|---|
| `EKEvent.eventIdentifier` | `providerMetadata.providerObjectID` | "Which event do I pass back to fetch or save this?" |
| `EKEvent.calendarItemExternalIdentifier` | `providerMetadata.providerExternalID` | "Is this the same event as the one on my other device, or before this restore?" |

Neither is unique on its own for a detached occurrence of a series — every detachment of one
series shares an external identifier. Identity for anything detached is therefore the pair
`(identifier, originalOccurrenceDate)`, which is the `OccurrenceKey` model Phase 2 already
established for exactly this shape of problem.

`providerVersion` stores the device event's last-modified timestamp. In 3C it is the change
detector; in 3D it becomes the concurrency check (spec 3.22).

`providerAccountID` and `providerCalendarID` stay `nil` on a mirrored **event**. The event's
`calendarID` points at a mirrored `BetterCalendar` that already carries both, and duplicating
them onto every event would create two places for the same fact to be, which is one more than
can be kept in agreement.

---

## 3C.2 Field mapping

Spec 3.12's table, made exact. The mapping is a pure function over `DeviceEvent` in a file with
no EventKit import, so all of it is testable with no device.

| Device event | `CalendarEvent` | Rule |
|---|---|---|
| `identifier` | `providerMetadata.providerObjectID` | |
| `externalIdentifier` | `providerMetadata.providerExternalID` | |
| calendar identifier | `calendarID`, resolved through the mirrored `BetterCalendar` | An event whose calendar is not mirrored is **skipped**, not orphaned |
| `title` | `title` | Empty titles are legal and routine. `displayTitle` supplies "(No title)" at every rendering surface; the stored value stays empty |
| `notes` | `notes` | |
| `location` | `location` | Structured location and geo are preserved raw (3C.6), not modelled |
| `urlString` | `urlString` | |
| `startDate` / `endDate` | `startDate` / `endDate` | See 3C.4 |
| `isAllDay` | `timeType = .allDay` | See 3C.4 |
| `timeZoneIdentifier` | `timeZoneIdentifier` | `nil` on the device means floating; see 3C.4 |
| `availability` | `availability` | EventKit's four values map onto our two: `busy`/`unavailable` → `.busy`, `free` → `.free`, `tentative` → `.busy`. Mapped **down**, never dropped (spec 3.10) |
| `status` | `providerMetadata.status` | The `events.status` column has existed since `v001`, hardcoded to `'confirmed'`. It stops being hardcoded here |
| `alarms` | `reminders` | **Display only.** See 3C.7 |
| recurrence rules | `recurrence` | See 3C.3 |
| `attendees` / `organizer` | `attendees` | Read-only attribution. See 3C.5 |
| `lastModified` | `providerMetadata.providerVersion` | |
| everything else | `providerMetadata.providerRawFields` | See 3C.6 |

Every mapping is round-trip tested: device → local → device produces an equivalent event. The
reverse direction has no writer until 3D, so 3C tests it as a pure function against the value
type rather than against `EKEvent`.

---

## 3C.3 Recurrence

Better Calendar's `RecurrenceRule` and EventKit's overlap but are not the same, and spec 3.13 is
emphatic that the gap be handled explicitly rather than discovered in the field.

**Expressible**, and translated: daily, weekly, monthly by day-of-month, monthly by
weekday-ordinal, and yearly, each with an interval, a weekday set, and an end condition of never
/ after N / until a date. This is exactly the set Phase 2's engine supports, and
`RecurrenceExpander` already produces the same occurrence set for it.

**Not expressible**, and therefore *not translated*:

* An event carrying **more than one** recurrence rule. Better Calendar models one. Flattening two
  rules into one would corrupt the user's series on the first write-back, and truncating to the
  first would silently drop occurrences the user can see in Apple Calendar.
* Rules using set-positions, months-of-the-year lists, weeks-of-the-year, or days-of-the-year.

Such an event is mirrored **with its `recurrence` left `nil` and its raw rules preserved**, and
the row is marked `providerMetadata.hasUnrepresentableRecurrence`. What that marking buys:

* The event still appears, on its own start date, with a badge saying its repeat pattern is not
  shown here — visible incompleteness rather than invisible wrongness.
* It is **read-only at the model layer**: `EventMutationUseCases` refuses to edit it, with its
  own `CapabilityViolation` reason, so no local edit can be built on a series we cannot express.
  A partial rule written back is how a user's series gets destroyed, and the gate is what makes
  that unreachable rather than merely unlikely.

**Detached occurrences** map onto Phase 2's existing `RecurrenceException` +
replacement-event model — the same `(recurrenceMasterID, originalStart)` identity from §2.3. A
detached device occurrence becomes a replacement event carrying its own provider identity, plus a
`.modified` exception on the master. This is the model Phase 2 built and it fits without
alteration.

A series' master must be mirrored before its detachments, or a detachment has no master to point
at; the pass orders its output accordingly.

---

## 3C.4 Time zones, all-day, and floating

The Phase 0 §0.9 rules are unchanged and now have to survive a round trip through a system store.

* A **timed** event stores a UTC instant plus the original IANA zone identifier. EventKit's
  per-event time zone supplies that identifier.
* A device event with **no time zone is floating**, and maps to `.floating` — not to a timed
  event pinned to whatever zone the device happens to be in. Phase 1's schema already carries
  this case; this is the first producer of it from outside.
* An **all-day** event compares and stores on local calendar-date components, never UTC midnight.
  A mirrored all-day event must not shift by a day when the device time zone changes.
* An event near a DST transition retains its intended local time on both sides.

The existing `TimeZoneMatrixTests` cases are extended to mirrored events rather than duplicated.

---

## 3C.5 Attendees, organizer, and status

EventKit exposes attendees and the organizer as **read-only**: there is no API to add an attendee
to an event. Better Calendar must therefore never present an "add guest" affordance in Phase 3 —
invitations are Phase 11.

```text
EventAttendee
- id: UUID
- name: String?
- email: String?
- participationStatus: pending | accepted | declined | tentative | delegated | unknown
- role: required | optional | chair | nonParticipant | unknown
- isOrganizer: Bool
- isCurrentUser: Bool
- sortOrder: Int
```

Stored in a new `event_attendees` table, not stuffed into `notes`.

### The exclusions this makes possible

ADR 0002 kept `FreeBusy.Query.includeTentative` as a documented no-op and recorded that "declined"
could not be implemented, because Phase 2 had no attendee model. Its revisit trigger was this
phase. Both are implemented here, and **ADR 0002 is updated rather than left stale**:

* An event the current user has **declined** is excluded from free/busy. They are not busy at a
  meeting they said no to.
* A **cancelled** event is excluded from conflict detection and free/busy, but is still
  displayed, with its status shown. It is information, not a commitment.
* `includeTentative` stops being a no-op: when false, an event whose status is `tentative` or
  whose current-user participation is `tentative` no longer contributes busy time.

### Privacy

Attendee names and email addresses are personal data belonging to third parties, and are subject
to the same rule as event content: never logged, never in analytics, never in a diagnostic
string. `PrivacyLog`'s `StaticString` design makes the accidental case impossible — no escape
hatch is added here, and no attendee field enters the FTS index.

---

## 3C.6 Preserving what we do not model

Spec 3.17 and BC-EK-017. Phase 1 already preserves unmapped ICS properties in
`rawICSProperties` so export is non-destructive; the same principle extends to the device.

* Fields Better Calendar does not model — structured location, conference and video-call data,
  geolocation, per-account custom properties — are captured into
  `providerMetadata.providerRawFields` as JSON and never dropped.
* The failure this prevents is the one users notice immediately and never forgive: **a
  title-only edit stripping the Google Meet link off a meeting.**
* 3C is the preservation half. Spec 3.17's other requirement — that write-back be a field-level
  patch against a freshly fetched event rather than a whole-object save — is 3D's, and it is the
  half that makes the preserved payload actually survive. A test in 3C asserts the payload is
  carried on the row and through persistence; the round trip closes in 3D.
* `rawICSProperties` is untouched and stays the ICS channel. Two providers, two payloads, no
  shared bucket to disagree over.

---

## 3C.7 Alarms and the double-notification rule

**Already built, as a Phase 3 prerequisite.** `LocalNotificationPlanner` excludes every calendar
whose `connectionMethod` is `.device` from its desired-notification set, and three tests pin it.

3C is the first phase where that guard has real events to exclude, so BC-EK-016 is re-asserted
against them rather than against a fixture shaped to look like one: mirror a device event with
two alarms, run the pass, and assert the request set contains **zero** requests for it — and that
turning the calendar off and on again leaves no orphans behind.

A device event's alarms are still mirrored into `reminders`, because the detail view should show
what the user will be alerted about. They are display state. The system owns delivery, and from
3D an edit to them is written back as an alarm change rather than taken over.

---

## 3C.8 The mirror pass

`DeviceEventMirror.plan(...)` is pure, in the shape `DeviceCalendarMirror` established in 3B: it
takes fetched device events plus the existing local rows and returns `EntityChange`s, journal
entries and tombstones, which the store applies through the same atomic `EngineTransaction` path
as a user edit.

```text
1. Determine the window: the visible range plus a prefetch margin.
2. Fetch device events in that window, for the mirrored calendars that are
   selected, available, and whose access still permits reading.
3. Load mirrored local rows in the same window for the same calendars.
4. Match on provider identifier, falling back to the external identifier.
5. Classify:
     device-only            → insert
     both, device newer     → update
     both, equal            → no-op
     local-only, mirrored   → the device deleted it: remove the row, write a tombstone
     local-only, Better-owned → untouched; not our business
6. Emit one transaction, journalled with source: .reconciliation.
```

### The bounded-window rule

**Never infer a deletion from an event's absence outside the queried range.** A mirrored row is
deleted only when it was inside the fetched window *and* its calendar was included in the fetch.
Spec 3.24 states this as the way mirrors lose data, and it is the single most dangerous line in
this phase: a window computed slightly wrong turns into silent deletion of events the user still
has.

An external deletion writes a tombstone with `deletedBy: .providerDeletion` — a new cause — so
the journal distinguishes "the user deleted this here" from "it went away out there", and so the
existing resurrection guard applies to it.

### Idempotence

Running the pass twice produces one result, and a pass over an unchanged device produces an empty
transaction. Tested exactly as 3B's is.

### What 3C deliberately does not do

* It does not observe `EKEventStoreChanged`, coalesce bursts, or persist a per-calendar
  reconciliation window. That is 3E, and doing it here would mean shipping the trigger before the
  conflict handling that makes reacting to it safe.
* It does not resolve conflicts, because until 3D there is no local edit to a mirrored event that
  could conflict with anything.

---

## 3C.9 Surfaces

| Screen | ID | This phase |
|---|---|---|
| Event Detail | `EVT-DETAIL-01` | Owning **account and calendar** (BC-EK-018); read-only state stated *before* the user attempts an edit; event status when it is not plain confirmed; the attendee list with participation status and who organised it; a badge when the repeat pattern is not representable |
| Full Event Editor | `EVT-EDIT-01` | Unchanged from 3B. A mirrored event that cannot be edited does not open the editor at all, rather than opening it and refusing to save |

Spec 3.34: a user with a work Exchange calendar and a personal iCloud calendar must never have to
guess which one an event is on before editing it — and if the event is read-only, the detail view
says so before the attempt, not after.

---

## 3C.10 Migration `v020`

Following the Phase 2 §2.17 framework: numbered, forward-only, transactional, checksummed, and
tested against fixture databases from every previously released version.

```sql
CREATE TABLE event_attendees (
    id TEXT PRIMARY KEY NOT NULL,
    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    name TEXT,
    email TEXT,
    participation_status TEXT NOT NULL DEFAULT 'unknown',
    role TEXT NOT NULL DEFAULT 'unknown',
    is_organizer INTEGER NOT NULL DEFAULT 0,
    is_current_user INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX event_attendees_event_idx ON event_attendees(event_id);

ALTER TABLE events ADD COLUMN provider_external_id TEXT;
ALTER TABLE events ADD COLUMN provider_raw_fields TEXT;
ALTER TABLE events ADD COLUMN has_unrepresentable_recurrence INTEGER NOT NULL DEFAULT 0;
CREATE INDEX events_provider_external_idx ON events(provider_external_id)
    WHERE provider_external_id IS NOT NULL;
```

Two columns spec 3L expected are **not** added, because they already exist:

* The last-modified value for concurrency is `events.provider_version`, which has been there
  since `v001` and is exactly what spec 3.12 maps `lastModified` onto.
* `events.status` has been there since `v001` too, written as the literal `'confirmed'` for every
  row. It stops being hardcoded rather than being added — the same shape as the `v018` calendar
  work.

`change_journal.source` needs no migration: `JournalSource.reconciliation` exists and the column
carries no `CHECK`. `deleted_objects.deleted_by` likewise carries no `CHECK`, so
`TombstoneCause.providerDeletion` is additive. ADR 0003's deferred table rebuild concerns the
`operation` values and stays deferred.

---

## 3C.11 Test matrix

Runs on the macOS destination against `FakeEventKitStore`.

**Mapping**
* Round trip for every field in 3C.2, including empty title, no location, no notes, no URL
* EventKit's four availability values map onto our two, downward, and none is dropped
* A cancelled event maps to `.cancelled` and still produces a row
* An event on a calendar that is not mirrored is skipped rather than orphaned

**Time**
* A floating device event maps to `.floating`, not to a timed event in the current zone
* An all-day mirrored event does not shift across a device time-zone change
* An event near a DST boundary keeps its intended local time on both sides

**Recurrence**
* A weekly series expands to the same occurrences the device reports over a two-year window
* Each expressible frequency translates and expands correctly
* A multi-rule event is mirrored with `recurrence == nil`, its raw rules preserved, and marked
* A set-position rule is mirrored the same way
* An event so marked is refused by the mutation layer, with its own violation reason
* A detached occurrence becomes a replacement event plus a `.modified` exception on the master
* A master is always ordered before its detachments in the emitted transaction

**Attendees and exclusions**
* Attendees, roles, participation and the organizer round-trip through SQLite
* An event the current user declined contributes no busy time
* A cancelled event contributes no busy time and raises no conflict, but is still returned for
  display
* `includeTentative == false` excludes tentative events; `true` includes them

**The pass**
* An external create appears; an external update updates in place with the same row id
* An external delete inside the window removes the row and writes a `providerDeletion` tombstone
* An event outside the fetched window is never inferred to be deleted
* A calendar excluded from the fetch never has its events deleted
* Running the pass twice changes nothing the second time
* A Better Calendar-owned event on a local calendar is never touched by any pass

**Notifications**
* A mirrored event with two alarms produces zero local notification requests (BC-EK-016)
* A local event's notifications are unaffected by the presence of mirrored events

**Persistence**
* A mirrored event round-trips with provider identity, raw payload, status and attendees intact
* `v020` is proven against fixture databases from every released schema version

---

## 3C.12 Milestones

| Milestone | Contents |
|---|---|
| **3C-M1** | The model and the schema: attendees, status, provider identity fields, the unrepresentable-recurrence marker, migration `v020`, repository persistence. **Landed.** |
| **3C-M2** | The mapping layer: `DeviceEvent` and friends, `DeviceEventMapper`, recurrence translation, time semantics. **Landed.** |
| **3C-M3** | The seam and the pass: `events(in:calendarIdentifiers:)`, `DeviceEventMirror`, store wiring. **Landed.** |
| **3C-M4** | The consequences: free/busy and conflict exclusions, `EVT-DETAIL-01`, the notification proof, ADR updates. **Landed.** |

Four decisions this phase made that the specification above leaves open, all recorded in ADR 0008
because each one is expensive to change once it is on disk:

* **Local ids are derived from provider identity** (UUIDv5 over the EventKit identifier), not
  minted. That is what makes the pass idempotent, the mirror reconstructible, and the
  resurrection guard actually able to recognise a re-reported event.
* **The seam returns a series' master plus its detachments**, never EventKit's expanded
  occurrences — the collapsing needs an `EKEventStore` and so belongs on the EventKit side, and
  mirroring the expansion would discard the rule.
* **The device wins by content, not by timestamp.** `providerVersion` is carried for Phase 3D's
  concurrency check, but the change detector is a field comparison, which is what makes
  idempotence structural and a stray local edit self-correcting.
* **A row is deleted only when its *own start* is inside the fetched window** — the strict
  reading of §3C.8's bounded-window rule, chosen so the failure mode is a stale row a wider
  window cleans up rather than a deleted calendar.

The signature named in §3C.0 as `events(in:calendarIDs:)` shipped as
`events(in:calendarIdentifiers:)`, and is `async`: it takes the *provider's* calendar identifiers
rather than local ids, and spec 3.27 requires that rendering never block on it.

## 3C.13 Exit criteria

**Every criterion below is met.** Phase 3C is complete when:

* An event created in Apple Calendar appears in Better Calendar, on the right calendar, at the
  right time, in every view — Day, Week, Month, Agenda, Search — with no screen knowing it came
  from EventKit
* A recurring series expands to the same occurrence set the device reports, and a series that
  cannot be expressed is visibly marked and refused for editing rather than approximated
* An all-day or floating mirrored event does not move when the device time zone changes
* An external deletion inside the fetched window removes the event; one outside it never does
* A mirrored event produces no local notification
* Every event's owning account and calendar is visible in its detail view, and a read-only event
  says so before the user tries to edit it
* Declined and cancelled events no longer count as busy, and ADR 0002 says so
* Nothing in this phase writes to EventKit
* Every Phase 1, 2, 3A and 3B test passes unchanged, and `v020` is proven against fixtures from
  every released schema version
