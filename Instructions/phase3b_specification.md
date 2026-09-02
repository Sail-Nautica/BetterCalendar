# Better Calendar: Detailed Phase 3B Specification

Phase 3B is **calendar identity and ownership** — sections 3.8 and 3.9 of
`Instructions/phase3_specification.md`, plus the half of 3.6, 3.7 and 3.10 that the prerequisites
could only build the *types* for. It is where the calendars on the user's device first appear
inside Better Calendar.

It stops there, deliberately. No event is read, mirrored, or written in this phase. A calendar
list that is wrong is a visible annoyance; an event mirror built on a wrong calendar list is data
damage, and separating them means the first can be found and fixed before the second exists.

* **Phase 3 prerequisites** gave `BetterCalendar` provider identity, connection method, and
  capabilities — all inert, because nothing produced them.
* **Phase 3A** gave the app an authorization model, a primer, and the `CalendarAccessAuthorizing`
  seam. It grants access and lists nothing.
* **Phase 3B** (this document) makes those two real: it discovers the device's calendars, mirrors
  them as rows carrying the identity the prerequisites defined, and lets the user choose which to
  show and which to write to.
* **Phase 3C** reads their events.

---

## 3B.0 Scope

### Included

* `DeviceCalendar`, `DeviceCalendarSource`, `DeviceCalendarType` — Better Calendar's own value
  types for what EventKit reports
* `EventKitStore`, refining 3A's `CalendarAccessAuthorizing` with calendar enumeration, and the
  EventKit translation behind it
* `FakeEventKitStore`, extending 3A's `FakeCalendarAuthorization`
* Extending `EventProvider` so a source can be attributed honestly rather than approximately
* The discovery pass: a pure planner that diffs device calendars against mirrored rows and
  produces `EntityChange`s applied through the existing atomic write path
* Calendar availability — a calendar that disappears from EventKit is marked unavailable, never
  purged — and the schema to store it
* Per-calendar display selection, with defaults that do not require the user to answer a question
  before seeing their calendar
* Device calendars as read-only *records*: not renameable, recolourable, or deletable here
* Rendering a provider's exact colour, which `CalendarStyle`'s closed six-token enum cannot do
* The default destination calendar spanning all writable calendars, and its fallback when the
  chosen one stops being writable
* `SRC-LIST-01`, and the `CAL-MGR-01` / `EVT-EDIT-01` / `SET-01` extensions that reach it

### Excluded

* Reading, mirroring, or expanding device *events* — 3C
* Writing anything back to EventKit — 3D. **Nothing in this phase mutates the device.**
* Change observation and reconciliation — 3E. Discovery in this phase runs on explicit triggers,
  not on `EKEventStoreChanged`
* The duplicate-connection prompt (`SRC-CONN-01`) — 3F. Discovery records the identity that rule
  needs; the detection and the prompt come later
* Event-level attribution in the detail view (BC-EK-018) — it needs mirrored events, so 3C
* Reminders — 3G

### Requirement coverage

| ID | Statement | 3B delivers |
|---|---|---|
| BC-EK-004 | Every EventKit calendar on the device is listed, grouped by its owning account | Fully |
| BC-EK-005 | Toggling a device calendar off removes its events from every view without deleting them | The toggle, the persistence, and the guarantee that nothing is deleted. "Its events" disappear vacuously until 3C mirrors any — re-asserted there against real ones |
| BC-EK-019 | The user's chosen default destination calendar is preselected by Quick Add and the editor | Fully, including the fallback when it stops being writable |
| BC-EK-003 | Write-only access allows creating events and never claims to display device events | The listing half: device calendars appear as write-only destinations with no event display |
| BC-EK-010 | A read-only calendar rejects edits at the model layer, not only in the UI | Already enforced by the prerequisites. 3B is the first phase that produces a genuinely read-only calendar for it to reject |
| BC-EK-022 | Revoking calendar permission degrades the app without data loss | Extended: mirrored calendar rows are retained and hidden on access loss, and reconnected by provider identity on re-grant |
| BC-EK-024 | The mapping layer runs in CI against a fake event store | The calendar-mapping surface |

