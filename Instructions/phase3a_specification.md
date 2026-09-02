# Better Calendar: Detailed Phase 3A Specification

Phase 3A is the **permission and capability model** — sections 3.3, 3.4 and 3.5 of
`Instructions/phase3_specification.md`, expanded into something implementable and testable.

It is the first slice of Phase 3 that ships code the user can see, and it is deliberately the
slice that touches no calendar data at all. Nothing here enumerates a source, mirrors an event,
or writes to `EKEventStore`. What it builds is the gate everything after it passes through: a
truthful model of what the device has permitted, a request flow the user understands before the
system alert appears, and a seam that lets every later phase run in CI without a device.

* **Phase 3 prerequisites** (landed, `f83be73`) gave calendars provider identity, connection
  method, capability enforcement, and the double-notification guard.
* **Phase 3A** (this document) gives the app an authorization model.
* **Phase 3B** discovers and lists device calendars. It is out of scope here, and the boundary
  is stated precisely in §3A.9.

---

## 3A.0 Scope

### Included

* `CalendarAccessLevel` and `CalendarAccessStatus` as domain types, with the whole of spec 3.4's
  behavior table derived from them as pure, testable values
* A pre-prompt explanation screen (`SRC-PERM-01`) that precedes the system alert
* The request flow: full access only, never on launch, never twice, never after a denial
* Live authorization re-checking on every foreground transition
* Per-state copy for every authorization state, including the two that most apps get wrong
  (`restricted`, which the user cannot fix, and `writeOnly`, which must never render as an empty
  calendar)
* A Settings deep link on the states where Settings can actually help, and on no others
* The calendar-manager entry point that triggers the flow
* `NSCalendarsFullAccessUsageDescription` and the macOS sandbox calendar entitlement, added as
  build settings
* The `CalendarAccessAuthorizing` seam plus a scriptable fake, so the flow runs in CI with no
  device, no account, and no event store

### Excluded

* Enumerating `EKSource`s or `EKCalendar`s, and creating mirrored `BetterCalendar` rows — 3B
* Reading, writing, or reconciling events — 3C, 3D, 3E
* `NSCalendarsWriteOnlyAccessUsageDescription` — see §3A.6, we never request that level
* `NSRemindersFullAccessUsageDescription` — Reminders is a separate, independently permissioned
  module (spec 3.31), and requesting it as a side effect of calendar access is explicitly
  forbidden by spec 3K
* EventKitUI (`EKCalendarChooser`, `EKEventEditViewController`) — spec 3.5 recommends against it
  for the whole phase, and 3A has no use for it

### Requirement coverage

| ID | Statement | 3A delivers |
|---|---|---|
| BC-EK-001 | User is shown a plain-language explanation before the system calendar prompt appears | Fully |
| BC-EK-002 | Denying calendar access leaves every Phase 1/2 local-calendar feature fully working | Fully |
| BC-EK-003 | Write-only access allows creating events and never claims to display device events | The "never claims" half. The "allows creating" half needs a device calendar to create on (3B/3D) |
| BC-EK-022 | Revoking calendar permission in Settings degrades the app without data loss or crash | Fully for the states 3A can produce. Re-checked in 3B once mirror rows exist and 3.26's retention policy has something to retain |
| BC-EK-024 | The entire mapping and reconciliation layer runs in CI against a fake event store | The authorization surface of that fake |

---

## 3A.1 The access model

Two enums, both in `Domain/`, both free of EventKit, SwiftUI and GRDB — the same rule the rest
of the domain layer follows, and the reason this model is unit-testable without a device.

```text
CalendarAccessLevel        // what we may ask for
- writeOnly
- full

CalendarAccessStatus       // what the device has answered
- notDetermined
- restricted
- denied
- writeOnly
- fullAccess
```

`CalendarAccessStatus` is the app's own vocabulary, not `EKAuthorizationStatus`. The translation
lives in the adapter, so a future EventKit change — or a second provider that reports
authorization differently — cannot reach the domain.

Four derived questions hang off the status, and **every** device-calendar surface asks one of
these rather than switching on the raw case. That is what keeps the spec 3.4 table in one place
instead of scattered across views:

| Property | True for |
|---|---|
| `canReadDeviceEvents` | `fullAccess` |
| `canCreateDeviceEvents` | `fullAccess`, `writeOnly` |
| `allowsInAppRequest` | `notDetermined` |
| `isResolvableInSettings` | `denied`, `writeOnly` |

`restricted` is deliberately absent from the last two rows. It is the state a managed device or
Screen Time produces, and it is not the user's choice to change — offering a Settings deep link
there sends the user to a switch that will not move.

