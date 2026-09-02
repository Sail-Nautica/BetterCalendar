# ADR 0006 — Calendar access: request full only, cache nothing, split the seam (spec 3.3–3.5)

- **Status:** Accepted
- **Date:** 2026-09-02
- **Scope:** Phase 3A
- **Relates to:** `Instructions/phase3a_specification.md`, `Instructions/phase3_specification.md`
  §3.2, §3.3, §3.4, §3.5,
  `Better Calendar/Domain/CalendarAccess.swift`,
  `Better Calendar/Data/EventKit/`,
  `Better Calendar.xcodeproj/project.pbxproj`

## Context

Phase 3A builds the permission model that every later Phase 3 milestone passes through. Three
questions had to be settled before any of it could be written, and they interact enough that
deciding them separately would have produced an inconsistent answer.

**1. Which access level do we request, and which usage descriptions do we declare?** iOS 17 and
macOS 14 split calendar access into write-only and full. Spec 3.5 says to declare
`NSCalendarsFullAccessUsageDescription` "and, if write-only is ever requested,
`NSCalendarsWriteOnlyAccessUsageDescription`" — leaving open whether to declare both defensively.
The `writeOnly` *status* is reachable regardless of what we request, because a user can choose
add-only access in Settings, so the app must handle a state it never asks for.

**2. Where does the authorization status live?** The app has a settings table, an
`@Observable` store, and a launch sequence that already reads everything it needs from disk. The
path of least resistance is to read the status once at launch and keep it.

**3. How much of spec 3.2's `EventKitStore` protocol does 3A implement?** That protocol spans
authorization, source and calendar enumeration, event fetching, saving, removal, and change
observation. Its non-authorization members need `DeviceCalendar`, `DeviceEvent`,
`DeviceEventReceipt` and `DeviceEditSpan` — value types that belong to Phase 3B and 3C.

## Decision

**1. Request full access only. Declare only the full-access usage description.**

Better Calendar is a calendar client whose entire purpose is displaying existing events, so
write-only is never the right thing to ask for. It follows that
`NSCalendarsWriteOnlyAccessUsageDescription` is *not* declared: a usage-description string is
required for the level an app requests, and declaring one for a level we never request puts a
promise in the Info.plist that the code does not keep.

The `writeOnly` status is still handled in full (spec 3.4, BC-EK-003), because handling a state
and requesting it are different things. `EventKitCalendarAuthorization.requestAccess(_:)`
therefore refuses a `.writeOnly` level and returns the current status rather than calling
`requestWriteOnlyAccessToEvents()` — which, without the matching usage description, terminates
the app. If a later phase needs that level, the string and the call arrive in the same change.

**2. The authorization status is read live and never persisted.**

There is no `AppSettings` field for it and no value that survives a launch. It is re-read when
the root view appears, on every transition to the active scene phase, and whenever a
device-calendar surface appears. `load()` performs no authorization read at all, so launch
touches nothing from EventKit — spec 3.18's "launch must not block on EventKit", applied one
phase early and for free.

Exactly one bit of the flow *is* persisted, because it is ours rather than the device's:
`AppSettings.hasSeenCalendarAccessPrimer`. It needs no migration — `application_settings` is a
key-value table and `upsertSettings` only ever deletes keys it knows about.

**3. The seam is split: `CalendarAccessAuthorizing` now, `EventKitStore` refining it in 3B.**

Phase 3A ships the two authorization members as their own protocol, with the real
`EventKitCalendarAuthorization` and a scriptable `FakeCalendarAuthorization` behind it. Phase 3B's
`EventKitStore` refines this protocol rather than restating it, so the seam widens without any
3A call site changing.

## Consequences

- A cached status cannot go stale, so the class of bug where an app confidently displays a
  calendar it can no longer read is unreachable rather than defended against. The cost is one
  cheap static call per foreground transition.
- `CalendarAccessStatus` is the app's own enum, not `EKAuthorizationStatus`. The domain layer and
  every view stay free of EventKit, and a second provider that reports authorization differently
  translates at the same boundary.
- `EventKitCalendarAuthorization` holds no `EKEventStore`; the instance a request needs is
  created inside the request and released with it. Every existing test can therefore construct a
  `BetterCalendarStore` with the default authorizer without touching the system event store.
  Phase 3C will need a long-lived `EKEventStore` for fetching, and that is where it should be
  introduced — not here, where it would only make launch heavier.
- The store, not the view, enforces both preconditions on reaching the system alert (the primer
  has been seen, and the device has not already answered). No future screen can bypass them by
  calling the store directly.
- Better Calendar cannot ever request write-only access without a matching change to the
  Info.plist keys, because the adapter refuses the level. That is deliberate coupling: the
  failure mode it prevents is a crash on a user's device.

## Revisit trigger

Revisit (1) if a use case appears for an install that only ever writes to the device — a
"send to my calendar" share extension, say — where full access would be more than the feature
needs and spec 3K's "request the narrowest access that delivers the feature" would point the
other way.

Revisit (2) if the per-foreground status read ever shows up in a launch or foreground profile,
which would mean EventKit's static status read has stopped being cheap.