---

## 3B.1 The device value types

Three types, in `Domain/`, with no EventKit import — so the whole translation table below is
unit-testable with no device.

```text
DeviceCalendarSource
- identifier: String        // EKSource.sourceIdentifier
- title: String             // "iCloud", "Gmail", "Exchange"
- provider: EventProvider   // derived, see 3B.2

DeviceCalendarType          // EKCalendarType, in our own words
- local | calDAV | exchange | subscription | birthday

DeviceCalendar
- identifier: String        // EKCalendar.calendarIdentifier
- source: DeviceCalendarSource
- title: String
- type: DeviceCalendarType
- colorHex: String?
- isImmutable: Bool
- isSubscribed: Bool
- allowsContentModifications: Bool
- allowedAvailabilities: [EventAvailability]
```

`isSubscribed` is carried separately from `type` because EventKit documents that "CalDAV
subscribed calendars have type EKCalendarTypeCalDAV with isSubscribed = YES" — a subscribed
holiday feed inside an iCloud account never reports `.subscription`, so deriving ambience from
`type` alone would default it to visible.

`supportsRecurrence` and `supportsReminders` have no EventKit counterpart and are derived rather
than reported: recurrence is assumed for every calendar (a calendar that refuses one has to fail
the write in 3D and be classified there), and alarm support follows writability.

`DeviceCalendar` carries its own `source` rather than the protocol exposing a separate
`sources()`. Spec 3.2 sketches both; in 3B every consumer — grouping, attribution, the mirror's
matching key — wants the source *of a calendar*, and a source with no calendars has nothing to
list or toggle. `sources()` arrives in 3F, where the duplicate-connection rule needs to compare
accounts that may have no calendars in common.

## 3B.2 Attributing a source to a provider

Spec 3.6 makes `provider` mean *who owns the data*. With `EventProvider` limited to
`betterCalendar / google / apple / university`, an Exchange account or an "On My iPhone" calendar
has no honest answer, so the enum gains four cases:

```text
EventProvider (extended)
- betterCalendar   // ours
- google
- apple            // iCloud, and Apple-provided calendars such as Birthdays
- university       // U-M (Phase 8)
- exchange         // NEW
- deviceLocal      // NEW — EKSourceType.local, "On My iPhone"; not the same as ours
- subscribed       // NEW — EKSourceType.subscribed, read-only feeds
- otherAccount     // NEW — a CalDAV or other account we cannot attribute more precisely
```

| `EKSourceType` | `EventProvider` |
|---|---|
| `.local` | `deviceLocal` |
| `.exchange` | `exchange` |
| `.subscribed` | `subscribed` |
| `.birthdays` | `apple` |
| `.mobileMe` | `apple` |
| `.calDAV` | `google` when the account identity is recognisably Google, `apple` when it is iCloud, otherwise `otherAccount` |

`deviceLocal` is a separate case from `betterCalendar` on purpose. EventKit's "local" source is
the device's own calendar store, which Better Calendar reaches through EventKit and does not own;
ours is reached through no provider at all. Collapsing them would make `connectionMethod` the only
thing distinguishing a row we own from one we mirror, and that is exactly the conflation spec 3.6
warns against.

The Google heuristic is deliberately narrow — a source is Google only when its identity says so,
never by elimination. A calendar wrongly attributed to `otherAccount` is a cosmetic grouping
error; one wrongly attributed to `google` becomes a false match in Phase 3F's duplicate-connection
rule, which is a data decision.

`EventProvider` has a hand-written `databaseValue` mapping distinct from its `Codable` raw value,
and `init(databaseValue:)` already falls back to `.betterCalendar` for anything it does not
recognise — so the new cases need new database strings and no migration.

## 3B.3 The mirror: what discovery writes