---

## 3A.2 The request flow

```text
                    ┌─────────────────────────────────────────┐
User taps           │  CalendarAccessPrimerView SRC-PERM-01   │
"Connect Device  ──▶│  what we read · nothing leaves the      │
 Calendars"         │  device · revocable in Settings         │
                    └──────────┬───────────────┬──────────────┘
                     "Connect" │               │ "Not Now"
                               ▼               ▼
                  requestAccess(.full)   primer dismissed,
                               │         hasSeenCalendarAccessPrimer = true,
                               │         system prompt NOT burned
                               ▼
                    system alert (single use, ever)
                               │
              ┌────────────────┼─────────────────┐
              ▼                ▼                 ▼
          fullAccess        denied           writeOnly
```

The rules, each of which is a test in §3A.8:

1. **Full access is the only level ever requested.** Better Calendar is a calendar client; it
   must display existing events. Write-only is a state to handle, not a state to ask for. A
   consequence falls out of this in §3A.6: only one usage-description string is declared.
2. **Never on launch.** `load()` performs no authorization read and no request. The status is
   first read when the root view appears, which is a read, not a prompt.
3. **The primer always precedes the system alert.** The store's request path is unreachable
   except from the primer's Connect action. There is no code path from launch, from a tab
   change, or from the calendar manager appearing, to `requestAccess`.
4. **The system prompt is a single-use resource.** `requestDeviceCalendarAccess()` refuses to
   call through unless the status is `notDetermined`, and returns the current status instead.
   The refusal is in the store, not in the view, so no future screen can bypass it.
5. **Dismissing the primer does not burn the prompt.** "Not Now" records only
   `hasSeenCalendarAccessPrimer`, leaving the status `notDetermined` and the affordance
   available for whenever the user is ready.
6. **After a denial the app never re-prompts in-app.** The affordance changes from "Connect
   Device Calendars" to "Open Settings", and there is no third state where it changes back.

---

## 3A.3 Behavior in each authorization state

Spec 3.4's table, made exact. `DeviceCalendarAccessMessage.forStatus(_:)` is the single function
that produces it, and §3A.8 tests it case by case.

| Status | Title | Message | Action |
|---|---|---|---|
| `notDetermined` | Not Connected | Better Calendar can show the calendars already set up on this device — iCloud, Google, Exchange, and subscribed calendars — alongside your local ones. | Connect Device Calendars |
| `restricted` | Calendar Access Is Managed by This Device | A profile or Screen Time restriction controls calendar access, so it can't be granted here. Your local Better Calendar calendars are unaffected. | *none* |
| `denied` | Calendar Access Is Off | Better Calendar doesn't have permission to use this device's calendars. Your local calendars are unaffected. Turn access on in Settings to see the rest of your schedule here. | Open Settings |
| `writeOnly` | Add-Only Calendar Access | Better Calendar can add events to this device's calendars but can't read them, so device events aren't shown here. This is not an empty calendar. | Open Settings |
| `fullAccess` | Connected | Better Calendar has permission to use this device's calendars. Choosing which of them to show isn't available in this version. | *none* |

Four rules the table encodes, each of which exists because getting it wrong is a shipped bug:

* **`denied` is not a failure state.** Every Phase 1 and Phase 2 capability keeps working, and
  the copy says so rather than implying the app is broken (BC-EK-002).
* **`restricted` gets its own copy and no Settings link.** Telling a user on a managed device to
  "turn it on in Settings" is telling them to do something they cannot do.
* **`writeOnly` must never render as an empty calendar** (BC-EK-003). The one thing the copy has
  to say is that events exist and are not being shown — "This is not an empty calendar" is load-
  bearing, not filler.
* **`fullAccess` in 3A is honest about the boundary.** Access is granted and nothing is listed
  yet, because listing is 3B. The copy states that plainly instead of implying an empty device.

### Re-checking

Authorization is **read live and never cached across the process lifetime**. There is no
`AppSettings` field for it, and no in-memory value survives a launch. It is re-read:

* when the root view first appears,
* on every transition to `scenePhase == .active`, and
* whenever a device-calendar surface appears, which closes the gap between launch and the first
  time the user opens one.

A user can revoke access in Settings while the app is backgrounded — on iOS, that terminates the
app in many cases, but not all, and on macOS it does not — so the foreground read is what makes
BC-EK-022 true rather than hoped for. A downgrade changes displayed state and nothing else: it
never deletes, never mutates local data, and never surfaces an error alert.

---

## 3A.4 Persistence

One new persisted value:

