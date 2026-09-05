import Foundation

/// Spec 2.15 (BC-ENG-007): duplicate-event heuristics, used both by ICS re-import
/// (`BetterCalendarStore.commitImport`) and as a general safety net for anything else that
/// creates events from an external description of one. **Never merges silently** — this only
/// ever returns candidates with a confidence score; the caller (today, `commitImport`'s existing
/// skip-on-duplicate policy) decides what to do with them.
enum DuplicateDetector {
    struct Candidate: Equatable {
        var matchedEventID: UUID
        /// 0...1, higher is more likely a genuine duplicate. A provider UID match is always 1.0
        /// (spec 2.15 gives it precedence, independent of how much everything else differs — see
        /// `MatchReason.providerUID`); a heuristic match's score falls off linearly from 1.0 at an
        /// exact field match toward 0.5 at the edge of `timeTolerance`.
        var confidence: Double
        var reason: MatchReason
    }

    enum MatchReason: String, Equatable {
        /// RFC 5545 UID, round-tripped as `providerMetadata.providerObjectID`. Takes precedence
        /// over every other signal: an event whose UID already exists locally is the same event
        /// even if its title or time has since changed underneath it.
        case providerUID
        /// Spec 3.30 (3F.6): the same underlying event reached two ways.
        ///
        /// The insight it encodes is that the *account-level* identifier survives a change of
        /// transport even when the local one does not. For EventKit that is
        /// `calendarItemExternalIdentifier`, which for a CalDAV or Google calendar is derived
        /// from the iCalendar UID — the same string an ICS file carries, and the same string a
        /// direct connection would see.
        ///
        /// This is not only a Phase 5 hypothetical. Phase 1's ICS import writes that UID to
        /// `providerObjectID` while Phase 3C's mirror writes it to `providerExternalID`, so
        /// without this reason re-importing an ICS file over mirrored events gives the user two
        /// of everything — today.
        case sameEventDifferentTransport
        /// `(calendarID, normalizedTitle, startInstant, endInstant)` within `timeTolerance`. Used
        /// for plain events and recurring masters alike — a master's own `startDate`/`endDate` is
        /// a legitimate single-instant identity, the same as any non-recurring event's.
        case titleAndTime
        /// `(recurrenceMasterID, originalStart)` within `timeTolerance`, for per-occurrence
        /// replacement events (BC-REC-010) specifically — spec 2.15's "compare recurrenceMasterID
        /// equivalent fields and originalStart rather than per-occurrence fields." A replacement's
        /// own title/time can differ arbitrarily from what it started as (that's the whole point
        /// of a "This Event" edit), so title+time is not a meaningful identity for one; its slot
        /// in its series is.
        case recurringOccurrence
    }

    /// A small tolerance window (spec 2.15) rather than exact equality — generous enough to
    /// survive an ICS producer that rounds `DTSTART`/`DTEND` to the minute, narrow enough that two
    /// genuinely distinct events an hour apart never collide.
    static let defaultTimeTolerance: TimeInterval = 5 * 60

    /// Every candidate in `existingEvents` that could be the same real-world event as `event`.
    static func candidates(for event: CalendarEvent, among existingEvents: [CalendarEvent], timeTolerance: TimeInterval = defaultTimeTolerance) -> [Candidate] {
        if let uid = event.providerMetadata.providerObjectID {
            let matches = existingEvents.filter { $0.providerMetadata.providerObjectID == uid }
            if !matches.isEmpty {
                return matches.map { Candidate(matchedEventID: $0.id, confidence: 1.0, reason: .providerUID) }
            }
        }

        // Spec 3.30: the same identifier reached through a different transport. Compared in both
        // directions because the two sides store it in different fields — an imported ICS event
        // carries the UID as its object id, a mirrored device event as its external id — and
        // matching only one way would miss exactly the overlap this exists to catch.
        let transportKeys = Set([event.providerMetadata.providerObjectID, event.providerMetadata.providerExternalID].compactMap { $0 }.filter { !$0.isEmpty })
        if !transportKeys.isEmpty {
            let matches = existingEvents.filter { candidate in
                let candidateKeys = Set([candidate.providerMetadata.providerObjectID, candidate.providerMetadata.providerExternalID].compactMap { $0 }.filter { !$0.isEmpty })
                return !candidateKeys.isDisjoint(with: transportKeys)
            }
            if !matches.isEmpty {
                // Spec 2.15's precedence rule generalises: an identifier match is the same event
                // however much else has since diverged. Still a *candidate* — this returns
                // confidence, and never merges (BC-EK-021).
                return matches.map { Candidate(matchedEventID: $0.id, confidence: 1.0, reason: .sameEventDifferentTransport) }
            }
        }

        if let masterID = event.recurrenceMasterID, let originalStart = event.recurrenceOriginalStart {
            return existingEvents.compactMap { candidate -> Candidate? in
                guard candidate.recurrenceMasterID == masterID, let candidateStart = candidate.recurrenceOriginalStart else { return nil }
                let delta = abs(candidateStart.timeIntervalSince(originalStart))
                guard delta <= timeTolerance else { return nil }
                return Candidate(matchedEventID: candidate.id, confidence: confidence(forDelta: delta, tolerance: timeTolerance), reason: .recurringOccurrence)
            }
        }

        let normalizedTitle = normalize(event.title)
        return existingEvents.compactMap { candidate -> Candidate? in
            guard candidate.calendarID == event.calendarID, normalize(candidate.title) == normalizedTitle else { return nil }
            let startDelta = abs(candidate.startDate.timeIntervalSince(event.startDate))
            let endDelta = abs(candidate.endDate.timeIntervalSince(event.endDate))
            guard startDelta <= timeTolerance, endDelta <= timeTolerance else { return nil }
            return Candidate(matchedEventID: candidate.id, confidence: confidence(forDelta: max(startDelta, endDelta), tolerance: timeTolerance), reason: .titleAndTime)
        }
    }

    private static func confidence(forDelta delta: TimeInterval, tolerance: TimeInterval) -> Double {
        guard tolerance > 0 else { return 1.0 }
        return 1.0 - 0.5 * min(delta / tolerance, 1.0)
    }

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