Discovery is a **pure planner** — `DeviceCalendarMirror.plan(devices:existing:now:)` — that
returns `EntityChange`s, exactly as `EventMutationUseCases` does for user edits. It performs no
I/O, so every rule below is a unit test, and its output goes through the same atomic
`EngineTransaction` path as everything else.

### Matching

A mirrored row and a device calendar are the same calendar when the row has
`connectionMethod == .device` and its `(providerAccountID, providerCalendarID)` equals the
device calendar's `(source.identifier, identifier)`. That pair is what the `v018` partial index
on `(provider, provider_account_id, provider_calendar_id)` exists to serve.

Identity is never inferred from the calendar's *name*. Two accounts each having a calendar called
"Work" is ordinary, and a renamed calendar is still the same calendar.

### Classification

| Case | Action |
|---|---|
| Device calendar with no matching row | Insert a mirrored row |
| Both, provider-owned fields differ | Update those fields only |
| Both, nothing differs | No change — the pass is idempotent |
| Both, row was marked unavailable | Clear the unavailability; the row reconnects, it is not re-imported |
| Mirrored row with no matching device calendar | Mark unavailable. **Never delete** |
| Row with `connectionMethod == .local` | Untouched; not our business |

### Which fields the device owns, and which it does not

This split is the whole safety property of the mirror, and it is the same rule
[ADR 0005](../Documentation/Decisions/0005-default-calendar-stays-a-row-flag.md) established for
`isDefault`.

| Provider-owned — discovery overwrites | Local-only — discovery never touches |
|---|---|
| `name` | `isVisible` |
| `colorHex` / `colorName` | `isDefault` |
| `isReadOnly`, `capabilities` | `sortOrder` |
| `accountName`, `provider` | `id` (the local UUID, stable for the life of the mirror) |
| `isUnavailable` / `unavailableSince` | |

`BetterCalendar.timeZoneIdentifier` is not in either column: `EKCalendar` has no time zone
property — only `EKEvent` does — so a mirrored calendar's stays `nil`, and per-event zones are
Phase 3C's business.

A local-only field surviving a rename is what makes "I hid this calendar" stick when the account
renames it upstream. The `id` staying stable is what stops every event mirrored in 3C from being
reparented on the next discovery pass.

### Defaults on first discovery

Spec 3.8 says to "default display to the calendars the device itself considers active". **EventKit
exposes no such state** — the Calendar app's per-calendar checkboxes are not readable through any
API — so that instruction cannot be followed literally, and guessing is worse than a stated rule.
The rule is:

* Every discovered calendar is mirrored as a row.
* `isVisible` defaults to **true**, except for `type == .birthday` and `type == .subscription`,
  which default to **false** — the large ambient calendars spec 3.8 names.
* `isDefault` is never set by discovery. The user's existing default is untouched, and a device
  calendar becomes the default only when the user chooses it (3B.5).
* `sortOrder` continues after the highest existing value, so local calendars keep their order and
  new device calendars land underneath in a stable, per-account order.

Nothing is asked on first connect. Everything is one toggle away in `SRC-LIST-01`.

### Idempotence

Running the pass twice must produce no second change, and running it against an unchanged device
must produce an empty transaction — cheap enough to run on every foreground once 3E triggers it
that way. This is a test, not an aspiration.

## 3B.4 Availability

A calendar can vanish: an account is removed, a shared calendar is revoked, a subscription is
deleted on another device. Spec 3.8 requires that the row be **marked unavailable rather than
purged**, and spec 3.26 requires the same on access loss.

```text
BetterCalendar (extended)
- isUnavailable: Bool          // default false
- unavailableSince: Date?      // when the mirror last failed to find it
```

* An unavailable calendar is hidden from every calendar list and picker, and is not a valid
  destination. It is not deleted, and its `isVisible` and `isDefault` are preserved so a
  reconnection restores exactly what the user had.
* Reappearing clears both fields. Reconnection is by provider identity, which is what stops a
  removed-and-re-added account from producing a duplicate set of calendars (BC-EK-022).
