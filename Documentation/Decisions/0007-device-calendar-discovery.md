# ADR 0007 — Device-calendar discovery: provider taxonomy, matching key, and the seam's shape (spec 3.8)

- **Status:** Accepted
- **Date:** 2026-09-02
- **Scope:** Phase 3B, milestone M1
- **Relates to:** `Instructions/phase3b_specification.md`, `Instructions/phase3_specification.md`
  §3.2, §3.6, §3.8,
  `Better Calendar/Domain/DeviceCalendar.swift`,
  `Better Calendar/Domain/Engine/DeviceCalendarMirror.swift`,
  `Better Calendar/Data/EventKit/`

## Context

Phase 3B mirrors the device's calendars as `BetterCalendar` rows. Three questions had to be
answered before a single row could be written, and each one is expensive to change afterwards
because the answer ends up on disk.

**1. What is a device calendar's `provider`?** Spec 3.6 makes `provider` mean *who owns the data*
and lists "`google`, `apple`, `exchange`, `local`, `subscribed`, …" — but `EventProvider` shipped
with only `betterCalendar / google / apple / university`. An Exchange account and an "On My
iPhone" calendar had no honest value, and `provider` is the axis Phase 3F's duplicate-connection
rule matches on.

**2. What makes two calendars the same calendar?** The mirror has to recognise a row it wrote on
a previous pass. Get it wrong and either every pass duplicates the device, or two calendars
collapse into one.

**3. How much of spec 3.2's `EventKitStore` does 3B implement, and where does it live?** ADR 0006
left a single EventKit-importing file, `EventKitCalendarAuthorization`, named for the only thing
it then did.

## Decision

**1. Extend `EventProvider` by four, and attribute CalDAV narrowly.**

`exchange`, `deviceLocal`, `subscribed` and `otherAccount` join the enum. `EKSourceType` maps
onto them directly except for `.calDAV`, which is `google` only when the account identity is
recognisably Google, `apple` when it is recognisably iCloud, and `otherAccount` otherwise —
never by elimination. A calendar wrongly attributed to `otherAccount` is a cosmetic grouping
error; one wrongly attributed to `google` becomes a false match in 3F's duplicate-connection
rule, which is a data decision. The asymmetry is the whole argument.

`deviceLocal` is deliberately a separate case from `betterCalendar`. EventKit's "local" source is
the device's own calendar store — reached through EventKit, and not ours. Collapsing the two
would leave `connectionMethod` as the only thing distinguishing a row we own from one we mirror,
which is exactly the conflation spec 3.6 warns against.

No migration: `EventProvider` already has a hand-written `databaseValue` mapping whose
`init(databaseValue:)` falls back to `.betterCalendar` for anything unrecognised, so the four new
strings are additive.

**2. The matching key is `(providerAccountID, providerCalendarID)`, and never the name.**

Two accounts each having a calendar called "Work" is ordinary, and a renamed calendar is still the
same calendar — matching on the name produces a duplicate on every rename and a collision on
every multi-account device. The `v018` partial index on
`(provider, provider_account_id, provider_calendar_id)` exists to serve exactly this lookup.

The key carries a rule with it: **discovery overwrites provider-owned fields and never touches
local-only ones.** Name, colour, read-only state, capabilities, account and provider are the
device's; the row `id`, `isVisible`, `isDefault` and `sortOrder` are ours. This generalises
[ADR 0005](0005-default-calendar-stays-a-row-flag.md) from `isDefault` to the whole row. The
stable `id` is load-bearing beyond tidiness: Phase 3C hangs mirrored events off it, and
regenerating it would reparent all of them on the next pass.

A vanished calendar is *marked* unavailable, never deleted, and an already-marked one is not
re-marked — re-marking would rewrite `unavailableSince` on every pass, and that timestamp is what
Phase 3E's retention limit measures from.

**3. One adapter file, one protocol, and no members without consumers.**

`EventKitCalendarAuthorization` was renamed `EventKitDeviceStore` and grew `discoverCalendars()`,
rather than gaining an EventKit-importing sibling — spec 3.2's "the adapter is the only file in
the codebase that imports `EventKit`" stays literally true.

`EventKitStore` refines 3A's `CalendarAccessAuthorizing` rather than restating it, so no 3A call
site changed. It deviates from spec 3.2's sketch in two ways, both deliberate:

* **No `sources()`.** Every consumer in 3B wants the source *of a calendar*, which `DeviceCalendar`
  carries, and an account with no calendars has nothing to list or toggle. `sources()` arrives in
  3F, where the duplicate-connection rule compares accounts rather than calendars.
* **One `discoverCalendars()` returning a snapshot**, rather than separate calendar and
  default-calendar accessors. The real implementation needs a live `EKEventStore` for both
  answers and creating one is the expensive part; the protocol should not force it to make two.

## Consequences

- Discovery is a pure function — `DeviceCalendarMirror.plan(devices:existing:now:makeIdentifier:)`
  — with the clock and identifier generation injected, so every rule above is a deterministic
  test and the whole layer runs in CI with no device (BC-EK-024).
- Its output is `[EntityChange]`, so it flows through the same atomic `EngineTransaction` path as
  a user edit and inherits the journal, rollback and consistency guarantees Phase 2 built. There
  is no second write path for discovery.
- Idempotence became a design constraint rather than a nice property, and it forced one
  non-obvious fix: `CalendarColorName.hexValue` / `init?(hexValue:)` moved out of
  `SQLiteCalendarRepository`'s private extension into the domain, because the planner has to
  normalise a token-coloured device calendar exactly the way the repository does when it reads
  one back. Without that, a calendar coloured `#4F7DFF` would compare unequal to its own stored
  row on every pass and be rewritten forever.
- `CapabilityViolation` gained a third reason, `unavailable`. A calendar that is gone has not
  refused anything, and telling the user it is "read-only" would be false.
- `BetterCalendar.timeZoneIdentifier` stays `nil` for mirrored rows: `EKCalendar` has no time zone
  property, only `EKEvent` does.

## Revisit trigger

Revisit (1) if the Google heuristic proves too narrow on real devices — the symptom is Google
calendars grouped under "Other Account" — which would mean matching on the account's email
identity rather than the source title, and is better done with a real device in hand than
guessed at now.

Revisit (2) if a provider is ever found to recycle calendar identifiers across accounts, which
would make the key ambiguous and force the account's own identity into it more strongly.
