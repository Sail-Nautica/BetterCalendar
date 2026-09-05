# ADR 0011 — What makes two calendars the same calendar, and what happens to the one that loses (spec 3.28–3.30)

- **Status:** Accepted
- **Date:** 2026-09-05
- **Scope:** Phase 3F
- **Relates to:** `Instructions/phase3f_specification.md`, `Instructions/phase3_specification.md`
  §3.28–§3.30,
  `Better Calendar/Domain/Engine/DuplicateConnectionDetector.swift`,
  `Better Calendar/Domain/Engine/ConnectionMethodMigrationPlanner.swift`,
  `Better Calendar/Domain/Engine/DuplicateDetector.swift`

## Context

A Google calendar may already appear in EventKit because the user added their Google account in
iOS Settings, and in Phase 5 Better Calendar may *also* connect to that account directly.
Synchronising both independently produces duplicate events, duplicate notifications, and edits
that fight each other.

Phase 3 cannot solve that — the second transport does not exist yet — but spec 3.29 requires the
detection and the storage now, because retrofitting them after Phase 5 means migrating live user
data on a schema never designed for it. Three decisions were needed.

## Decision 1 — Connection identity is provider + account name + calendar name, and it is weak on purpose

The obvious identity is an identifier, and every identifier available is wrong for this:
`EKCalendar.calendarIdentifier` is EventKit's, Google's calendar id is Google's, and
`EKSource.sourceIdentifier` is device-local. None survives a change of transport, which is the
only situation this rule exists for.

So identity is composed from the three things that *do* survive: the `provider` (ADR 0004's
ownership axis), the account's name, and the calendar's own name — case- and whitespace-folded,
and nothing cleverer. "Work" and "work" are one calendar; "Work" and "Work Calendar" are two, and
guessing otherwise hides a calendar the user still has.

Two consequences follow from admitting the identity is weak rather than pretending otherwise:

* **A group is a candidate, never a conclusion.** Spec 2.15's "never merge silently" applies with
  more force here than anywhere else in Phase 3, because the thing being merged is a whole
  calendar. The detector surfaces a choice; it never makes one.
* **ADR 0007's narrow CalDAV attribution is load-bearing here.** That decision said a CalDAV
  source is `.google` only on positive evidence, never by elimination, and reasoned that a wrong
  `.otherAccount` is cosmetic while a wrong `.google` "becomes a false match in Phase 3F's
  duplicate-connection rule". This is that rule, and the prediction was right: `provider` is part
  of the key, so a mis-attribution silently hides a calendar.

## Decision 2 — Two fields carry the answer, not one

`connectionMethod` records *how* a calendar is reached and is the whole answer in Phase 5, where
the choice is between two genuinely different transports.

It is not enough in Phase 3, because the only reachable case is the degenerate one — the same
account configured twice on the device — where both rows carry `.device` and that field cannot say
which of them won. So `isSupersededByDuplicateConnection` (v024) records the losing side, with
`duplicateConnectionResolvedAt` beside it so the detector can tell "not yet asked" from "asked,
and this is the answer" and stop re-prompting.

A superseded calendar mirrors nothing (`fetchableCalendars` excludes it), writes nothing (refused
at the model layer with its own `CapabilityViolation` reason, not merely hidden from the pickers),
and appears nowhere but `SRC-CONN-01`.

**It is never deleted.** Its events, visibility and sort order all survive, and because the
bounded-window rule refuses to delete from a calendar no pass fetched (ADR 0008, Decision 4), they
are retained and hidden exactly as spec 3.26 requires. Changing the answer restores everything.

## Decision 3 — Changing the choice re-keys; it does not re-import

Spec 3.29 says changing the connection is "a **migration**, not a toggle". The distinction is not
pedantic: delete-and-re-import loses every local id, and with it every undo action holding one,
every `ConflictIndex` entry keyed by one, and the identity every `EventVersion` row points at.

`ConnectionMethodMigrationPlanner` produces the re-key as one pure transaction. An event on both
sides is merged onto the winner's row and the loser's is retired with a tombstone; an event only
the losing connection had is **moved**, keeping its local id, with its old provider identity
cleared so the new transport treats it as something to push rather than as something it already
has under a foreign identifier.

Nothing in Phase 3 calls it. It ships tested so Phase 5 inherits a designed path rather than an
improvised one, which is exactly what spec 3.29 asked for.

## The part that is not hypothetical

Spec 3.30 asks for cross-provider duplicate detection against a transport that does not exist yet.
Implementing it surfaced a duplicate that exists **today**: Phase 1's ICS import writes the RFC
5545 `UID` to `providerObjectID`, while Phase 3C's mirror writes `calendarItemExternalIdentifier`
to `providerExternalID` — and for a CalDAV or Google calendar those are the same string.
`DuplicateDetector` compared only object id to object id, so re-importing an ICS file over
mirrored events gave the user two of everything.

The new `sameEventDifferentTransport` reason compares both fields in both directions. It is the
Phase 5 mechanism and the Phase 3 bug fix at once, which is the best argument for having built the
mechanism now.

## Non-decisions

- **`sources()` finally exists.** Spec 3.2 sketched it and Phase 3B deferred it, correctly: every
  consumer there wanted the source *of a calendar*. The duplicate rule compares accounts, and an
  account with no calendars on it still has something to compare.
- **`SRC-CONN-01` offers a choice with one real option.** The direct connection arrives in Phase 5,
  and the copy says so rather than implying a choice the app cannot honour. Spec 3.29 anticipated
  this: "exercise the prompt with fixtures."
