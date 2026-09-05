# Better Calendar: Detailed Phase 3 Specification

The purpose of this phase is to connect Better Calendar to the calendars already configured on
the user's device — Apple/iCloud, Google-via-iOS-settings, Exchange, subscribed, and local
device calendars — through **EventKit**, without redesigning any part of the event engine built
in Phase 2.

* **Phase 0** defined product scope, the ownership model, and the initial local data model.
* **Phase 1** produced a complete offline iPhone calendar.
* **Phase 2** turned that into a production-quality event engine: recurrence edit scopes, an
  append-only change journal, an outbox with idempotency and retry, tombstones, optimistic
  concurrency, duplicate detection, and a migration/recovery framework.
* **Phase 3** attaches the *first real provider* to the far side of that outbox. It is the
  phase in which the pipeline stops being a simulation.

Phase 2 was deliberately invisible to end users. Phase 3 is the opposite: it is the first phase
where the user's existing calendar data appears inside Better Calendar, and therefore the first
phase where a bug can damage data the user did not create in this app. That asymmetry drives
almost every rule below.

Do not begin Phase 4 (Better Calendar accounts and cloud sync) until every exit criterion in
this document is met. A second provider must never be attached while the first one is still
producing duplicates, resurrection, or write-back failures.

---

## Prerequisite status

The changes that had to land *before* Phase 3 could begin — because they alter types every later
adapter builds on, and because retrofitting them once a provider is attached means migrating live
user data — are **complete**:

| Prerequisite | Where | Status |
|---|---|---|
| Calendar provider identity (3.6) | `BetterCalendar`, `v018`, ADR 0004 | Done |
| Connection method, the two-axis model (3.7) | `ConnectionMethod`, ADR 0004 | Done |
| Capability enforcement at the model layer (3.10) | `Outcome.rejected`, ADR 0004 | Done |
| Default-calendar modelling decision (3.9) | ADR 0005 | Decided, no code change |
| Double-notification guard (3.16) | `LocalNotificationPlanner` | Done |
| Untitled-event placeholder (3.12) | `CalendarEvent.displayTitle` | Done |
| Change-journal `reconciliation` source (3L) | — | Not needed; see 3L |

All of it is inert until a provider exists: no calendar reports `.device`, none is read-only, and
none carries an account, so every gate above is a no-op against today's data. That is the same
approach Phase 2 took with the outbox — build the mechanism, prove it with tests, attach the
provider afterwards. Coverage lives in `Tests/MyAppTests/CalendarProviderIdentityTests.swift`,
plus provider-identity assertions added to the `MigrationTests` loop that runs against every
released schema version.

## Milestone status

| Milestone | Sections | Status |
|---|---|---|
| Prerequisites | 3.6, 3.7, 3.9, 3.10, 3.12, 3.16 | Done — see the table above |
| **3A — Permission and capability model** | 3.3, 3.4, 3.5 | **Done.** Specified in detail in `Instructions/phase3a_specification.md`; see ADR 0006 and `CalendarAccessTests`. Delivers BC-EK-001, BC-EK-002, BC-EK-022 in full, and the "never claims to display device events" half of BC-EK-003 |
| **3B — Calendar identity and ownership** | 3.8, 3.9 | **Done.** Specified in `Instructions/phase3b_specification.md`; see ADR 0007, `DeviceCalendarDiscoveryTests` and `DeviceCalendarStoreTests`. Delivers BC-EK-004, BC-EK-005 and BC-EK-019 in full, and extends BC-EK-022 to calendar rows. Nothing in it writes to EventKit |
| **3C — Reading events** | 3.11–3.17 | **Done.** Specified in `Instructions/phase3c_specification.md`; see ADR 0008, ADR 0002's Phase 3C amendment, and `DeviceEventMappingTests` / `DeviceEventMirrorTests` / `DeviceEventStoreTests` / `DeviceEventPersistenceTests`. Delivers BC-EK-006, BC-EK-012, BC-EK-013, BC-EK-016 and BC-EK-018 in full, completes BC-EK-003, and delivers the preservation half of BC-EK-017. Nothing in it writes to EventKit |
| **3D — Writing back** | 3.18–3.22 | **Done.** Specified in `Instructions/phase3d_specification.md`; see ADR 0009 and `DeviceWriteBackTests` / `DeviceWriteAdapterTests` / `DeviceWriteStressTests`. Delivers BC-EK-007, BC-EK-008, BC-EK-009, BC-EK-014 and BC-EK-015 in full, completes BC-EK-010 and BC-EK-017, and delivers the detection half of BC-EK-011 |
| **3E — Change detection** | 3.23–3.27 | **Done.** Specified in `Instructions/phase3e_specification.md`; see ADR 0010 and `DeviceChangeObservationTests` / `ReconciliationWindowTests` / `ConflictResolutionTests`. Completes BC-EK-006 and BC-EK-011, and reinforces BC-EK-012 |
| **3F — Duplicate connections** | 3.28–3.30 | **Done.** Specified in `Instructions/phase3f_specification.md`; see ADR 0011 and `DuplicateConnectionTests`. Delivers BC-EK-020 in full and BC-EK-021's calendar half, plus the event-level cross-transport match |
| 3G — Reminders | 3.31–3.32 | Not started |

---

# Phase 3 — Apple Calendar and Device-Calendar Integration

## Phase 3 objective

At the end of Phase 3, the team should have:

* A calendar permission flow that explains itself before the system prompt appears, and that
  degrades correctly for every EventKit authorization state including write-only access
* A calendar record that carries real provider identity — source, account, provider calendar
  identifier, read-only status, and connection method — instead of being implicitly local
* Device calendars listed, selectable, and individually toggleable for display
* EventKit events mirrored into the local SQLite database and rendered by the existing Day,
  Week, Month, Agenda, and Search screens with no screen-level knowledge that they came from
  EventKit
* Create, update, and delete flowing *out* to EventKit through the same outbox, journal, and
  tombstone mechanisms Phase 2 built — with a real adapter where Phase 2 had a stub validator
* External changes (made in Apple Calendar, or by a server push into iCloud/Google/Exchange)
  detected and reconciled into the local database without losing local edits
* Read-only calendars honored at the model layer, not merely hidden in the UI
* A default destination calendar the user chooses, used by Quick Add and the full editor
* Every event attributed on screen to its owning account and calendar
* A stored, user-made choice of connection method for any calendar reachable both through
  EventKit and (later) through a direct Google connection — the roadmap's duplication rule
* Apple Reminders integration behind an explicit, optional switch
* An EventKit test double that lets the entire mapping and reconciliation layer run in CI with
  no device, no account, and no real event store

A user should be able to install Better Calendar on a phone that already has three calendar
accounts, grant access, and see their real calendar correctly within seconds — then edit an
event in Apple Calendar and watch it update in Better Calendar, and vice versa.

---

## 3.0 Phase 3 boundaries

### Included

* EventKit calendar-access permission flow (full access, write-only, denied, restricted)
* Enumeration of EventKit sources and calendars
* Per-calendar display selection and visibility
* Reading EKEvents into the local database (the mirror)
* Creating, updating, and deleting EKEvents from local mutations
* Read-only and capability enforcement (`allowsContentModifications`, allowed availabilities,
  allowed entity types)
