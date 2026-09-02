# ADR 0004 — Calendar provider identity: two axes, and an exact color (spec 3.6/3.7)

- **Status:** Accepted
- **Date:** 2026-09-02
- **Scope:** Phase 3 prerequisites
- **Relates to:** `Instructions/phase3_specification.md` §3.6, §3.7, §3.10,
  `Better Calendar/Domain/CalendarModels.swift`,
  `Better Calendar/Data/SQLiteCalendarRepository.swift` (`v018`)

## Context

`BetterCalendar` carried no provider identity at all: `id`, `name`, `colorName`, `isVisible`,
`isDefault`, `sortOrder`, `createdAt`, `updatedAt`, `versionNumber` and nothing else. The
`calendars` table has had `provider`, `provider_account_id`, `provider_calendar_id`,
`is_read_only`, and `time_zone_id` since `v001` — spec 0.7 specified them — but
`calendarArguments(_:)` hardcoded every one: provider always `betterCalendarLocal`, account
always `NULL`, `provider_calendar_id` set to the local UUID again, `is_read_only` always `0`.

Nothing in Phase 3 can start until a calendar can say which account owns it, whether it is
writable, and how Better Calendar reaches it.

Three sub-decisions had to be made together, because they interact.

**1. One provider axis, or two?** Phase 0 §0.6 listed `eventKit` as a future `provider` value
alongside `google`. But a Google calendar added in iOS Settings arrives through EventKit, and the
*same* calendar will arrive through the Google API in Phase 5. If "how we reach it" is encoded in
`provider`, that one calendar has two provider values and the duplicate-connection rule
(spec 3.28–3.29, BC-EK-020/021) has nothing stable to match on.

**2. Color.** `CalendarColorName` is a closed six-case enum of design tokens, mapped to hex by a
private extension in the repository and to `Color` by `Shared/CalendarStyle.swift`. Device
calendars carry arbitrary RGB that is not in that set.

**3. Read-only.** Spec 3.10 requires enforcement "at the model layer, not merely in the UI," but
a single boolean cannot express "writable, but this calendar refuses tentative availability" —
which EventKit does report.

## Decision

**Two orthogonal axes.** `provider: EventProvider` answers *who owns the data*;
`connectionMethod: ConnectionMethod` (`local` / `device` / `direct`) answers *how we reach it*.
`EventProvider` is unchanged — notably it already persists `.apple` as the string `"eventKit"`,
which is now the ownership answer, not the transport answer. `direct` is defined but never
produced in Phase 3, so Phase 5 inherits the column instead of migrating it.

**Color: store the provider's exact hex; keep tokens as tokens.** `colorHex: String?` is non-nil
only when the color is not one of the six tokens. The writer stores `colorHex ?? colorName.hexValue`
into the existing `color_hex` column; the reader maps a hex that matches a token back to that
token with `colorHex == nil`, and keeps anything else verbatim. Local calendars therefore round-
trip byte-identically to before this change, and no "nearest token" distance function is needed.

**Read-only is two things.** `isReadOnly: Bool` is the coarse flag the UI shows;
`capabilities: CalendarCapabilities` is the fine-grained truth a provider reports, stored as one
JSON blob (`capabilities_json`) rather than seven columns, because the set will grow as adapters
are added and widening JSON needs no migration. `allowsEventEditing` / `allowsEventCreation`
combine them, and are the only questions the mutation layer asks.

Every new field is appended after `versionNumber` and defaulted, so all four existing
construction sites compile unchanged, and `BetterCalendar`'s hand-written `Codable` conformance
decodes a pre-Phase-3 calendar as local, writable, and Better Calendar-owned — the same tolerance
the `sortOrder` and `versionNumber` additions already established.

## Consequences

- `SQLiteCalendarRepository` stops hardcoding provider columns; `v018` adds `account_name`,
  `connection_method`, and `capabilities_json`, plus a partial index on
  `(provider, provider_account_id, provider_calendar_id)` for the duplicate-connection lookup.
- One asymmetry had to be handled explicitly: the writer defaults `provider_calendar_id` to the
  local UUID (as it always has), so the reader treats "equal to the row's own id" as *no* provider
  identity and returns `nil`. Without this, a local calendar no longer round-trips to an equal
  value, which `EngineTransactionTests` and `SQLiteCalendarRepositoryTests` both caught.
- `MigrationTests` now asserts, for every released schema version, that a migrated calendar comes
  back local, writable, and token-colored — no upgrade path can strand a user's own calendar in a
  read-only or unknown-transport state.
- Phase 5 can record a direct Google connection without a schema change, and the duplicate-
  connection rule has a stable key to match on.

## Revisit trigger

Revisit the color decision when a device calendar's exact hex first reaches a rendering surface:
`Shared/CalendarStyle.swift` still maps only the closed token enum, so `colorHex` is stored and
round-tripped but not yet painted. That is deliberate — Phase 3's calendar-list work is where a
contrast check in both appearances belongs, not here. Revisit the two-axis model if a provider
ever needs more than one transport simultaneously, which the current design forbids by construction.