* `unavailableSince` exists now, unused, because spec 3.26 requires a retention limit for hidden
  mirror rows and that limit is a Phase 3E decision with an ADR of its own. Adding the column now
  means 3E writes a policy rather than a migration — the same reasoning that made Phase 0 reserve
  `ProviderMetadata` and 3A define `ConnectionMethod.direct`.
* **Access loss is not disappearance.** When authorization drops below `fullAccess`, discovery
  does not run at all: rows keep their state and the UI explains the permission state instead.
  Marking every calendar unavailable because we may not look at them would destroy exactly the
  state a re-grant is supposed to restore.

Migration `v019_add_calendar_availability` adds both columns, `is_unavailable` NOT NULL DEFAULT 0
so every existing row backfills as available.

## 3B.5 Default destination calendar

Spec 3.9, with the modelling settled by ADR 0005: `isDefault` stays a flag on the row, local-only,
never written back to a provider.

* The Settings picker spans **all writable, available calendars**, local and device, grouped by
  account and labelled with it. A read-only or unavailable calendar is never offered.
* `defaultCalendarID` gains a fallback, applied in order:
  1. the flagged default, if it is writable and available;
  2. the device's own default calendar for new events, if it is mirrored, writable and available;
  3. the first writable, available calendar in sort order — which is a local calendar on any
     device where one exists, since local calendars sort first.

  It never falls back to a read-only calendar, and never to an unavailable one.
* The device's default-for-new-events identifier is **read live and held in memory only**, never
  persisted — it is the device's state, not ours, and a stored copy can disagree with the device
  the moment the user changes it. Same rule 3A applied to the authorization status, and the
  reason `EventKitStore` exposes it as a property rather than the mirror storing it.
* Quick Add and the full editor preselect the default and **always show which calendar and which
  account** they are about to write to. On a device with three accounts this is the difference
  between a work event landing in a personal calendar and not.

## 3B.6 Device calendars are read-only records

Spec 3.8: a device calendar cannot be renamed, recoloured, or deleted from Better Calendar. Those
operations exist in EventKit, but they mutate a shared system resource in ways a user does not
expect a third-party app to perform.

This is distinct from `isReadOnly`, which is about *events*:

| | Rename / recolour / delete the calendar | Create and edit events on it |
|---|---|---|
| Local calendar | Yes | Yes |
| Device calendar, writable | **No** — manage in Settings | Yes (3D) |
| Device calendar, read-only | **No** | No — rejected at the model layer |

`CAL-MGR-01` therefore shows device calendars without the edit affordances it gives local ones,
with a "Manage in Settings" pointer, while `SRC-LIST-01` owns the one control that *is* ours: the
visibility toggle.

## 3B.7 Colour

The prerequisites decided (ADR 0004) to store a provider's exact hex in `colorHex` and to leave
the six design tokens as tokens. Rendering is the half that remains: `Shared/CalendarStyle.swift`
maps a closed `CalendarColorName` enum to `Color` and has no way to render `#7B2D8E`.

* `BetterCalendar.displayColor` resolves `colorHex` when present and falls back to
  `colorName.color`, and every surface that renders a calendar colour uses it. A local calendar's
  rendering is byte-identical to before.
* A malformed or unparseable hex falls back to the token rather than to a default colour, so a
  provider sending something unexpected produces a wrong-but-legible calendar rather than an
  invisible one.
* Contrast: provider colours are arbitrary and some are illegible on one appearance or the other.
  Calendar colour is used as a fill behind text in Day/Week/Month chips, so the foreground colour
  is chosen per swatch from its relative luminance rather than fixed.

## 3B.8 Surfaces

| Screen | ID | This phase |
|---|---|---|
| Device calendars | `SRC-LIST-01` | New. Calendars grouped by account, visibility toggles, read-only and unavailable badges, per-account counts. Presents `SRC-PERM-01` on first open when `shouldPresentPrimerAutomatically` — the rule 3A specified and this screen finally consumes |
| Calendar Manager | `CAL-MGR-01` | Local and device calendars in one list; device entries without edit affordances, with an entry point to `SRC-LIST-01`. Replaces 3A's Device Calendars permission section, which becomes that entry point |
| Full Event Editor | `EVT-EDIT-01` | Calendar picker spanning writable local and device calendars, showing the account; read-only and unavailable calendars absent |
| Settings | `SET-01` | Default destination picker across all writable calendars, showing the account |