* Change detection via `EKEventStoreChanged` plus a reconciliation pass
* Local-vs-external conflict detection and resolution for mirrored events
* Default destination calendar selection
* Provider-specific metadata preservation, including fields Better Calendar does not model
* Owning-account and calendar attribution in event detail and editor surfaces
* The device-vs-direct connection-method choice and its persistence
* Cross-provider duplicate detection, extending the Phase 2 heuristics
* Apple Reminders as an optional, separately-permissioned integration
* An `EventKitStore` protocol plus an in-memory fake for CI
* Schema migrations for every new column and table this phase introduces

### Explicitly excluded

* The Google Calendar API (Phase 5) — Phase 3 reaches Google calendars *only* as they appear in
  EventKit, through the device
* Better Calendar accounts, cloud sync, or any network call originating from this app (Phase 4)
* Server-driven push notifications (Phase 4)
* Sending or responding to invitations; EventKit cannot add attendees, and Better Calendar must
  not pretend otherwise (Phase 11)
* CalDAV, Exchange, or Microsoft Graph adapters written by us — these arrive through EventKit as
  the device already configured them, and we do not talk to them directly
* Scheduling links, availability pages, or AI suggestions (Phases 11–12)
* iPad and Mac as *shipping* targets (Phase 7) — but see 3.5: the code must still compile and
  behave correctly on macOS, per the existing project rule

### The non-negotiable rule of this phase

**Better Calendar is not the authority for an EventKit event.** The device event store is. Every
design decision below follows from that. Where Phase 2 could resolve a disagreement by picking a
deterministic winner, Phase 3 often cannot: the other side is a system database that other apps
also write to, and that syncs to servers we do not control.

---

## 3.1 Establish Phase 3 requirement identifiers

Continue the identifier scheme from Phases 0–2, using a new `EK` prefix.

```text
BC-EK-001: User is shown a plain-language explanation before the system calendar prompt appears.
BC-EK-002: Denying calendar access leaves every Phase 1/2 local-calendar feature fully working.
BC-EK-003: Write-only access allows creating events and never claims to display device events.
BC-EK-004: Every EventKit calendar on the device is listed, grouped by its owning account.
BC-EK-005: Toggling a device calendar off removes its events from every view without deleting them.
BC-EK-006: An event created in Apple Calendar appears in Better Calendar after reconciliation.
BC-EK-007: An event created in Better Calendar on a device calendar appears in Apple Calendar.
BC-EK-008: Editing a mirrored event in Better Calendar writes the change back to EventKit.
BC-EK-009: Deleting a mirrored event removes it from EventKit and does not resurrect it.
BC-EK-010: A read-only calendar rejects edits at the model layer, not only in the UI.
BC-EK-011: An event edited externally between two launches is reconciled without losing local edits.
BC-EK-012: An event deleted externally is removed locally and does not reappear.
BC-EK-013: A recurring EventKit series expands identically to the same series in Apple Calendar.
BC-EK-014: A "this event only" edit to a mirrored series detaches exactly one occurrence.
BC-EK-015: A "this and future" edit to a mirrored series splits it the way EventKit splits it.
BC-EK-016: Mirrored events do not produce duplicate local notifications alongside system alerts.
BC-EK-017: Provider fields Better Calendar does not model survive a local edit round trip.
BC-EK-018: Every event displays its owning account and calendar in the detail view.
BC-EK-019: The user's chosen default destination calendar is preselected by Quick Add and the editor.
BC-EK-020: A calendar reachable both through the device and directly prompts a connection choice.
BC-EK-021: The same underlying event never appears twice from two connection methods.
BC-EK-022: Revoking calendar permission in Settings degrades the app without data loss or crash.
BC-EK-023: Apple Reminders integration is off until the user explicitly enables it.
BC-EK-024: The entire mapping and reconciliation layer runs in CI against a fake event store.
```

Use these identifiers in engine and integration tests, pull requests, and the Phase 3 QA
checklist, exactly as Phase 0/1/2 identifiers were used.

### Phase-level success criteria

* No event the user did not create in Better Calendar is ever silently destroyed, duplicated, or
  detached from its series by this app.
* No local edit is lost because an external change arrived at the same time — the loser of any
  conflict is preserved in `EventVersion` history and, where the user's intent is unclear, the
  user is asked.
* Permission is requested at a moment the user understands, never on first launch before any
  value has been shown.
* The app is fully usable — every Phase 1 and Phase 2 feature — with calendar access denied.
* Reconciliation cost is proportional to what changed, not to the size of the calendar.

---

## 3.2 Architecture: the provider adapter seam

Phase 2 built this pipeline and ran it with nothing on the far end:

```text
User edit
   ↓
EventMutationUseCases  (pure planner → EngineTransaction)
   ↓
Local database transaction (event + journal entry + outbox row, atomic)
   ↓
Pending mutation, status: pending
   ↓
MutationProcessor.decide(...)   ← validate closure always returned .valid
   ↓
applied
```

Phase 3 replaces the stub validator with a real provider adapter and adds an inbound path that
did not exist before:

```text
OUTBOUND                                  INBOUND
                                          EKEventStoreChanged / launch / foreground
User edit                                          ↓
   ↓                                       EventKitReconciler
EventMutationUseCases                              ↓
   ↓                                       Fetch changed range per selected calendar
EngineTransaction (local, atomic)                  ↓
   ↓                                       Diff against mirrored local rows
Outbox row (pending)                               ↓
   ↓                                       Classify: new / updated / deleted / conflicted
MutationProcessor                                  ↓
   ↓                                       EngineTransaction (same atomic write path)
EventKitMutationAdapter                            ↓
   ↓                                       Journal entry, source: reconciliation
EKEventStore commit
   ↓
Success → applied, store returned identifiers/version
Retryable → backoff (existing RetryPolicy)
Permanent → failed, surfaced in diagnostics
Conflict → conflicted, surfaced to the user
```

### Rules

* The adapter is the **only** file in the codebase that imports `EventKit`. Domain code stays
  free of it exactly as it stays free of SwiftUI and GRDB. Views must never see an `EKEvent`.
* The adapter is reached only through the outbox. No screen, view model, or store method calls
  `EKEventStore.save` directly — this is the Phase 2 rule, now load-bearing.
* Inbound reconciliation writes through the **same** `EngineTransaction` path as user edits, so
  it produces journal entries, respects tombstones, and cannot half-apply.
* Every inbound write carries `source: .reconciliation` in the change journal, so the journal
  distinguishes "the user did this" from "the device told us this."
* The adapter is defined against a protocol, not against `EKEventStore` directly:

```text
protocol EventKitStore {
    var authorizationStatus: CalendarAccessStatus { get }
    func requestAccess(_ level: CalendarAccessLevel) async throws -> CalendarAccessStatus
    func sources() throws -> [DeviceCalendarSource]
    func calendars() throws -> [DeviceCalendar]
    func events(in range: DateInterval, calendarIDs: [String]) throws -> [DeviceEvent]
    func event(withIdentifier id: String) throws -> DeviceEvent?
    func save(_ event: DeviceEvent, span: DeviceEditSpan) throws -> DeviceEventReceipt
    func remove(eventIdentifier: String, span: DeviceEditSpan) throws
    func changeObservations() -> AsyncStream<Void>
}
```

  `DeviceCalendar`, `DeviceEvent`, and friends are Better Calendar's own value types, populated
  by a thin translation layer over EventKit. A `FakeEventKitStore` implementing the same
  protocol is what makes BC-EK-024 — and most of this phase's test matrix — possible in CI.

---

# Phase 3A — Permission and capability model

## 3.3 Access levels and the request flow

