# ADR 0005 — The default calendar stays a flag on the calendar row (spec 3.9)

- **Status:** Accepted
- **Date:** 2026-09-02
- **Scope:** Phase 3 prerequisites
- **Relates to:** `Instructions/phase3_specification.md` §3.9 (BC-EK-019),
  `Better Calendar/Data/LocalCalendarStore.swift` (`defaultCalendarID`),
  `Better Calendar/Data/SQLiteCalendarRepository.swift` (`calendars_one_default_idx`)

## Context

Spec 3.9 requires the default destination calendar to span all writable calendars, local and
device. Writing that section surfaced a modelling question that had to be settled before Phase 3
mirrors its first device calendar.

There is no `AppSettings.defaultCalendarID`. The default is a flag on the calendar row —
`BetterCalendar.isDefault` — surfaced as a computed property:

```swift
var defaultCalendarID: UUID? {
    calendars.first(where: \.isDefault)?.id ?? calendars.first?.id
}
```

and enforced in SQLite by a partial unique index created in `v001`:

```sql
CREATE UNIQUE INDEX calendars_one_default_idx ON calendars(is_default)
WHERE is_default = 1 AND deleted_at IS NULL
```

Once device calendars are mirrored as `calendars` rows, making one of them the default means
setting a Better Calendar flag on a row that mirrors a system object. The question is whether
that flag belongs there at all.

**Option A — keep `isDefault` on the row**, treating it as strictly local-only mirror state.
**Option B — move the default to `AppSettings` as an explicit calendar id**, separating an app
preference from calendar identity.

## Decision

Keep `isDefault` on the calendar row (Option A), and treat it as **local-only mirror state that
is never written back to a provider**.

The mirror already holds Better Calendar-owned state that has no provider counterpart —
`isVisible` is exactly the same kind of thing, and spec 3.8 makes display selection explicitly
local ("this is display state, not data state"). A default-destination flag is the same category.
Option B would require migrating the existing flag, dropping a unique index that has enforced the
"only one default" invariant since `v001`, and rewriting `defaultCalendarID` and its five call
sites — real churn, to move one boolean from a place where the database already guarantees its
invariant to a place where nothing would.

The rule this imposes on Phase 3's adapter: **`isDefault` is never included in a write-back
patch.** Spec 3.17 already requires write-back to be a field-level patch computed from the
journal's `FieldDiff` rather than a whole-object save, so a flag that no provider field maps to is
excluded by construction — but it must stay excluded deliberately, not accidentally.

## Consequences

- No migration, no index change, no change to `defaultCalendarID` or its callers.
- The `calendars_one_default_idx` invariant continues to hold across local and device calendars
  alike: exactly one default, enforced by the database rather than by application code.
- Spec 3.9's fallback rules operate on calendar rows, which is where writability now lives
  (`allowsEventCreation`, see [ADR 0004](0004-calendar-provider-identity.md)) — so "fall back to a
  writable calendar" is answerable without a second lookup.
- A device calendar that becomes unwritable while it is the default needs the fallback in 3.9;
  that logic is Phase 3 work and is not implemented here.

## Revisit trigger

Revisit if per-device defaults are ever needed — a user wanting a different default calendar on
iPhone than on Mac. That is a Phase 4 cloud-sync question (`isDefault` would then be device-scoped
state that must *not* sync, while the rest of the calendar row does), and it is the one scenario
where the row flag becomes genuinely wrong rather than merely unfashionable.