```text
AppSettings.hasSeenCalendarAccessPrimer: Bool   // default false
```

stored as a single `application_settings` row under the key
`has_seen_calendar_access_primer`. **No schema migration is required** — settings are a
key-value table (spec 1.20's BC-SET-001 model), and `upsertSettings` already deletes rows for
keys that become unset rather than issuing a blanket delete, so an older build reading a newer
database is unaffected.

Deliberately *not* persisted:

* **The authorization status.** It is the device's answer, not ours, and a cached copy is how an
  app ends up confidently showing a calendar it can no longer read.
* **A "user denied us" flag.** `CalendarAccessStatus.denied` already says that, and a second
  source of truth for the same fact can disagree with the first.

---

## 3A.5 The authorization seam

Spec 3.2 defines an `EventKitStore` protocol spanning authorization, enumeration, fetching and
saving. 3A implements only the authorization members, as a protocol of their own:

```text
protocol CalendarAccessAuthorizing {
    var authorizationStatus: CalendarAccessStatus { get }
    func requestAccess(_ level: CalendarAccessLevel) async -> CalendarAccessStatus
}
```

3B's `EventKitStore` refines this protocol rather than restating it, so the seam widens without
the 3A call sites changing. Two implementations ship:

* **`EventKitCalendarAuthorization`** — the real one, and the only file in the codebase that
  imports EventKit (spec 3.2's rule). It translates `EKAuthorizationStatus` into
  `CalendarAccessStatus` and calls `requestFullAccessToEvents()`.

  It holds **no** `EKEventStore` instance. `EKEventStore.authorizationStatus(for:)` is a static
  read, and the instance needed to issue a request is created inside the request and released
  with it. Launch therefore instantiates nothing from EventKit, which is spec 3.18's "launch
  must not block on EventKit" applied one phase early — and it is why every existing test can
  construct a `BetterCalendarStore` with the default authorizer without touching the system
  event store.

* **`FakeCalendarAuthorization`** — scriptable status, scriptable grant result, and a request
  counter, so "granted → revoked → re-granted" is a deterministic test step (spec 3.36) and
  "we asked the system exactly once" is assertable. It ships in the app target next to the real
  one, following the `NoopNotificationScheduler` precedent, so previews and tests share it.

### Platform behavior

EventKit, `EKEventStore.authorizationStatus(for:)` and `requestFullAccessToEvents()` all exist on
macOS 14 and iOS 17, which are the project's deployment targets — so the adapter compiles
unguarded on both. The single platform difference in this phase is the Settings deep link
(§3A.7), and it is the only thing behind `#if canImport(UIKit)`.

---

## 3A.6 Entitlements and usage descriptions

The project generates its Info.plist (`GENERATE_INFOPLIST_FILE = YES`), so these are build
settings on the app target in **both** the Debug and Release configurations, not a checked-in
plist:

```text
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "Better Calendar shows the calendars already set up on this device — iCloud, Google, Exchange, and subscribed calendars — alongside your local ones, and adds the events you create to the calendar you choose. Your calendar data stays on this device."
ENABLE_RESOURCE_ACCESS_CALENDARS = YES
```

`ENABLE_RESOURCE_ACCESS_CALENDARS` is the modern spelling of the macOS sandbox entitlement
`com.apple.security.personal-information.calendars`; the target has `ENABLE_APP_SANDBOX = YES`
and already declares `ENABLE_USER_SELECTED_FILES = readonly` the same way, so no `.entitlements`
file is introduced. The whole test suite runs on the macOS destination on the development
machine, which is why this is not a hypothetical.

**`NSCalendarsWriteOnlyAccessUsageDescription` is deliberately not declared.** A usage-description
string is required for the level an app *requests*, and Better Calendar only ever requests full
access (§3A.2 rule 1). The `writeOnly` status remains reachable — a user can select add-only
access in Settings — and §3A.3 handles it, but handling a state is not requesting it. Declaring
a string for a level we never ask for would put a promise in the Info.plist that the code does
not keep. If a future phase ever requests write-only, that string is added with the request, not
before it.

The usage description states a genuine user benefit, per spec 3K. Generic boilerplate is a
common App Review rejection for calendar-access apps.

Per the project's standing rule, this pbxproj change carries **no** development team and **no**
bundle identifier; those stay in the local stash and out of git.

---

## 3A.7 Surfaces

### `SRC-PERM-01` · Calendar access primer

A sheet, presented only from the calendar manager's Connect action. Content, per spec 3.3:

* **What is read** — the calendars already on the device, named by the account types the user
  will recognize.
* **That nothing leaves the device** — true today with no caveat: there is no backend, no
  account, and no network call originating from this app (spec 3.0, 3K).
* **That access is revocable** — and where.
* **"Not Now" as a first-class choice**, weighted equally with Connect, not a dismissible
  afterthought.

It follows the design system already in use (UI/UX §6.2 tokens, §9.2 error-copy rules) and
introduces no new visual language.

### `CAL-MGR-01` (extended) · Device Calendars section

The calendar manager gains a "Device Calendars" section that replaces the Phase 1 footnote
("Local-only MVP. Connected accounts are intentionally not exposed in Phase 1.") — which this
phase makes untrue. It renders exactly the §3A.3 row for the current status: title, message, and
the one action that state permits.

This is the phase's only entry point into the flow. Spec 3.3's other trigger — "the first time
the user opens the device-calendars screen" — refers to `SRC-LIST-01`, which does not exist until
3B; the auto-presentation rule is specified here (`shouldPresentPrimerAutomatically` is
`notDetermined && !hasSeenCalendarAccessPrimer`) and consumed there.

### `AppRootView`

Adds the foreground re-check from §3A.3 alongside the existing time-zone refresh. No new
navigation, no new tab.

### Settings deep link

| Platform | Destination |
|---|---|
| iOS | `UIApplication.openSettingsURLString` — the app's own Settings page |
| macOS | `x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars` |

Offered only where `isResolvableInSettings` is true. On any platform where neither applies, the
action is not shown at all rather than shown and inert.

---

## 3A.8 Test matrix

All of it runs on the macOS destination against `FakeCalendarAuthorization`, with no device and
no system prompt.

**The state table (spec 3.4)**
* Each of the five statuses produces its specified `canReadDeviceEvents`,
  `canCreateDeviceEvents`, `allowsInAppRequest`, and `isResolvableInSettings`
* `restricted` offers no Settings action, and its copy does not mention Settings
* `writeOnly` reports "cannot read, can create", and its copy states that device events exist
  and are not shown (BC-EK-003)
* Every status produces non-empty title and message copy — no state falls through to a generic
  failure message

**The request flow (BC-EK-001)**
* Constructing the store and loading performs zero authorization requests
* The primer is what precedes a request: requesting is refused unless the primer has been seen
* "Not Now" leaves the status `notDetermined` and the request count at zero — the system prompt
  is not burned
* Granting records the result and updates the observable status
* A second request after a resolved status does not call through (the prompt is single-use)
* A request after a denial does not call through (the app never re-prompts in-app)

**Degradation (BC-EK-002, BC-EK-022)**
* With access denied, creating, editing, moving and deleting a local event all still succeed,
  and the local calendar list is unchanged
* `fullAccess → denied` between foreground reads changes the status and nothing else: same
  events, same calendars, same settings, no error surfaced
* `denied → fullAccess` (re-grant in Settings) is picked up by the foreground read without an
  in-app prompt
* The status is not read at launch, and a fresh store reports the provider's live value rather
  than a persisted one

**Persistence**
* `hasSeenCalendarAccessPrimer` round-trips through SQLite
* A database written before the key existed loads with it `false`, and no other setting is
  disturbed

---

## 3A.9 The 3A/3B boundary

What a user gets at the end of 3A: a permission flow that explains itself, asks once, degrades
correctly in every state, and tells the truth about what it can and cannot see. What they do not
get: their device calendars, because listing them is 3B.

This is a real, deliberate incompleteness, and §3A.3's `fullAccess` copy states it rather than
hiding it. The alternative — holding the permission model back until 3B could consume it — would
mean landing the permission flow and the mirror together, which is precisely the combination
that makes a permission bug look like a data bug.

The seams 3B inherits, already built and already tested:

* `CalendarAccessAuthorizing`, refined into `EventKitStore`
* `status.canReadDeviceEvents` — the gate on any enumeration or fetch
* `shouldPresentPrimerAutomatically` — the auto-present rule `SRC-LIST-01` consumes
* `FakeCalendarAuthorization`'s scriptable transitions, extended into `FakeEventKitStore`

## 3A.10 Exit criteria

Phase 3A is complete when:

* Every authorization state produces its specified behavior and its own copy, proven by test
* No code path reaches a system prompt without the primer preceding it, and none reaches one
  twice
* The status is never persisted and never cached across a foreground transition
* Every Phase 1 and Phase 2 test passes unchanged, and the app is fully usable with access denied
* The macOS build carries the calendar entitlement and the Info.plist carries the full-access
  usage description
* No file outside the EventKit adapter imports EventKit
