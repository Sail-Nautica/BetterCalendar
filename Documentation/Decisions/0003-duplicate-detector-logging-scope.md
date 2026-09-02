# ADR 0003 — Duplicate-detection logging: privacy log, not a new change-journal operation (spec 2.15)

- **Status:** Accepted
- **Date:** 2026-09-02
- **Scope:** Phase 2 M6
- **Relates to:** `Instructions/phase2_specification.md` §2.15 (BC-ENG-007),
  `Better Calendar/Domain/Engine/DuplicateDetector.swift`

## Context

Spec 2.15's last bullet: "Log duplicate-detection decisions to the change journal for
auditability." `ChangeJournalEntry.operation` is a `JournalOperation` (`create`/`update`/`delete`)
backed by a SQLite `CHECK (operation IN ('create', 'update', 'delete'))` on `change_journal`
(migration `v011`). A duplicate-skip decision during `commitImport` doesn't create, update, or
delete anything — the whole point is that nothing was written — so none of the three existing
values describe it, and every other journal entry in the codebase is written *alongside* the
`EntityChange` it describes, in the same transaction. A duplicate-skip entry would be the first
journal row with no corresponding write, which the rest of the journal's design doesn't expect.

Widening the `CHECK` to add a fourth value (e.g. `duplicateDetected`) needs a real migration:
SQLite has no `ALTER TABLE ... ALTER COLUMN`, so the only way to change a `CHECK` constraint is
the rename-rebuild-drop pattern (`ALTER TABLE change_journal RENAME TO change_journal_old`,
`CREATE TABLE change_journal (...)` with the new `CHECK`, copy rows, drop the old table). SQLite's
`ALTER TABLE ... RENAME TO` automatically rewrites every foreign key elsewhere in the schema that
references the renamed table — `event_versions.change_journal_entry_id REFERENCES
change_journal(id)` (migration `v012`) would silently start pointing at `change_journal_old`
instead of the freshly created `change_journal`, unless `event_versions` is *also* rebuilt in the
same migration to point its `REFERENCES` clause back at the right table. That's real schema risk
(a version-history table that is spec 2.9's durable "what did this event look like" record) for a
feature whose own spec section says it's "used both for ICS re-import... and as a general safety
net" with **no UI consumer anywhere in Phase 2**.

## Decision

Duplicate-detection decisions are logged through the existing `PrivacyLog.track(.icsImportResult,
metadata:)` call `commitImport` already makes for import counts (spec 0.13's privacy-log
mechanism, not `change_journal`), extended to append a reason breakdown —
`duplicateReasons=providerUID=1,titleAndTime=2` — alongside the existing `imported=`/`skipped=`/
`failed=` counts. No new migration, no `JournalOperation` case.

`DuplicateDetector.candidates(for:among:)` itself returns every candidate it finds (never
swallows them) regardless of this decision — a future caller with a real reason to persist
per-decision audit history to `change_journal` can do so without touching `DuplicateDetector` at
all, only the schema and whatever calls this function.

## Consequences

- `change_journal` stays exactly what its own doc comment says it is: "the append-only history of
  every entity-level change" — decisions that changed nothing don't appear in it.
- Duplicate-detection auditability is coarser than spec 2.15's literal wording asks for: the
  privacy log records *how many* duplicates were found and *why* (per reason category), not *which*
  existing event each one matched. Good enough for "did dedup do something reasonable during this
  import," not enough to answer "was event X ever detected as a duplicate of event Y."

## Revisit trigger

Revisit when a real consumer needs per-decision duplicate audit history (a diagnostics screen, a
future provider-sync policy that needs to explain a merge decision to the user) — design the
`change_journal` migration against that consumer's actual needs rather than speculatively now, and
rebuild `event_versions`' foreign key in the same migration rather than leaving it silently
pointing at a renamed-away table.
