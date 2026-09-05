import Foundation

/// Spec 3.29 (3F.1/3F.2): recognising that two calendar rows reach the *same underlying calendar*
/// through different transports.
///
/// Pure, and deliberately conservative. A group this returns is a **candidate**, never a
/// conclusion: spec 2.15's "never merge silently" applies with more force here than anywhere else
/// in Phase 3, because the thing being merged is a whole calendar rather than one event.
enum DuplicateConnectionDetector {

    /// What makes two calendars the same calendar when every identifier they carry is different.
    ///
    /// None of the stored identifiers survive a change of transport — EventKit's
    /// `calendarIdentifier` is EventKit's, Google's calendar id is Google's, and
    /// `EKSource.sourceIdentifier` is device-local. So identity is composed from the three things
    /// that *are* stable across transports, and it is weak on purpose.
    struct CalendarConnectionIdentity: Hashable {
        /// Who owns the data (ADR 0004's two-axis model). Part of the key, which is why ADR 0007
        /// attributed CalDAV to Google only on positive evidence: a calendar wrongly attributed
        /// to `.google` becomes a false match here, and a false match hides a calendar the user
        /// still has.
        var provider: EventProvider
        var accountKey: String
        var calendarKey: String

        /// `nil` for a calendar with no account — a local Better Calendar calendar has no
        /// connection to duplicate.
        init?(_ calendar: BetterCalendar) {
            guard let accountName = calendar.accountName?.normalizedConnectionKey, !accountName.isEmpty else { return nil }
            let calendarName = calendar.name.normalizedConnectionKey
            guard !calendarName.isEmpty else { return nil }

            provider = calendar.provider
            accountKey = accountName
            calendarKey = calendarName
        }
    }

    /// Two or more calendar rows that appear to be one calendar reached more than once.
    struct DuplicateGroup: Equatable, Identifiable {
        var identity: CalendarConnectionIdentity
        /// In display order, and never fewer than two.
        var calendars: [BetterCalendar]

        var id: CalendarConnectionIdentity { identity }

        /// Whether the user has already answered for this group. A group where exactly one row is
        /// active and the rest are superseded has been decided; one where every row is active has
        /// not.
        var isResolved: Bool {
            calendars.contains { $0.isSupersededByDuplicateConnection }
                || calendars.allSatisfy { $0.duplicateConnectionResolvedAt != nil }
        }

        /// The row still in use, if the choice has been made.
        var chosen: BetterCalendar? {
            let active = calendars.filter { !$0.isSupersededByDuplicateConnection }
            return active.count == 1 ? active.first : nil
        }
    }

    /// Two accounts that look like the same account configured twice.
    ///
    /// Spec 3.2 reserved `sources()` for this phase and 3B was right to defer it: a source with no
    /// calendars has nothing to list or toggle, but it does have something to *compare*. This is
    /// the degenerate case that makes the whole rule reachable in Phase 3 at all — someone who
    /// added a Google account both as "Google" and as a generic CalDAV account.
    struct DuplicateAccount: Equatable {
        var title: String
        var sourceIdentifiers: [String]
    }

    /// Groups of calendar rows sharing a connection identity.
    ///
    /// - Parameter includingResolved: when false (the default), groups the user has already
    ///   answered for are omitted — that is what stops `SRC-CONN-01` asking the same question
    ///   every launch. `SRC-CONN-01` itself passes `true` to list decisions already made.
    static func duplicateGroups(among calendars: [BetterCalendar], includingResolved: Bool = false) -> [DuplicateGroup] {
        let grouped = Dictionary(grouping: calendars.compactMap { calendar -> (CalendarConnectionIdentity, BetterCalendar)? in
            CalendarConnectionIdentity(calendar).map { ($0, calendar) }
        }, by: \.0)

        return grouped
            .compactMap { identity, pairs -> DuplicateGroup? in
                let members = pairs.map(\.1).sorted { $0.sortOrder < $1.sortOrder }
                // A group of one is not a group.
                guard members.count > 1 else { return nil }
                let group = DuplicateGroup(identity: identity, calendars: members)
                return includingResolved || !group.isResolved ? group : nil
            }
            .sorted { ($0.identity.accountKey, $0.identity.calendarKey) < ($1.identity.accountKey, $1.identity.calendarKey) }
    }

    /// Accounts that appear more than once under different source identifiers.
    static func duplicateAccounts(among sources: [DeviceCalendarSource]) -> [DuplicateAccount] {
        Dictionary(grouping: sources) { $0.title.normalizedConnectionKey }
            .compactMap { title, group -> DuplicateAccount? in
                let identifiers = Set(group.map(\.identifier)).sorted()
                guard identifiers.count > 1, !title.isEmpty else { return nil }
                return DuplicateAccount(title: group.first?.title ?? title, sourceIdentifiers: identifiers)
            }
            .sorted { $0.title < $1.title }
    }

    /// The transaction that records the user's answer: one row stays, the rest are superseded.
    ///
    /// Nothing is deleted. Superseding is a choice, and a choice the user can change — so the
    /// losing rows keep their events, their visibility and their sort order, and un-superseding
    /// restores all of it.
    static func resolution(for group: DuplicateGroup, keeping chosenID: UUID, now: Date) -> EngineTransaction {
        let changes: [EntityChange] = group.calendars.compactMap { calendar in
            var updated = calendar
            updated.isSupersededByDuplicateConnection = calendar.id != chosenID
            updated.duplicateConnectionResolvedAt = now
            guard updated != calendar else { return nil }
            updated.updatedAt = now
            updated.versionNumber = calendar.versionNumber + 1
            return .upsertCalendar(updated)
        }

        return changes.isEmpty ? .empty : EngineTransaction(entityChanges: changes)
    }
}

private extension String {
    /// Case- and whitespace-folding, and nothing cleverer. "Work" and "work" are the same
    /// calendar; "Work" and "Work Calendar" are not, and guessing otherwise is how a calendar the
    /// user still has gets hidden.
    var normalizedConnectionKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
