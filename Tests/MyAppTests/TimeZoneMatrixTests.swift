import XCTest
@testable import Better_Calendar

/// Spec 2.16's "Time zone" bullet list. Most of it is already covered elsewhere —
/// `CalendarEngineTests` has DST-preserving recurrence, a single secondary-zone display
/// conversion, and (implicitly) all-day device-zone independence: an all-day event's display
/// date always comes from `calendarInOriginalTimeZone` (the event's *own* stored zone), never
/// from `Calendar.current`, so there is no code path through which a device zone change could
/// shift it — nothing here re-proves that structural guarantee. What's actually missing is a
/// *travel* scenario spanning three distinct zones (not one hand-picked pair) and
/// `refreshForSystemTimeChange`'s own effect.
final class TimeZoneMatrixTests: XCTestCase {

    // MARK: - Three-zone travel (spec 2.16: "dual-time display computes correctly for a travel
    // scenario spanning three time zones")

    func testDualTimeDisplayConvertsEachLegOfAThreeZoneTripCorrectly() {
        let events = TestData.threeZoneTravelEvents()
        let newYorkMeeting = events[0]
        let londonMeeting = events[1]
        let tokyoMeeting = events[2]

        // Each meeting, viewed from the other two zones on the trip.
        XCTAssertEqual(newYorkMeeting.startTime(displayedIn: "Europe/London"), formattedTime(newYorkMeeting.startDate, in: "Europe/London"))
        XCTAssertEqual(newYorkMeeting.startTime(displayedIn: "Asia/Tokyo"), formattedTime(newYorkMeeting.startDate, in: "Asia/Tokyo"))

        XCTAssertEqual(londonMeeting.startTime(displayedIn: "America/New_York"), formattedTime(londonMeeting.startDate, in: "America/New_York"))
        XCTAssertEqual(londonMeeting.startTime(displayedIn: "Asia/Tokyo"), formattedTime(londonMeeting.startDate, in: "Asia/Tokyo"))

        XCTAssertEqual(tokyoMeeting.startTime(displayedIn: "America/New_York"), formattedTime(tokyoMeeting.startDate, in: "America/New_York"))
        XCTAssertEqual(tokyoMeeting.startTime(displayedIn: "Europe/London"), formattedTime(tokyoMeeting.startDate, in: "Europe/London"))
    }

    /// The identity case a travel scenario should never disturb: each leg displayed back in its
    /// own storage zone must equal its own local wall-clock time.
    func testEachLegDisplayedInItsOwnStorageZoneMatchesItsOwnLocalTime() {
        for meeting in TestData.threeZoneTravelEvents() {
            XCTAssertEqual(meeting.startTime(displayedIn: meeting.timeZoneIdentifier), formattedTime(meeting.startDate, in: meeting.timeZoneIdentifier))
        }
    }

    private func formattedTime(_ date: Date, in zoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: zoneIdentifier)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - refreshForSystemTimeChange (spec 1.2/2.16: a device time-zone change picked up
    // while the app is suspended must be reflected on resume)

    /// Nothing about a stored event changes when the device's time zone changes — every timed
    /// display recomputes from the same UTC instant + the event's own zone, and every all-day
    /// display already ignores the device zone entirely (see the type doc comment). What
    /// actually has to happen is that every view depending on "the current device zone" gets a
    /// reason to re-render, which is exactly what bumping `environmentRevision` provides —
    /// `AppRootView` wires `refreshForSystemTimeChange()` to the system's time-zone-change
    /// notification for precisely this.
    @MainActor
    func testRefreshForSystemTimeChangeBumpsEnvironmentRevisionSoViewsRecomputeDisplayedTimes() {
        let repository = StubCalendarRepository(loadResult: .success(TestData.database()))
        let store = BetterCalendarStore(repository: repository, notificationScheduler: NoopNotificationScheduler())
        let revisionAfterLoad = store.environmentRevision

        store.refreshForSystemTimeChange()

        XCTAssertGreaterThan(store.environmentRevision, revisionAfterLoad)
    }
}
