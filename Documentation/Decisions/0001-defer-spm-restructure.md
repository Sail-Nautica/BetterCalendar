# ADR 0001 — Defer the SPM package restructure (spec 0.4)

- **Status:** Accepted
- **Date:** 2026-08-08
- **Scope:** Phase 0 / Phase 1 completion effort
- **Relates to:** `Instructions/phase0_phase1_specification.md` §0.4,
  `Documentation/ProductRequirements/phase1-backlog.md`

## Context

Spec 0.4 prescribes a multi-package repository layout: an `Apps/BetterCalendariOS`
shell over six local Swift packages (`CalendarDomain`, `CalendarDatabase`,
`CalendarUI`, `CalendarNotifications`, `CalendarImportExport`,
`CalendarTestSupport`), assembled through an `.xcworkspace`.

The codebase today is a single app target with the source organised into
`Domain/`, `Data/`, `Features/`, and `Shared/` folders, plus a `MyAppTests`
unit-test target. GRDB 6.29.3 is the sole external dependency.

The stated purpose of the package split in spec 0.4 is layering enforcement —
in particular the rule that the domain layer "should not import SwiftUI or
contain database code."

## Decision

**The SPM package restructure is deferred.** Phase 1 completion proceeds in the
existing single-target layout with the `Domain/ Data/ Features/ Shared/` folder
structure. This is a known, accepted deviation from spec 0.4 — not an oversight.

## Reasoning

1. **The layering the packages would enforce is already respected.**
   `Domain/CalendarModels.swift` and `Domain/CalendarEngine.swift` import neither
   SwiftUI nor GRDB. The dependency direction the packages exist to guarantee
   already holds; the restructure would convert a convention into a compiler
   constraint without changing any actual dependency edge.

2. **The cost lands entirely on risk, not on capability.** Splitting targets
   touches the project file, the scheme, the test host, and every access modifier
   that currently defaults to internal — each type crossing a new package boundary
   needs explicit `public`. That is a large, mechanical, entirely behaviour-neutral
   diff. The test target was *just* repaired after a project-file breakage
   (stale `TEST_HOST`, stale module name); reopening the project file immediately
   afterwards trades a verified-green baseline for zero functional gain.

3. **Nothing in the remaining Phase 1 backlog is blocked by it.** Recurrence
   exceptions, FTS5 search, the settings layer, ICS completeness, and the
   notification work are all implementable in the current layout. No backlog item
   requires a package boundary to be correct.

4. **The deadline for the split is a real one, and it is later.** Package
   boundaries start paying for themselves when code must be shared across targets —
   a Mac app, an iPad app, a Watch app, or a widget extension. Phase 1 ships none
   of those. Phase 2's EventKit work is additive within the app target.

## Consequences

- Layering remains a **convention**, enforced by review rather than by the
  compiler. A future `import SwiftUI` inside `Domain/` would compile. Reviewers
  must watch for it.
- The repository does not match the spec 0.4 directory diagram. Anyone reading
  spec 0.4 literally will find `Packages/` and `Apps/` absent. This document is
  the explanation.
- `CalendarTestSupport` does not exist as a package; shared fixtures live in
  `Tests/MyAppTests/TestFixtures.swift` and are reachable because the tests are a
  single target.

## Revisit trigger

Revisit **before Phase 3**, or sooner if any of the following becomes true:

- A second Apple-platform target (Mac, iPad, Watch) or an app extension is added.
- A layering violation actually reaches `main` — the convention has then failed
  and needs compiler enforcement.
- The domain or database layer grows to the point where full-target rebuild times
  measurably slow the edit/test loop.

Deferring is cheap to reverse: the folder structure already mirrors the intended
package boundaries, so the split is a mechanical move plus access-modifier work.