iOS 17 and macOS 14 (the project's current deployment targets) distinguish two levels of
calendar access, and Better Calendar must model both:

```text
CalendarAccessLevel
- writeOnly     // may create events; may not read any
- full          // may read and write

CalendarAccessStatus
- notDetermined
- restricted    // policy/MDM/parental controls; not the user's choice to change
- denied
- writeOnly
- fullAccess
```

* Request **full access**, because the product is a calendar client that must display existing
  events. Write-only is a state to *handle gracefully*, not a state to request first.
* Never request access on first launch. Phase 1's onboarding shows value first; the calendar
  prompt is triggered by an explicit user action — tapping "Connect device calendars" in the
  calendar manager, or the first time the user opens the device-calendars screen.
* A pre-prompt explanation screen precedes the system alert (BC-EK-001). It states, in the
  product's own copy: what is read, that nothing leaves the device in this phase, and that
  access can be revoked in Settings at any time. It offers "Not now" as a first-class choice.
* The system prompt can only ever be shown once. Treat it as a single-use resource: if the
  pre-prompt is dismissed, do not burn the system prompt.
* After a denial, the app must never re-prompt in-app. It offers a deep link to Settings and
  otherwise stops asking.

## 3.4 Behavior in each authorization state

| Status | Required behavior |
|---|---|
| `notDetermined` | Local calendars only. Device-calendar surfaces show a single "Connect device calendars" affordance. No implicit prompting. |
| `restricted` | Local calendars only. Copy explains that access is managed by device policy and cannot be granted in-app. Never show a Settings deep link that cannot help. |
| `denied` | Local calendars only, full Phase 1/2 functionality (BC-EK-002). Device-calendar surfaces explain the state once and offer a Settings deep link. Previously mirrored events, if any, are hidden and their mirror rows retained — see 3.26. |
| `writeOnly` | Better Calendar may create events on device calendars but **cannot read them**. The app must not display an empty device calendar as though it were genuinely empty (BC-EK-003). Device calendars are listed as write-only destinations, with no event display, and copy says so plainly. |
| `fullAccess` | Everything in this phase. |

* Authorization is re-checked on every foreground transition, not cached for the process
  lifetime. A user can revoke access in Settings while the app is backgrounded; on return the
  app must degrade without crashing and without losing local data (BC-EK-022).
* A downgrade from `fullAccess` to `denied` or `writeOnly` triggers the mirror-retention policy
  in 3.26 — it never triggers a local delete.

## 3.5 Entitlements, usage descriptions, and platform guards

* Info.plist must carry `NSCalendarsFullAccessUsageDescription` and, if write-only is ever
  requested, `NSCalendarsWriteOnlyAccessUsageDescription`. Reminders (3.31) additionally needs
  `NSRemindersFullAccessUsageDescription`. The strings must describe the actual user benefit;
  App Review rejects generic boilerplate.
* The project generates its Info.plist (`GENERATE_INFOPLIST_FILE = YES`), so these are added as
  `INFOPLIST_KEY_*` build settings, not by checking in a plist file. Do not restructure the
  project to add a literal Info.plist for this.
* macOS builds of a sandboxed app require the calendar entitlement
  (`com.apple.security.personal-information.calendars`). The target's
  `SUPPORTED_PLATFORMS` includes `macosx`, and the whole test suite runs on the macOS
  destination on this machine — so this is not hypothetical.
* **EventKitUI is iOS/iPadOS only.** `EKCalendarChooser` and `EKEventEditViewController` have no
  macOS equivalents. Per the existing project rule in `CLAUDE.md`, any use of them sits behind
  `#if canImport(UIKit)` with a macOS fallback, following the `onboardingCover` pattern in
  `App/AppRootView.swift`. **Recommendation:** do not use EventKitUI at all in Phase 3. Better
  Calendar has its own editor and its own calendar manager; adopting Apple's would produce two
  visually inconsistent editors and a macOS hole. Use EventKit only.
* Any change to `project.pbxproj` on this branch must respect the existing local-signing rule:
  development team and bundle identifier stay out of git.

---

# Phase 3B — Calendar identity and ownership

## 3.6 Extend the calendar record with provider identity

**This was the single largest prerequisite in Phase 3. It has been built — see ADR 0004,
migration `v018`, and `CalendarProviderIdentityTests`. The description below is retained because
it is what the rest of this document is written against.**

`Better Calendar/Domain/CalendarModels.swift` defines `BetterCalendar` with only
`id, name, colorName, isVisible, isDefault, sortOrder, createdAt, updatedAt, versionNumber`.
The SQLite `calendars` table created by `v001_create_calendars` already has the right columns —
`provider`, `provider_account_id`, `provider_calendar_id`, `is_read_only`, `time_zone_id`,
`deleted_at` — but `SQLiteCalendarRepository.calendarArguments(_:)` hardcodes them: provider is
always `betterCalendar`, account is always `nil`, `provider_calendar_id` is just the local UUID
again, and `is_read_only` is always `0`.

Phase 3 must close that gap before any EventKit work begins:

```text
BetterCalendar  (extended)
- id: UUID
- provider: EventProvider
- providerAccountID: String?     // EKSource identifier
- providerCalendarID: String?    // EKCalendar.calendarIdentifier
- accountName: String?           // EKSource.title, for attribution display
- name: String
- colorName: CalendarColorName
- colorHex: String?              // device calendars carry an arbitrary color, not a token
- isVisible: Bool
- isReadOnly: Bool
- isDefault: Bool
- timeZoneIdentifier: String?
- connectionMethod: ConnectionMethod   // see 3.7
- capabilities: CalendarCapabilities   // see 3.10
- sortOrder: Int
- createdAt / updatedAt / versionNumber
```

* The migration that adds these to the domain type must be **read-tolerant** in exactly the way
  `BetterCalendar`'s existing hand-written `Codable` conformance already is: a calendar written
  before these fields existed decodes as a local, writable, non-read-only Better calendar. That
  conformance exists specifically so new fields can be added this way — follow the `sortOrder`
  and `versionNumber` precedent rather than inventing a new pattern.
* Color is the one genuinely awkward field. Phase 1 models calendar color as a
  `CalendarColorName` token drawn from the UI/UX design system; device calendars have arbitrary
  RGB. Store the device color as hex and map it to the nearest token *for chrome only*, or carry
  the exact hex through to rendering with a contrast check in both appearances. Decide this
  explicitly and record it as an ADR under `Documentation/Decisions/` — it affects
  `Shared/CalendarStyle.swift`, which today maps a closed enum.
* `EventProvider` currently has `.betterCalendar`, `.google`, `.apple`, `.university`. Phase 0
  §0.6 anticipated a distinct `eventKit` value. **Decide and record:** the provider of a Google
  calendar reached through the device is *not* the same as one reached through the Google API in
  Phase 5, and conflating them is precisely what causes the duplication the roadmap warns about.
  The recommended model separates the two axes:
  * `provider` = who owns the data (`google`, `apple`, `exchange`, `local`, `subscribed`, …),
    derived from `EKSource.sourceType` and, for Google-in-iCloud-settings, from the account
    identity
  * `connectionMethod` = how we reach it (`device` via EventKit, `direct` via a first-party API
    in Phase 5, `betterCalendar` for our own)

## 3.7 Connection method

```text
ConnectionMethod
- local          // a Better Calendar-owned calendar; no provider round trip
- device         // reached through EventKit
- direct         // reached through a provider API (Phase 5+; unreachable in Phase 3)
```

* Every calendar row carries exactly one. It is set when the calendar is first discovered or
  created and changed only by the explicit user choice described in 3.29.
* `direct` is defined in Phase 3 but never produced by it. Defining it now means Phase 5 does
  not have to migrate the column — the same reasoning that made Phase 0 reserve
  `ProviderMetadata` before any provider existed.

## 3.8 Calendar discovery, selection, and visibility

* On first grant, enumerate all EventKit sources and calendars and create a mirrored
  `BetterCalendar` row for each (BC-EK-004). Group by source in the UI: "iCloud", "Gmail",
  "Exchange", "Other", "Subscribed", "Birthdays".
* **Default selection on first connect:** mirror all calendars as rows, but default *display*
  to the calendars the device itself considers active, and leave large ambient calendars
  (Birthdays, Holidays, subscribed feeds) visible-off by default. Ask nothing; the user can
  toggle any of them immediately in the calendar manager.
* Toggling a device calendar off hides its events everywhere — Day, Week, Month, Agenda, Search,
  conflict detection, free/busy — and **never deletes** anything from EventKit or from the local
  mirror (BC-EK-005). This is display state, not data state.
* A device calendar cannot be renamed, recolored, or deleted from Better Calendar in Phase 3.
  Those operations exist in EventKit but they mutate a shared system resource in ways the user
  will not expect from a third-party app. The calendar manager shows them as read-only entries
  with a "Manage in Settings" affordance. (Creating *events* on them is of course allowed.)
* A calendar that disappears from EventKit between launches — account removed, calendar deleted
  elsewhere — is marked unavailable rather than purged. Its mirrored events follow 3.26.

## 3.9 Default destination calendar

* Settings gains a default-destination picker spanning **all** writable calendars, local and
  device (BC-EK-019). Phase 1 already has a default, but note **how** it is modeled, because it
  constrains the design: there is no `AppSettings.defaultCalendarID`. The default is a flag on
  the calendar row (`BetterCalendar.isDefault`), surfaced as the computed
  `BetterCalendarStore.defaultCalendarID` (`calendars.first(where: \.isDefault) ?? calendars.first`)
  and enforced in SQLite by the partial unique index `calendars_one_default_idx`.
* That model needs a decision in Phase 3. Making a *device* calendar the default means setting a
  Better Calendar flag on a mirrored row — which is our state, not the device's, and must never
  be written back to EventKit. Two viable options:
  * Keep `isDefault` on the row and treat it as strictly local-only mirror state (simplest;
    preserves the existing index and the computed property)
  * Move the default to `AppSettings` as an explicit calendar id (cleaner separation of app
    preference from calendar identity; requires migrating the flag and dropping the index)

  **Decided: the first.** `isDefault` stays on the row as local-only mirror state that is never
  written back to a provider. See ADR 0005 for why, and for the rule it imposes on the adapter.
* If the chosen default becomes unwritable — permission revoked, calendar removed, calendar
  turned read-only — fall back deterministically: the device's own default writable calendar if
  available, otherwise the first writable local calendar. Never fall back to a read-only
  calendar, and never silently write to a calendar the user did not choose without surfacing it
  in the editor.
* Quick Add and the full editor preselect the default but always show which calendar (and which
  account) they are about to write to. On a device with three accounts this is the difference
  between a work event landing in a personal calendar and not.

## 3.10 Read-only calendars and capability enforcement

Read-only is not a UI state. Enforce it at the model layer (BC-EK-010):

```text
CalendarCapabilities
- allowsContentModifications: Bool   // EKCalendar.allowsContentModifications
- allowsEventCreation: Bool
- allowedAvailabilities: [EventAvailability]
- supportsRecurrence: Bool
- supportsReminders: Bool            // EKCalendar allowed alarms
- isSubscribed: Bool
- isImmutable: Bool
```

* `EventMutationUseCases` gains a capability precondition: a mutation targeting a calendar that
  disallows it returns a new `Outcome` case rather than producing an `EngineTransaction`. It
  must fail *before* the local write, so the user never sees an optimistic change that then
  vanishes when EventKit rejects it.
* **Built.** `EventMutationUseCases.Outcome` gained `case rejected(CapabilityViolation)`,
  matching the existing `.duplicate` / `.conflicted` precedent, and `RecurrenceSplitter.Outcome`
  mirrors it. Create, update, move-between-calendars, delete, duplicate, and ICS import are all
  gated; `BetterCalendarStore` surfaces the violation's message through `lastError`. The gate is
  deliberately conservative — a `calendarID` with no matching row is *not* rejected, because
  Phase 1/2 already permit that and import and undo both rely on it.
* Birthday and subscribed calendars are always read-only. Holiday calendars usually are.
  Availability values a calendar does not allow must be mapped down, not silently dropped.
* Read-only events still participate fully in *display*, conflict detection, and free/busy. They
  are readable data; only writes are blocked.

---

# Phase 3C — Reading EventKit events into the local database

## 3.11 The mirror model

Better Calendar keeps a **local mirror** of device events rather than querying EventKit on every
render. This follows directly from the Phase 1/2 architecture: calendar views read from the
store, recurrence expands from `RecurrenceExpander`, search reads the FTS index, conflict
detection reads `ConflictIndex`. None of those can be reimplemented against a live EventKit
query without abandoning the engine Phase 2 just built.

Mirror rules:

* Every mirrored event is a normal `CalendarEvent` row whose `providerMetadata` identifies its
  origin: `provider`, `providerAccountID`, `providerCalendarID`, `providerObjectID`,
  `providerVersion`.
* `providerObjectID` stores EventKit's event identifier. Record both identifiers EventKit
  offers, because they answer different questions: the local event identifier is what you pass
  back to fetch and save, while the cross-device external identifier is what recognizes "the
  same event" after a restore or on another device. Neither is guaranteed unique on its own for
  detached recurring occurrences — treat identity as `(identifier, originalOccurrenceDate)` for
  anything detached, mirroring the `OccurrenceKey` model Phase 2 already established.
* `providerVersion` stores the device event's last-modified timestamp. It is the change detector
  in 3.24 and the concurrency check in 3.22.
* The mirror is **not** authoritative and must be reconstructible. Deleting the entire local
  database and re-mirroring must produce the same calendar. This is what makes the mirror safe:
  no user data lives only in it.
* Mirrored rows are never written by any path except the reconciler and the outbound adapter's
  receipt handling. A user edit goes local → outbox → EventKit → receipt → mirror update.

## 3.12 Field mapping: device event → `CalendarEvent`

| Device event | `CalendarEvent` | Notes |
|---|---|---|
| identifier | `providerMetadata.providerObjectID` | Plus external identifier, stored alongside |
| calendar identifier | `calendarID` via the mirrored `BetterCalendar` | Never the raw EventKit id |
| title | `title` | Empty titles are legal in EventKit and common on imported events. `CalendarEvent.displayTitle` supplies "(No title)" and is already applied across Day, Week, Month, Agenda, Search, detail, and notification bodies — deliberately *not* in the editor, where an empty title must stay empty |
| notes | `notes` | |
| location (string) | `location` | Structured location/geo is preserved raw (3.17), not modeled |
| url | `urlString` | |
| start / end | `startDate` / `endDate` | See 3.14 |
| isAllDay | `timeType = .allDay` | See 3.14 |
| timeZone | `timeZoneIdentifier` | Nil on device means floating; see 3.14 |
| availability | `availability` | Map `tentative`/`unavailable` per 3.10's allowed set |
| status | — | Cancelled events are excluded from free/busy, as Phase 2 §2.7 requires |
| alarms | `reminders` | See 3.16 — **display only, no local notification** |
| recurrence rules | `recurrence` | See 3.13 |
| attendees / organizer | read-only attribution | See 3.15 |
| lastModified | `providerMetadata.providerVersion` | |
| everything else | preserved raw | See 3.17 |

* Mapping is a pure function over Better Calendar's own `DeviceEvent` value type, in a file with
  no EventKit import, so the whole table above is unit-testable without a device.
* Every mapping is round-trip tested: device → local → device produces an equivalent event.

## 3.13 Recurrence mapping

Better Calendar's `RecurrenceRule` and EventKit's rules overlap but are not identical, and the
gaps must be handled explicitly rather than discovered in the field.

* Support the frequencies Phase 2 already supports — daily, weekly, monthly by day-of-month,
  monthly by weekday-ordinal, yearly — plus interval, weekday set, and end condition (never /
  after N / until date).
* **A device event can carry more than one recurrence rule.** Better Calendar models one. An
  event with multiple rules is mirrored as **read-only** with a clear badge, never flattened
  into one rule and never silently truncated — flattening would corrupt the user's series on the
  first write-back.
* Rules using set-positions, month-of-year lists, or day-of-year values that Phase 2's engine
  does not model are likewise mirrored read-only with the raw rule preserved.
* Detached occurrences (EventKit's exceptions) map onto Phase 2's existing
  `RecurrenceException` + replacement-event model — the same `(recurrenceMasterID,
  originalStart)` identity from §2.3. This is exactly the model Phase 2 built, and it fits.
* A mirrored series must expand to the same occurrence set as Apple Calendar shows for the same
  range (BC-EK-013). This is a test, not an aspiration: fixture series compared occurrence by
  occurrence.
* The existing lazy-expansion and `OccurrenceCache` invalidation rules from §2.5 apply
  unchanged. Reconciliation invalidates the cache for affected masters only.

## 3.14 Time zones and all-day events

The Phase 0 §0.9 time-semantics rules are unchanged and now have to survive a round trip through
a system store:

* Timed events store a UTC instant plus the original IANA zone identifier. EventKit's per-event
  time zone maps to that identifier; a device event with no time zone is **floating** and maps
  to Phase 1's `.floating` time type, which the schema already supports.
* All-day events compare and store on local calendar-date components, never UTC midnight. A
  mirrored all-day event must not shift by a day when the device time zone changes — this is
  BC-EVT-level behavior already covered by `TimeZoneMatrixTests`, extended here to mirrored
  events.
* An event created near a DST transition must retain its intended local time on both sides,
  through the mirror in both directions.
* Add to the existing time-zone matrix: create in zone A → mirror → change device to zone B →
  reconcile → the event has not moved.

## 3.15 Attendees, organizer, and status

* EventKit exposes attendees and the organizer as **read-only**. There is no API to add an
  attendee to an event. Better Calendar must therefore never present an "add guest" affordance
  in Phase 3 (invitations are Phase 11).
* Mirror attendees as display-only attribution: name where available, participation status, and
  whether the current user is the organizer. Store them in a new `event_attendees` table rather
  than stuffing them into notes.
* An event the user has **declined** is excluded from free/busy, closing the reserved no-op left
  by Phase 2 §2.7 and ADR 0002. Update that ADR rather than leaving it stale.
* A cancelled event is excluded from conflict detection and free/busy but still displayed, with
  its status shown.
* Attendee names and email addresses are personal data belonging to third parties. They are
  subject to the same privacy rule as event content: never logged, never in analytics, never in
  a diagnostic string. `PrivacyLog`'s `StaticString` design already makes the accidental case
  impossible — do not add an escape hatch.

## 3.16 Alarms, reminders, and the double-notification rule

**This is the most easily-missed correctness bug in the phase (BC-EK-016). The guard is already
in place — `LocalNotificationPlanner` excludes `connectionMethod == .device` calendars from its
desired set, and three tests in `CalendarProviderIdentityTests` pin it, including the cancellation
path. It removes nothing today, because no calendar reports `.device` yet.**

A device event's alarms are scheduled by the *system*, on behalf of the account that owns the
event. If Better Calendar mirrors an event's alarms into its own `EventReminder` list and lets
`LocalNotificationPlanner` schedule them, the user gets **two** notifications for every event:
one from the system calendar, one from us.

Required behavior:

* Mirrored device events' alarms are **display-only**. `LocalNotificationPlanner` must exclude
  any event whose calendar's connection method is `device` from its desired-notification set.
* The exclusion belongs in the planner's `plan(...)` input, not in the scheduler — the planner
  is the pure, tested component, and `LocalNotificationPlanner`'s reconciliation diff is what
  guarantees stale notifications get cancelled when an event stops qualifying.
* When the user *edits* reminders on a mirrored event in Better Calendar, that write goes to
  EventKit as an alarm change. The system continues to own delivery. We never take over.
* Local Better Calendar events are unaffected and keep scheduling exactly as they do today.
* Test explicitly: mirror an event with two alarms, run reconciliation, and assert the
  `UNUserNotificationCenter` request set contains **zero** requests for it — and that turning a
  device calendar off and on again does not leave orphaned requests behind.

## 3.17 Preserving provider-specific metadata

Phase 0 §0.6 requires that a provider-derived event never silently becomes a Better-owned event,
and Phase 1 already preserves unmapped ICS properties in `providerMetadata.rawICSProperties` so
export is non-destructive. Extend the same principle (BC-EK-017):

* Fields Better Calendar does not model — structured location, conference/video-call data,
  geolocation, custom account properties — are preserved on the mirror row and written back
  untouched.
* A Better Calendar edit that touches only the title must not strip a Google Meet link from the
  event. This is the failure mode users notice immediately and never forgive.
* Implement write-back as a **field-level patch** against a freshly-fetched device event, not as
  "construct a new event from the local row and save it." Fetch, apply only changed fields
  (computed from the journal's `FieldDiff`, which Phase 2 already produces), save.

---

# Phase 3D — Writing back to EventKit

## 3.18 The mutation adapter

`MutationProcessor.decide(...)` already takes an injectable `validate` closure and already
classifies outcomes as retired / retry / failed. Phase 3 supplies a real implementation behind
that seam rather than rewriting the processor.

* The processor stays **pure and synchronous** for the launch-recovery path — that property is
  load-bearing (`LaunchRecovery` calls `MutationProcessor.reconcile` inline, and its doc comment
  explains why launch must not become async). EventKit I/O therefore runs through
  `MutationProcessorActor`, off the main thread, not inside launch.
* Launch recovery reconciles the outbox *without* provider I/O: pending rows for device
  calendars stay pending and are drained by the actor shortly after launch. Launch must not
  block on EventKit.
* The adapter maps each outbox row to a device operation, applies it, and returns a receipt
  containing the new provider identifier and last-modified value, which is written back to the
  mirror row in the same transaction that marks the mutation applied.

## 3.19 Create, update, delete

* **Create:** save to the target device calendar, then persist the returned identifier onto the
  local row. Until the receipt lands, the local row's `syncStatus` is `pendingCreate` — a state
  the schema has carried since Phase 0 and that finally means something.
* **Idempotency across a crash:** a create that succeeded in EventKit but crashed before the
  receipt was persisted must not create a second device event on retry. Before re-issuing a
  create, the adapter searches the target calendar's recent range for an event matching the
  outbox row's payload using the Phase 2 `DuplicateDetector` heuristics; a high-confidence match
  is adopted as the receipt instead of creating again. This is the concrete provider-side
  realization of §2.11, and it is worth a dedicated test.
* **Update:** fetch, patch changed fields only (3.17), save with the correct span (3.20).
* **Delete:** remove from EventKit with the correct span, then finalize the local tombstone. The
  tombstone is written locally in the same transaction as the delete (Phase 2 §2.13) and is what
  prevents a late reconciliation pass from resurrecting the event (BC-EK-009). The existing
  resurrection guard in `MutationProcessor.decide` — which retires a create/update whose entity
  now has a live tombstone — must be extended to cover inbound reconciliation as well.

## 3.20 Recurrence-scope writes

Phase 2 defined three edit scopes; EventKit offers **two** spans — this event, and future
events. There is no "all events" span. The mapping must be explicit:

| Better Calendar scope | Device write |
|---|---|
| `thisEventOnly` | Save with the this-event span; EventKit detaches the occurrence. Mirror the detachment into the existing `RecurrenceException` + replacement-event model (BC-EK-014). |
| `thisAndFuture` | Save with the future-events span from the target occurrence. **EventKit performs its own split**, which may not produce the same shape as Phase 2's `RecurrenceSplitter`. Do not split locally and then also split remotely. Issue one future-span write and re-mirror the resulting series from the device (BC-EK-015). |
| `allEvents` | Address the series master and save with the this-event span *on the master*, which is how EventKit expresses a whole-series change. Verify against the fixture matrix; this is the mapping most likely to be got wrong. |

* Phase 2's backlog notes that `.thisAndFuture` is engine-API only, with no third button on the
  confirmation dialog, deliberately deferred until "Phase 3 has a provider to justify the added
  complexity." **That condition is now met.** Phase 3 ships the third option in
  `EventDetailsView`'s confirmation dialog for both local and mirrored series.
* After any scope write to a mirrored series, re-mirror the affected series from the device
  rather than trusting the local projection. The device is the authority; the local split is a
  prediction.

## 3.21 Failure taxonomy

The existing `RetryPolicy` (exponential backoff with jitter, bounded window) is reused, but
Phase 2 had only one failure class. Phase 3 must classify:

| Class | Examples | Handling |
|---|---|---|
| Transient | Store busy, temporary account unavailability | Retry with existing backoff |
| Permission | Access revoked, write-only, calendar became read-only | Do **not** retry blindly. Park the mutation, surface it, resume when access returns |
| Permanent | Calendar deleted, event no longer exists, invalid data rejected | Fail the mutation, journal it, surface it in diagnostics — never drop it silently |
| Conflict | Device event changed underneath us | Route to 3.25, not to retry |

* A `failed` mutation must remain user-visible or diagnostics-visible. Phase 2's §2.12 rule —
  silent data loss is the one failure mode this pipeline exists to eliminate — is unchanged and
  now matters more, because the payload may be the user's only copy of an edit.
* Permission failures must not consume retry attempts. A user who denies access for a week and
  then re-grants it should still have their queued edits, not a queue of exhausted mutations.

## 3.22 Optimistic concurrency against the device

Phase 2 §2.14 gives every entity a local `versionNumber`. Phase 3 adds the provider side:

* An update mutation records the device event's last-modified value it was based on.
* Before writing, the adapter re-fetches and compares. A mismatch means the device event changed
  since the local edit was made — the write is **not** applied blindly; the row moves to
  `conflicted` and goes to 3.25.
* Last-modified granularity is coarse (whole seconds on some sources), so treat a mismatch as a
  *signal* and confirm with a field-level diff before declaring a conflict. Two writes within the
  same second that touched different fields are a merge, not a conflict.

---

# Phase 3E — Change detection and reconciliation

## 3.23 Change observation

* Subscribe to the event-store-changed notification for the lifetime of the app. It carries no
  payload — it means "something changed, re-query" — so it triggers a reconciliation pass, not a
  targeted update.
* Also reconcile on: app foreground, permission grant, calendar-selection change, and the
  visible date range moving outside the currently-mirrored window.
* Coalesce. The notification can arrive in bursts during account sync; debounce so a burst
  produces one pass, and never run two passes concurrently.
* Ask the store to refresh its sources when appropriate so a pass sees server-side changes rather
  than only local ones, but do not do this on every pass — it is a network-triggering operation.

## 3.24 The reconciliation pass

EventKit exposes no delta/change-token API. Reconciliation is therefore a **bounded range diff**,
and keeping it bounded is what keeps it affordable:

```text
1. Determine the reconciliation window: the visible range plus a prefetch margin,
   unioned with any range mutated since the last pass.
2. Fetch device events in that window for every selected calendar.
3. Load mirrored local rows in the same window for the same calendars.
4. Match on provider identifier (falling back to the cross-device external identifier,
   then to Phase 2 duplicate heuristics for events whose identifier changed).
5. Classify each pair:
     device-only          → insert mirror row
     both, device newer   → update mirror row (or conflict, see 3.25)
     both, equal          → no-op
     both, local pending  → conflict candidate
     local-only, mirrored → device deletion; delete mirror row and write a tombstone
     local-only, Better-owned → untouched; not our business
6. Emit one EngineTransaction with all changes, journalled with source: .reconciliation.
7. Invalidate OccurrenceCache for affected masters only.
8. Recompute ConflictIndex incrementally for the affected ranges only.
```

* A mirrored event that vanished from the device is deleted locally (BC-EK-012) — but only if it
  was inside the fetched window and its calendar was included in the fetch. **Never infer a
  deletion from an event's absence outside the queried range.** This is how mirrors lose data.
* The pass is idempotent: running it twice produces one result. Test it that way.
* Every pass records what it did — counts, not content — for the diagnostics surface.

## 3.25 Conflict model: local edit versus external edit

The roadmap's Phase 4 conflict policy is the right policy here too, applied one phase early:

* **Different fields changed on each side → merge automatically.** The journal's `FieldDiff`
  makes this computable rather than guesswork.
* **Same low-risk field (title, notes, location, url, color) → newest write wins**, with the
  loser preserved in `EventVersion` history. Never discard.
* **Time, recurrence, deletion, or attendees conflict → ask the user.** Preserve both versions
  until resolved. These are the changes where guessing wrong is expensive and irreversible.
* Until a conflict is resolved, the event displays its **device** state (the shared truth other
  people and other devices see) with a clear indicator that a local edit is pending, rather than
  showing a local state that no one else can see.
* Conflicts are surfaced in a dedicated list, not only as a transient banner. A conflict the user
  dismisses by accident must remain findable.

## 3.26 Deletions, tombstones, and access loss

* A local delete of a mirrored event writes a tombstone *and* removes the device event. The
  tombstone's purge window must outlast plausible reconciliation delay — Phase 2 §2.13 already
  requires this; Phase 3 supplies the real number, which must exceed the longest realistic
  account sync latency (hours, not minutes).
* An external delete removes the mirror row and writes a tombstone with a distinct
  `deletedBy` reason, so the journal distinguishes "the user deleted this here" from "it went
  away out there."
* **Access loss is not deletion.** If permission is revoked or a calendar is deselected, mirror
  rows are retained and hidden, not deleted. If access is restored, reconciliation reconnects
  them by provider identifier instead of re-importing everything as new — which is what would
  produce the duplicate storm this phase exists to avoid.
* Define a retention limit for hidden mirror rows (e.g. purge mirrored events for a calendar
  that has been unavailable for N days) so the database does not grow without bound. Record N in
  an ADR; do not leave it implicit.

## 3.27 Cost budget

* A reconciliation pass fetches only the reconciliation window, never the whole calendar.
* Fetches and diffs run off the main thread. Rendering must never block on reconciliation.
* A pass that finds nothing changed must be cheap enough to run on every foreground without a
  perceptible cost — see the targets in Phase 3J.

---

# Phase 3F — The duplicate-connection rule

## 3.28 The problem

The roadmap states it directly: a Google calendar may already appear in EventKit because the
user added their Google account in iOS Settings. In Phase 5, Better Calendar may *also* connect
to that same Google account directly. Synchronizing both copies independently produces duplicate
events, duplicate notifications, and edits that fight each other.

Phase 3 cannot fully solve this — the direct connection does not exist yet — but it must build
the detection and the storage now, because retrofitting it after Phase 5 means migrating live
user data.

## 3.29 Detection and the user's choice

* At calendar discovery, record enough identity to recognize the same underlying calendar through
  a different transport: source type, account identifier, account email/title where exposed, and
  the provider calendar identifier.
* When two connection methods would reach the same underlying calendar, prompt the user to choose
  one (BC-EK-020), presenting the trade-off honestly:
  * **Device connection** — no extra sign-in, works with everything already on the phone, limited
    to what EventKit exposes
  * **Direct connection** — richer provider features, needs a separate sign-in (Phase 5+)
* Store the choice on the calendar row (`connectionMethod`) and honor it: the non-chosen
  transport must not mirror, must not write, and must not appear as a separate calendar.
* The choice is changeable later in the calendar manager, and changing it is a **migration**, not
  a toggle: re-key mirrored events to the new transport's identifiers rather than deleting and
  re-importing. Specify this now even though Phase 3 cannot execute it, so Phase 5 inherits a
  designed path instead of an improvised one.
* In Phase 3 the prompt is reachable only in the degenerate case (the same account configured
  twice on the device). Ship the storage, the detection, and the calendar-manager surface;
  exercise the prompt with fixtures.

## 3.30 Cross-provider duplicate detection

Extend Phase 2's `DuplicateDetector` (§2.15) rather than writing a second one:

* Its provider-UID match already takes precedence over heuristics — that generalizes correctly,
  since the same underlying event reached two ways carries the same account-level identifier even
  when local identifiers differ.
* Add a match reason for "same event, different transport," scored on account identity plus the
  provider's own event identifier.
* The rule from §2.15 is unchanged and is now more important: **never merge silently.** Return
  candidates with confidence; let policy or the user decide (BC-EK-021).
* An ICS import that re-imports an event already mirrored from the device must be detected as a
  duplicate — Phase 1's import path and Phase 3's mirror now overlap, and this is a real case.

---

# Phase 3G — Apple Reminders (optional)

## 3.31 Scope

Reminders are a *separate* EventKit entity type with a *separate* permission. Treat them as an
opt-in module, not as part of calendar integration (BC-EK-023):

* Off by default. A dedicated Settings switch requests reminders access when enabled, with its
  own pre-prompt explanation.
* Read reminders with due dates and display them in Agenda and Day views as a visually distinct
  row type — never as events, which would corrupt conflict detection and free/busy.
* Completion toggling writes back. Creating and editing reminders is **out of scope** for
  Phase 3; Better Calendar's own tasks arrive in Phase 6, and shipping a half-task-manager here
  guarantees a rewrite then.
* Reminders never participate in conflict detection, free/busy, or duplicate detection.
* If reminders access is denied while calendar access is granted, the calendar side is entirely
  unaffected. The two permissions are independent and must be handled independently.

## 3.32 Explicitly deferred to Phase 6

Recurring reminders, subtasks, priorities, lists-as-calendars, and reminder creation.

---

# Phase 3H — User-facing surfaces

## 3.33 New and changed screens

Continue the screen-ID convention from `Instructions/ui_ux_design_document.md` §7:

| Screen | ID | Purpose |
|---|---|---|
| Calendar access primer | `SRC-PERM-01` | Pre-prompt explanation, "Connect" / "Not now" |
| Device calendars | `SRC-LIST-01` | Sources and calendars grouped by account, visibility toggles, read-only badges |
| Connection method choice | `SRC-CONN-01` | The 3.29 device-vs-direct decision |
| Sync status / conflicts | `SRC-STAT-01` | Pending, failed, and conflicted mutations; last reconciliation; per-calendar state |
| Calendar Manager | `CAL-MGR-01` (extended) | Local and device calendars in one list, device entries read-only with an entry point to `SRC-LIST-01` |
| Event Detail | `EVT-DETAIL-01` (extended) | Owning account and calendar attribution, read-only state, attendees, conflict indicator |
| Full Event Editor | `EVT-EDIT-01` (extended) | Calendar picker spanning writable local and device calendars, showing the account |
| Settings | `SET-01` (extended) | Default destination calendar, reminders switch, device-calendar diagnostics |

These follow the existing design system: the tokens in UI/UX §6.2, the error-copy rules in §9.2,
and the destructive-action patterns in §9.3. No new visual language is introduced by this phase.

## 3.34 Attribution

Every event shows its owning account and calendar in the detail view (BC-EK-018), and calendar
color remains the primary at-a-glance signal in grid views. A user with a work Exchange calendar
and a personal iCloud calendar must never have to guess which one an event is on before editing
it — and if the event is read-only, the detail view says so *before* the user attempts an edit,
not after.

## 3.35 Error and empty-state copy

Per UI/UX §9.2, error copy states what happened, why, and what to do next. The states this phase
introduces, each needing real copy rather than a generic failure message:

* Access denied / restricted (distinct copy — restricted cannot be fixed by the user)
* Write-only access (can create, cannot display)
* Calendar became read-only
* Account removed from the device
* Edit could not be saved to the device (with retry and "keep my copy" affordances)
* Conflict awaiting resolution
* Reconciliation in progress on first connect, for accounts with large calendars

---

# Phase 3I — Test strategy

## 3.36 The fake event store

BC-EK-024 is what makes this phase testable at all. Everything above is written against the
`EventKitStore` protocol in 3.2, and `FakeEventKitStore` implements it in memory with:

* Scriptable authorization status, including transitions (granted → revoked → re-granted)
* Injectable failures by class (transient, permission, permanent, conflict) for 3.21
* Simulated external mutation between passes, so "someone edited this in Apple Calendar" is a
  deterministic test step rather than a manual one
* Deterministic identifiers and last-modified values
* Recurrence expansion faithful enough to test detachment and splitting

This matters beyond convenience: no iOS runtime is installed on the primary development machine,
and the full suite runs on the macOS destination. The mapping, reconciliation, conflict, and
adapter layers must be fully covered there.

## 3.37 Required automated coverage

Runs in CI on every pull request, alongside the Phase 2 matrix.

**Permission**
* Every authorization state produces its specified behavior (3.4)
* Revocation while backgrounded degrades without data loss or crash
* Re-grant reconnects mirrored events by identifier instead of re-importing as new
* Write-only never displays device events and never claims the calendar is empty

**Mapping**
* Round trip for every field in 3.12, including empty title, no location, no notes
* All-day mirrored event does not shift across a device time-zone change
* Floating device event maps to `.floating`, not to a timed event in the current zone
* Event near a DST boundary retains intended local time in both directions
* Multi-rule and unsupported-rule events are mirrored read-only with the raw rule preserved
* Unmapped provider fields survive a title-only local edit (BC-EK-017)

**Recurrence**
* A mirrored series expands to the same occurrences as the device for a two-year window
* This-event edit detaches exactly one occurrence and leaves the rest untouched
* This-and-future edit produces the device's split, and the local mirror matches after re-mirror
* All-events edit updates the master and every non-detached occurrence
* A detached occurrence deleted externally does not remove its siblings

**Write-back**
* Create → receipt persisted → mirror carries the device identifier
* Create that succeeded but crashed before the receipt is adopted, not duplicated (3.19)
* Update patches only changed fields
* Delete removes the device event and the tombstone prevents resurrection
* A write to a read-only calendar is rejected before the local write (BC-EK-010)
* Each failure class routes to its specified handling; permission failures do not burn retries

**Reconciliation**
* External create, update, and delete each land correctly
* Running the pass twice changes nothing the second time
* An event outside the fetched window is never inferred to be deleted
* Deselecting and reselecting a calendar does not duplicate its events
* Concurrent local edit and external edit to different fields merge
* Concurrent edits to the same time field surface a conflict rather than overwriting

**Notifications**
* A mirrored event with alarms produces zero local notification requests (BC-EK-016)
* A local event's notifications are unaffected by the presence of mirrored events
* Turning a device calendar off cancels nothing belonging to local events and leaves no orphans

**Duplicates**
* The same account configured twice yields one calendar and one set of events
* Re-importing an ICS file whose events are already mirrored is detected as duplicate

## 3.38 Device scenarios that cannot be automated

Automated coverage cannot reach these; they are a written, executed manual checklist before exit:

* A real device with iCloud, a Google account added in Settings, and an Exchange account
* Granting access with a calendar of 5,000+ events and measuring first-mirror time
* Editing in Apple Calendar with Better Calendar backgrounded, then foregrounding
* Airplane mode: create locally, restore connectivity, confirm the queue drains once
* Revoking access in Settings while the app is backgrounded
* A shared calendar the user has read-only access to
* A birthday calendar and a subscribed holiday calendar
* An event with a video-conference link, edited in Better Calendar, verified intact
* Time-zone travel: change the device zone and confirm nothing moves that should not

---

# Phase 3J — Performance and reliability targets

* First mirror of a 5,000-event account: under 10 seconds, progress shown, UI responsive
  throughout.
* Incremental reconciliation pass with no changes, one-month window: under 100 milliseconds.
* Reconciliation pass with 50 changed events: under 500 milliseconds.
* Write-back of a single event edit: under 200 milliseconds from outbox pickup to receipt,
  excluding account sync latency we do not control.
* Foreground-to-interactive with mirrored calendars present: unchanged from Phase 1's target —
  reconciliation must never gate the first frame.
* Zero duplicate device events across 1,000 simulated create-crash-retry cycles.
* Zero lost local edits across 1,000 simulated concurrent-external-edit cycles.
* Zero resurrections across 1,000 delete-then-delayed-reconcile cycles.

Follow the Phase 2 precedent for stress loops: a reduced smoke variant on every PR, the full
loop on demand and before release.

---

# Phase 3K — Privacy and App Review

* Calendar contents never leave the device in Phase 3. There is no backend yet; do not add one
  here.
* Usage-description strings must describe genuine user benefit. Generic strings are a common
  rejection cause for calendar-access apps.
* `PrivacyLog`'s existing constraints hold without exception: no event title, notes, location,
  attendee name, account email, or calendar name in any log or analytics payload. Add
  Phase 3 analytics events to the existing closed `AnalyticsEvent` enum — a permission-result
  event and a reconciliation-summary event carrying counts only.
* Update the privacy manifest and App Store privacy disclosures to reflect calendar (and, if
  enabled, reminders) access.
* Request the narrowest access that delivers the feature, and never request reminders access as
  a side effect of granting calendar access.

---

# Phase 3L — Migrations

Phase 3 adds schema. Every change follows the Phase 2 §2.17 framework: numbered, forward-only,
transactional, checksummed in `schema_metadata`, and tested against fixture databases from every
previously released version.

**Already landed** as a Phase 3 prerequisite (`v018_add_calendar_provider_identity`): the
`calendars` extension 3.6 requires — `account_name`, `connection_method`, `capabilities_json`,
and a partial index on `(provider, provider_account_id, provider_calendar_id)` for the
duplicate-connection lookup. The other five fields (`provider`, `provider_account_id`,
`provider_calendar_id`, `is_read_only`, `time_zone_id`) already existed in the table since `v001`
and simply started carrying real values. See ADR 0004.

Still expected:

* Add `event_attendees` (3.15).
* Extend `events` with the device's cross-device external identifier and the last-modified
  value used for concurrency (3.22).
* Add a reconciliation-state table: per calendar, the last reconciled window and timestamp.

**No migration is needed for the change journal.** `JournalSource` already has a
`reconciliation` case, and `change_journal.source` carries no `CHECK` constraint — only
`operation` does. ADR 0003's deferred table rebuild concerns widening the **`operation`** values
(e.g. adding a `duplicateDetected` case), which reconciliation does not require: an inbound
change is an ordinary create, update, or delete. That deferral therefore stands; do not reopen it
on Phase 3's account.

Extend the launch sequence (Phase 2 §2.18) with a step after outbox reconciliation: re-check
calendar authorization and mark mirrored calendars unavailable if access was lost — **without**
performing EventKit I/O inline, per 3.18.

---

# Phase 3M — Quality and release criteria

## Required scenarios

In addition to the Phase 1 and Phase 2 scenario lists:

* Grant access on a device with three accounts; every calendar appears, grouped by account, with
  correct colors and read-only badges.
* Create an event in Better Calendar on a device calendar; it appears in Apple Calendar.
* Edit that event in Apple Calendar; it updates in Better Calendar after reconciliation.
* Delete it in Apple Calendar; it disappears locally and does not come back.
* Edit a mirrored recurring series at each of the three scopes; the resulting occurrence set
  matches Apple Calendar's exactly.
* Attempt to edit an event on a read-only calendar; the app prevents it before any local change.
* Revoke access in Settings; the app degrades cleanly and local events remain fully editable.
* Re-grant access; mirrored events reconnect without duplicating.
* Confirm a mirrored event with alarms produces exactly one notification, from the system.
* Verify a video-conference link survives a title-only edit made in Better Calendar.
* Every Phase 1 and Phase 2 test continues to pass unchanged.

## Phase 3 exit criteria

Phase 3 is complete when:

* Every Phase 1 and Phase 2 capability works unchanged with calendar access denied.
* Device calendars are discoverable, selectable, and correctly attributed, with read-only status
  enforced at the model layer rather than in the UI.
* Events flow correctly in both directions, through the outbox in one direction and the
  reconciler in the other, with no path bypassing either.
* No known bug can duplicate, resurrect, or silently destroy a device event, or detach an
  occurrence the user did not ask to detach.
* Conflicts are detected, surfaced, and resolvable, and no local edit is lost to one.
* Mirrored events produce no duplicate notifications.
* The connection-method choice is detected, stored, and honored, with a designed migration path
  for Phase 5 to change it.
* The full Phase 3 matrix runs in CI against the fake event store on every pull request, and the
  device checklist in 3.38 has been executed and recorded.
* Every migration is proven against fixture databases from every previously released schema
  version.
* Diagnostics report authorization state, per-calendar mirror state, last reconciliation time and
  result, and outbox depth including conflicted and failed rows.

Once Phase 3 is stable, Phase 4 can add the Better Calendar account and cloud synchronization by
writing a second adapter behind the same outbox — and the fact that the pipeline already carries
one real provider, with real failures and real conflicts, is what will make that second one
tractable.