Every state in `SRC-LIST-01` needs copy, per UI/UX §9.2: no access yet, access denied or
restricted (reusing 3A's `DeviceCalendarAccessMessage`), write-only, connected with no calendars,
and one or more calendars unavailable.

## 3B.9 Test matrix

Runs on the macOS destination against `FakeEventKitStore`.

**Translation**
* Every `EKSourceType` maps to its specified `EventProvider`; an unrecognised CalDAV account maps
  to `otherAccount`, never to `google`
* A calendar's colour, read-only state, capabilities, and time zone survive translation
* An immutable or subscribed calendar translates to `capabilities.readOnly`

**First discovery**
* Every device calendar becomes a row, with account, provider identifier, and account name
* Birthday and subscription calendars are mirrored `isVisible == false`; everything else `true`
* No existing local calendar is modified, and no default is stolen
* Sort order continues after existing calendars rather than interleaving

**Subsequent discovery**
* An unchanged device produces an empty transaction
* Running the pass twice changes nothing the second time
* A renamed or recoloured device calendar updates in place — same row id, same `isVisible`,
  same `isDefault`, same `sortOrder`
* A calendar the user hid stays hidden across a discovery pass that renames it

**Availability**
* A calendar absent from the device is marked unavailable, not deleted, and keeps its local state
* A calendar that reappears is reconnected by provider identity — same row, no duplicate
* An unavailable calendar is excluded from destination pickers and from `defaultCalendarID`
* Discovery does not run below `fullAccess`, and access loss marks nothing unavailable

**Default destination**
* Each fallback step fires in order, and none of them selects a read-only or unavailable calendar
* A device calendar can be made the default, and that flag is never included in provider state

**Persistence**
* A mirrored calendar round-trips through SQLite with every provider field intact
* `is_unavailable` and `unavailable_since` survive the round trip, and `v019` backfills every
  fixture database from every released schema version

## 3B.10 Milestones

| Milestone | Contents |
|---|---|
| **3B-M1** | 3B.1, 3B.2, 3B.3, 3B.4, 3B.7 — the value types, the seam and its fake, the mirror planner, availability and its migration, colour rendering. No UI. |
| **3B-M2** | Store wiring: the discovery trigger, the `defaultCalendarID` fallback, and the in-memory device default. |
| **3B-M3** | `SRC-LIST-01`, the `CAL-MGR-01` rework, and the editor/Settings pickers. |

M1 is the whole of the risk. It is where a wrong matching key or an overwritten local field would
do damage, and it is entirely testable without a screen. **M1 has landed** — see ADR 0007 and
`DeviceCalendarDiscoveryTests`. Nothing it builds is wired into the running app yet: discovery is
a mechanism with no trigger, which is the same order Phase 2 used for the outbox and the Phase 3
prerequisites used for provider identity, and it is what keeps a half-built device-calendar list
off the calendar manager until M3 can render it properly.

## 3B.11 Exit criteria

Phase 3B is complete when:

* Every calendar on a device with several accounts is listed, grouped by account, with the correct
  colour, read-only badge, and account name
* Hiding a calendar persists, survives a discovery pass, and deletes nothing
* A discovery pass against an unchanged device produces no writes
* A removed account's calendars are marked unavailable, and re-adding it reconnects them without
  duplicating
* The default destination spans local and device calendars, is never a read-only or unavailable
  one, and is visible in the editor before the user saves
* No device calendar can be renamed, recoloured, or deleted from inside Better Calendar
* Nothing in this phase writes to EventKit
* Every Phase 1, 2, 3A test passes unchanged, and `v019` is proven against fixtures from every
  released schema version
