# Better Calendar: Detailed Phase 0 and Phase 1 Specification

The purpose of these two phases is to create a reliable calendar foundation before introducing Google Calendar, Apple Calendar, Gmail, U-M, cloud synchronization, or AI scheduling.

* **Phase 0** defines what the product is, how calendar data behaves, and how the codebase will be organized.
* **Phase 1** produces a complete offline iPhone calendar that stores and manages Better Calendar events locally.

---

# Phase 0 — Product, Architecture, and Data Foundation

## Phase 0 objective

At the end of Phase 0, the team should have:

* A defined product scope
* A documented calendar data model
* A working iPhone project and local database
* Technical rules for dates, time zones, recurrence, reminders, and deletion
* Wireframes for the primary calendar screens
* A testing strategy
* A list of requirements for future Google, Apple, Gmail, U-M, and cloud integrations

There does not need to be a complete usable calendar yet, but the architectural decisions must be implemented sufficiently to prove they work.

---

## 0.1 Define the product identity

### Product promise

Better Calendar should be positioned as:

> A unified calendar and planning system that combines events, school schedules, tasks, travel time, email-derived commitments, and intelligent time blocking across Apple devices.

The initial differentiation should come from:

1. Faster schedule creation
2. Better visualization of busy and free time
3. Integration of tasks and calendar blocks
4. Student-specific planning
5. U-M integration
6. Consistent behavior across iPhone, Mac, iPad, and Apple Watch
7. Later Gmail-assisted scheduling
8. Explainable automatic rescheduling

### Initial target user

The first version should target one primary user profile:

* University student
* Uses an iPhone and Mac
* Has personal and university Google accounts
* Manages classes, assignments, meetings, workouts, travel, and personal events
* Frequently reschedules flexible work
* Wants one view of personal and academic commitments

Other audiences can be supported later, but designing for everyone immediately would make Phase 1 unfocused.

### Product terminology

Establish consistent terminology before writing interface text:

* **Event:** A scheduled commitment at a defined time
* **Task:** Something that must be completed
* **Time block:** Reserved time in which a task will be worked on
* **Calendar:** A container controlling event ownership, color, and visibility
* **Account:** A Better Calendar, Google, Apple, U-M, or future Microsoft identity
* **Reminder:** A notification before or at an event
* **Schedule suggestion:** A proposed change that has not yet been applied
* **Conflict:** Two or more commitments overlapping in a meaningful way

These definitions should be documented in the repository so interface, backend, and database terminology stay consistent.

---

## 0.2 Define Phase 1 boundaries

Phase 1 should include only locally owned Better Calendar data.

### Included

* Local calendars
* Local events
* Recurring events
* Multiple reminders
* Search
* Day, week, month, and agenda views
* All-day events
* Time-zone support
* Local notifications
* ICS import and export
* Offline use
* Undo for destructive actions

### Explicitly excluded

* Google Calendar synchronization
* Apple EventKit synchronization
* Better Calendar accounts
* Cloud backup
* Cross-device synchronization
* Gmail access
* U-M SSO
* Attendee invitations
* Meeting-room booking
* Apple Watch app
* Widgets
* AI scheduling
* Shared calendars

The internal model should anticipate these features, but Phase 1 should not expose incomplete versions of them.

---

## 0.3 Establish product requirements

Each major requirement should receive a stable identifier.

Example:

```text
BC-EVT-001: User can create a timed event.
BC-EVT-002: User can create an all-day event.
BC-REC-001: User can create a daily recurring event.
BC-NOT-001: User can assign multiple reminders.
BC-VIEW-001: User can view events by day.
BC-SRCH-001: User can search event titles, locations, and notes.
```

Use requirement identifiers in:

* GitHub issues
* Pull requests
* Test cases
* Design files
* Bug reports
* Release notes

### Product-level success criteria

Set measurable internal goals:

* A basic event can be created in no more than two screens.
* Moving an event should update the interface immediately.
* The application must function without internet access.
* No valid local event should disappear after force-closing the application.
* Recurring-event edits must clearly distinguish one occurrence from the entire series.
* All-day events must remain on the same calendar date when the device time zone changes.
* Timed events must display the correct local time when the device time zone changes.

These are engineering acceptance targets rather than App Store promises.

---

## 0.4 Create the repository and project structure

Use a native SwiftUI application with shared packages for business logic. SwiftUI provides the application lifecycle, navigation, state-management integration, gestures, drag-and-drop support, localization, and accessibility APIs that will later be shared across Apple platforms. ([Apple Developer][1])

### Recommended repository structure

```text
BetterCalendar/
├── Apps/
│   └── BetterCalendariOS/
├── Packages/
│   ├── CalendarDomain/
│   ├── CalendarDatabase/
│   ├── CalendarUI/
│   ├── CalendarNotifications/
│   ├── CalendarImportExport/
│   └── CalendarTestSupport/
├── Tests/
│   ├── DomainTests/
│   ├── DatabaseTests/
│   ├── RecurrenceTests/
│   ├── NotificationTests/
│   └── UITests/
├── Documentation/
│   ├── Architecture/
│   ├── DataModel/
│   ├── ProductRequirements/
│   └── Decisions/
└── BetterCalendar.xcworkspace
```

### Package responsibilities

**CalendarDomain**

Contains pure Swift models and business rules:

* Event validation
* Recurrence calculation
* Date-range calculation
* Conflict detection
* Reminder validation
* Calendar visibility
* Event mutation commands

It should not import SwiftUI or contain database code.

**CalendarDatabase**

Contains:

* SQLite connection
* Database migrations
* Record definitions
* Queries
* Transactions
* Search index
* Repository implementations

**CalendarUI**

Contains reusable controls:

* Event cards
* Calendar grids
* Date headers
* Event editor fields
* Time selectors
* Color selectors
* Empty states

**CalendarNotifications**

Contains:

* Notification permission handling
* Notification scheduling
* Notification cancellation
* Notification reconciliation

**CalendarImportExport**

Contains:

* ICS parser
* ICS generator
* Import validation
* Duplicate detection

### Architecture pattern

Use a feature-oriented variation of MVVM:

```text
SwiftUI View
    ↓
Feature ViewModel
    ↓
Use Case / Command
    ↓
Repository Protocol
    ↓
SQLite Repository
```

Views should never contain SQL, recurrence calculations, or direct notification scheduling.

---

## 0.5 Choose local persistence

Use SQLite with GRDB for the main local database.

GRDB is a Swift toolkit built around SQLite and is suitable for an application that needs direct control over schemas, migrations, queries, and database observation. ([GitHub][2])

### Why direct SQLite control matters

A calendar eventually needs:

* Compound indexes
* Full-text search
* Transactional event changes
* Deleted-object tombstones
* Provider identifiers
* Sync journals
* Recurrence exceptions
* Database migrations
* Efficient date-range queries

The database schema should therefore be treated as a permanent product interface.

### Initial database tables

```text
calendars
events
event_recurrence_rules
event_recurrence_exceptions
event_reminders
event_attachments
event_links
event_tags
event_search
pending_mutations
deleted_objects
application_settings
schema_metadata
```

Some tables, such as `pending_mutations`, will be minimally used in Phase 1 but will become essential for synchronization.

### Migration rules

Every schema modification must be represented as a named migration:

```text
v001_create_calendars
v002_create_events
v003_create_reminders
v004_create_recurrence
v005_create_search_index
```

Rules:

* Never modify an already released migration.
* Test migration from every previously released schema.
* Run migrations within transactions where possible.
* Back up the database before a destructive migration.
* Include fixture databases from older versions in automated tests.

---

## 0.6 Define calendar ownership

Every event must have one authoritative owner.

For Phase 1:

```text
provider = betterCalendarLocal
providerAccountID = null
providerCalendarID = internal calendar ID
providerObjectID = internal event ID
```

Future values may include:

```text
google
eventKit
betterCalendarCloud
microsoft
caldav
```

### Ownership rules

* An event belongs to exactly one calendar.
* A calendar belongs to exactly one provider account or to the local application.
* Editing an event must update its authoritative source.
* A provider-derived event should never silently become a Better-owned event.
* Copying an event creates a new event with a new identifier.
* Moving an event between incompatible providers should later be implemented as copy-plus-delete with explicit confirmation.

These rules prevent event duplication when Google calendars are available both through EventKit and through the Google Calendar API.

---

## 0.7 Define the calendar schema

### Calendar record

```text
CalendarRecord
- id: UUID
- provider: ProviderType
- providerAccountID: UUID?
- providerCalendarID: String?
- name: String
- colorHex: String
- isVisible: Bool
- isReadOnly: Bool
- isDefault: Bool
- timeZoneID: String?
- sortOrder: Int
- createdAt: Date
- updatedAt: Date
- deletedAt: Date?
```

### Calendar rules

* Only one local calendar may be the default.
* A calendar cannot be deleted while it still owns events without a user decision.
* Deleting a calendar must offer:

  * Delete calendar and events
  * Move events to another calendar
  * Cancel
* Hidden calendars remain stored and searchable only when the user explicitly includes hidden calendars.
* Calendar colors must pass contrast checks in both light and dark mode.

---

## 0.8 Define the event schema

### Core event record

```text
EventRecord
- id: UUID
- calendarID: UUID
- provider: ProviderType
- providerObjectID: String?
- providerVersion: String?

- title: String
- notes: String?
- locationName: String?
- locationLatitude: Double?
- locationLongitude: Double?
- url: String?

- eventType: timed | allDay | floating
- startInstant: Date?
- endInstant: Date?
- startLocalDate: String?
- endLocalDateExclusive: String?
- originalTimeZoneID: String?

- availability: busy | free | tentative
- status: confirmed | tentative | cancelled
- privacy: default | public | private
- colorOverride: String?

- recurrenceMasterID: UUID?
- recurrenceOriginalStart: Date?
- isRecurrenceMaster: Bool

- createdAt: Date
- updatedAt: Date
- deletedAt: Date?
```

### Validation rules

* Title should default to “New Event” only after saving; an entirely blank unsaved editor can be discarded.
* Timed events require `startInstant` and `endInstant`.
* All-day events require local dates rather than UTC instants.
* End must be later than start.
* Zero-duration events may be supported as markers, but they should be visually distinct.
* URLs must be validated but not restricted only to web links.
* Notes should support plain text initially.
* Phase 1 should establish a reasonable field limit, such as:

  * Title: 500 characters
  * Location: 1,000 characters
  * Notes: 50,000 characters

---

## 0.9 Define time semantics

This is the most important Phase 0 design decision.

Foundation provides `Calendar`, `DateComponents`, and `TimeZone` for calculating and interpreting calendar dates in specific time zones. Better Calendar should use those APIs rather than manually adding seconds to represent days or months. ([Apple Developer][3])

### Timed events

A timed event represents actual instants.

Example:

```text
Class meeting
Start instant: 2026-09-03T14:00:00Z
End instant:   2026-09-03T15:00:00Z
Original zone: America/Detroit
```

Store:

* UTC start instant
* UTC end instant
* Original IANA time-zone identifier

When displayed in another zone, the clock time changes but the instant does not.

### All-day events

An all-day event represents calendar dates, not UTC instants.

Example:

```text
Fall Break
Start local date: 2026-10-12
End local date exclusive: 2026-10-14
```

This represents October 12 and October 13.

Do not store an all-day event as midnight UTC. Doing so can shift the displayed date when the user travels.

### Floating events

A floating event occurs at the same wall-clock time regardless of location.

Example:

```text
Take medication at 8:00 PM wherever I am
```

Store local date components rather than an absolute instant. Phase 1 can model floating events internally even if the interface does not initially expose them.

### Device time-zone changes

When the time zone changes:

* Timed events recalculate their displayed clock time.
* All-day events remain on the same date.
* Floating events retain their local clock time.
* The visible calendar should refresh immediately.
* Scheduled notifications must be reconciled.

---

## 0.10 Define recurrence

Base the internal recurrence representation on iCalendar recurrence concepts rather than inventing a proprietary format. RFC 5545 defines iCalendar events, date and date-time values, recurrence rules, time zones, alarms, attendees, and other calendar properties independently of a particular calendar provider. ([RFC Editor][4])

### Recurrence-rule record

```text
RecurrenceRule
- id: UUID
- eventID: UUID
- frequency: daily | weekly | monthly | yearly
- interval: Int
- daysOfWeek: [Weekday]?
- daysOfMonth: [Int]?
- monthsOfYear: [Int]?
- weekStart: Weekday
- count: Int?
- untilInstant: Date?
- untilLocalDate: String?
- setPositions: [Int]?
- rawRRule: String?
```

Apple’s EventKit recurrence model also uses frequency, interval, recurrence end, weekday, month, week-number, and position concepts, making an RFC-aligned model easier to map later. ([Apple Developer][5])

### Recurrence architecture

Store:

* One master event
* One recurrence rule
* Zero or more exceptions
* Zero or more canceled occurrences

Do not permanently generate thousands of event rows.

### Exception record

```text
RecurrenceException
- id: UUID
- masterEventID: UUID
- originalOccurrenceStart
- exceptionType: modified | cancelled
- replacementEventID: UUID?
```

### Required edit scopes

When a recurring occurrence is edited, present:

* This event only
* This and future events
* All events

Phase 1 may initially support “this event only” and “all events,” but the schema must support future splitting.

### Test cases

Include:

* Every weekday
* Every other week
* Last Friday of each month
* Monthly event beginning on January 31
* Leap-day yearly event
* Recurrence across daylight-saving transitions
* Single modified occurrence
* Single deleted occurrence
* Recurrence with an end date
* Recurrence with a count
* All-day recurrence

---

## 0.11 Define reminder behavior

### Reminder record

```text
EventReminder
- id: UUID
- eventID: UUID
- triggerType: relative | absolute
- offsetSeconds: Int?
- absoluteInstant: Date?
- deliveryMethod: localNotification
- isEnabled: Bool
- notificationIdentifier: String
```

Examples:

```text
At time of event        = 0
10 minutes before       = -600
1 hour before           = -3600
1 day before            = -86400
```

### Notification rules

* Request notification permission only when the user first enables a reminder or during a clearly explained onboarding step.
* Each reminder receives a stable notification identifier.
* Editing an event cancels and recreates affected pending requests.
* Deleting an event cancels all associated requests.
* App startup should reconcile database reminders with pending system notifications.
* Notifications for recurring events should be scheduled within a rolling future window rather than attempting to schedule an unlimited series.

Apple’s User Notifications framework supports locally scheduled requests, calendar-based triggers, recurring triggers, and explicit cancellation of pending requests. ([Apple Developer][6])

---

## 0.12 Define deletion and undo

Do not immediately remove records from the database.

### Soft-delete behavior

Set:

```text
deletedAt = current timestamp
```

The event should immediately disappear from normal views, but remain recoverable during the undo period.

### Undo transaction

When an event is deleted or moved:

1. Apply the database transaction.
2. Display an undo banner.
3. Retain the inverse operation.
4. If Undo is selected, apply the inverse transaction.
5. If the application closes, retain soft-deleted data for a cleanup period.

### Future synchronization compatibility

A `deleted_objects` table should contain:

```text
objectID
objectType
provider
providerObjectID
deletedAt
deletionSyncedAt
```

This later prevents a remotely synchronized event from reappearing after local deletion.

---

## 0.13 Establish privacy and security requirements

Even without cloud synchronization, calendar information is sensitive.

### Phase 0 requirements

* Store the database inside the application sandbox.
* Use iOS data-protection capabilities for stored files.
* Do not include event titles, notes, or locations in analytics.
* Redact private information from crash logs.
* Do not print event objects in production logs.
* Create a logging wrapper with privacy classifications.
* Separate diagnostic IDs from user content.
* Include a “Delete all local data” function for testing and later user controls.

### Analytics allowed in Phase 1

Examples:

```text
calendar_view_opened
event_creation_started
event_saved
event_deleted
search_performed
notification_permission_result
ics_import_result
```

Do not transmit:

```text
event title
event notes
event location
search query
attendee name
calendar name
```

---

## 0.14 Design the interface system

### Navigation structure

Use a simple iPhone navigation structure:

```text
Main Calendar Screen
├── View selector
├── Date navigation
├── Calendar visibility
├── Search
├── Settings
└── Add event
```

Recommended main tabs:

* Calendar
* Agenda
* Search

Tasks should not receive a tab until the task system exists.

### Design tokens

Define:

* Spacing scale
* Corner radii
* Typography roles
* Event-card minimum height
* Calendar-grid line weight
* Light and dark backgrounds
* Selected-date style
* Current-time indicator
* Conflict style
* Disabled/read-only style
* Calendar color palette

### Accessibility specification

* Support Dynamic Type without clipped event titles.
* Give event cards explicit accessibility labels containing title, time, calendar, and conflict state.
* Do not communicate calendar identity through color alone.
* Provide VoiceOver actions for edit, move, duplicate, and delete.
* Maintain adequate touch-target sizes.
* Support Reduce Motion.
* Test with VoiceOver, Voice Control, and Switch Control.

SwiftUI provides automatic accessibility behavior for standard controls and modifiers for custom labels, values, hints, and navigation, but custom calendar grids still require explicit accessibility work. ([Apple Developer][7])

---

## 0.15 Establish test infrastructure

### Unit tests

Test:

* Event validation
* Date intervals
* All-day date handling
* Time-zone conversion
* Recurrence expansion
* Recurrence exceptions
* Reminder calculations
* Conflict detection
* Search normalization
* ICS parsing
* ICS generation

### Database tests

Test:

* Every migration
* Transaction rollback
* Soft deletion
* Undo
* Date-range queries
* Search-index consistency
* Cascade behavior
* Duplicate prevention

### Snapshot and UI tests

Test:

* Empty day
* Busy day
* Overlapping events
* Multi-day events
* Large Dynamic Type
* Dark mode
* Recurring-event editor
* Notification-permission states
* Search results
* All-day overflow

### Fixture calendars

Create deterministic test datasets:

* Empty calendar
* Normal university week
* Extremely busy day
* Overnight events
* Travel across time zones
* Daylight-saving transition
* Multi-month recurrence
* 10,000-event stress calendar

---

## Phase 0 exit criteria

Phase 0 is complete when:

* Product requirements are documented.
* The Xcode workspace builds successfully.
* Database migrations run on a clean installation.
* Calendar and event records can be inserted and queried.
* Timed and all-day events are represented differently.
* Recurrence rules can generate occurrences in unit tests.
* A local notification can be scheduled from a test event.
* Primary screen wireframes are approved.
* Architecture decisions are documented.
* Test fixtures exist for recurrence and time-zone edge cases.

---

# Phase 1 — Offline iPhone Calendar MVP

## Phase 1 objective

Create a polished iPhone application that can completely manage locally stored Better Calendar events without internet access or an account.

The user should be able to:

* Create calendars
* Create events
* Browse their schedule
* Search events
* Receive reminders
* Edit recurring events
* Import and export ICS files
* Recover from accidental deletion
* Use the application with accessibility features

---

# Phase 1A — Application shell and onboarding

## 1.1 Application launch

On first launch:

1. Create the database.
2. Run migrations.
3. Create a default calendar named “Calendar.”
4. Select a default calendar color.
5. Determine the device locale, calendar system, time zone, and preferred first weekday.
6. Display a brief local-only onboarding screen.
7. Open the current day.

### First-launch messaging

Explain:

* Events are currently stored only on this device.
* Google, Apple Calendar, and cloud synchronization will be added in later phases.
* Notification permission will be requested only when reminders are enabled.

Do not imply that local events are backed up.

## 1.2 Main navigation

The primary calendar screen should contain:

* Current date
* Today button
* Previous/next navigation
* Day/week/month selector
* Calendar visibility button
* Search button
* Add-event button
* Swipe navigation between adjacent periods

Persist:

* Last selected view
* Last selected date
* Visible calendars
* Preferred week start
* Hour-format preference

---

# Phase 1B — Local calendar management

## 1.3 Calendar list

Create a calendar-management screen showing:

* Calendar name
* Color
* Visibility
* Number of future events
* Default-calendar status
* Edit button

### Actions

* Create calendar
* Rename calendar
* Change calendar color
* Hide or show calendar
* Set default
* Reorder calendars
* Delete calendar

### Delete-calendar flow

When the calendar contains events:

```text
Delete “School”?
42 events belong to this calendar.

[Move Events]
[Delete Calendar and Events]
[Cancel]
```

A default calendar cannot be deleted until another default is selected.

---

# Phase 1C — Event creation and editing

## 1.4 Quick-create flow

Tapping the add button should open a compact editor with:

* Title
* Start
* End
* All-day toggle
* Calendar
* Save

Additional fields should be behind “More Options.”

### Default values

* Start: next sensible time boundary, such as the next 30-minute mark
* Duration: one hour
* Calendar: current default
* Time zone: current device zone
* Availability: busy
* Reminder: user’s default reminder, if configured

### Save behavior

* Saving must feel instantaneous.
* Write the event and reminder records in one database transaction.
* Update the visible calendar immediately.
* Schedule notifications after the transaction succeeds.
* If notification scheduling fails, save the event but display a non-blocking warning.

## 1.5 Full event editor

Fields:

1. Title
2. All-day toggle
3. Start date and time
4. End date and time
5. Time zone
6. Repeat
7. Calendar
8. Location
9. URL or meeting link
10. Notes
11. Availability
12. Privacy
13. Color override
14. Reminders
15. Attachments placeholder, hidden until implemented
16. Delete action when editing an existing event

### Validation behavior

* End time automatically follows start time while preserving duration.
* If the user manually changes the end, stop automatically preserving duration.
* If end precedes start, show an inline error and disable Save.
* Converting a timed event to all-day should preserve the local start date.
* Converting an all-day event to timed should use the user’s default start time and duration.
* Unsaved changes should trigger a discard confirmation.

---

# Phase 1D — Calendar views

## 1.6 Day view

### Layout

* All-day section at top
* Vertical hourly timeline
* Current-time indicator
* Event cards positioned by start and duration
* Optional mini-date strip
* Floating add button

### Overlap algorithm

For overlapping events:

1. Group events into connected overlap clusters.
2. Assign each event a column.
3. Expand an event horizontally when adjacent columns are available.
4. Retain a minimum readable width.
5. Display a condensed indicator when too many events overlap.

### Interaction

* Tap empty time to create an event at that time.
* Tap an event to view details.
* Long-press to initiate move.
* Drag event vertically to change time.
* Drag top or bottom handle to resize.
* Haptic feedback at 15- or 30-minute boundaries.
* Auto-scroll while dragging near the top or bottom.

### Acceptance targets

* Smooth scrolling across a full day
* No overlapping event-card text
* Overnight events displayed correctly
* Current-time indicator refreshed while the app is active

---

## 1.7 Week view

### iPhone design

Use a horizontally scrollable or compressed multi-day timeline.

Possible compact behavior:

* Portrait: three-day or adaptive week view
* Landscape: full seven-day view
* Pinch or menu control for density
* All-day row fixed above the timeline

### Interaction

* Swipe horizontally between weeks.
* Tap date header to open day view.
* Drag events between days.
* Show weekend based on user preference.
* Display conflicts visibly.
* Preserve vertical scroll position when moving between nearby dates.

The full seven-day portrait layout should not be forced if event titles become unreadable.

---

## 1.8 Month view

### Month-cell contents

Each date cell should display:

* Day number
* Today indicator
* Selected-date indicator
* Up to a limited number of event markers
* Overflow count
* Distinction between all-day and timed events

### Interaction

* Tap date to select it.
* Show the selected day’s events below the month grid.
* Swipe between months.
* Long-press a date to create an event.
* Tap an event preview to open details.

### Multi-day events

Display them as continuous bars where space permits. If a bar crosses a week boundary, break its visual segment while preserving consistent color and labeling.

---

## 1.9 Agenda view

The agenda is a chronological list grouped by date.

### Requirements

* Infinite or paginated scrolling
* Sticky date headers
* All-day events before timed events
* Empty-day handling
* Searchable event content
* Calendar color indicator
* Quick actions
* “Today” jump
* Past-event visual de-emphasis

### Performance

Load records by date range rather than reading the entire database. Prefetch the next range as the user approaches the end.

---

# Phase 1E — Event details and actions

## 1.10 Event-detail screen

Display:

* Title
* Date and time
* Time zone when relevant
* Calendar
* Location
* Notes
* URL
* Recurrence summary
* Reminders
* Availability
* Created and last-edited times where useful

Actions:

* Edit
* Duplicate
* Move to calendar
* Share as text
* Export as ICS
* Delete
* Open location
* Open URL

### Duplicate behavior

Duplicating an event:

* Creates a new UUID.
* Removes any provider identifiers.
* Copies fields and reminders.
* Defaults to the same start and end.
* Allows editing before saving.

---

# Phase 1F — Recurring events

## 1.11 Recurrence editor

### Basic presets

* Never
* Every day
* Every week
* Every two weeks
* Every month
* Every year
* Every weekday
* Custom

### Custom editor

Allow:

* Frequency
* Interval
* Weekdays
* Day of month
* Monthly positional rule
* End never
* End after a count
* End on a date

### Human-readable summary

Always display a generated summary:

```text
Every 2 weeks on Monday and Wednesday
Ends after 12 occurrences
```

### Editing occurrence behavior

When the user edits an occurrence:

```text
Edit recurring event

[This Event]
[All Events]
[Cancel]
```

When deleting:

```text
Delete recurring event

[This Event]
[All Events]
[Cancel]
```

A modified occurrence should become an exception attached to the recurrence master.

---

# Phase 1G — Reminders and notifications

## 1.12 Reminder editor

Preset options:

* At time of event
* 5 minutes before
* 10 minutes before
* 15 minutes before
* 30 minutes before
* 1 hour before
* 2 hours before
* 1 day before
* 1 week before
* Custom

Allow multiple reminders.

### Custom reminders

Support:

* Minutes
* Hours
* Days
* Weeks
* Before or at event

For all-day events, establish a default alert time such as 9:00 a.m., configurable in settings.

### Permission handling

If permission is denied:

* Keep reminder records attached to events.
* Display that reminders are disabled at the system level.
* Provide a button that opens the application’s system settings.
* Do not repeatedly prompt the user.

### Reconciliation process

Run reconciliation:

* On app launch
* When the app becomes active
* After an event is changed
* After a time-zone change
* After notification settings change

---

# Phase 1H — Search

## 1.13 Search index

Index:

* Title
* Location
* Notes
* Calendar name
* URL host
* Tags when added

Use an SQLite full-text-search table rather than loading every event into Swift memory.

SwiftUI’s searchable interface APIs can provide the system search field and manage search presentation, while the underlying database should perform the actual event queries. ([Apple Developer][8])

### Search interface

Support:

* Free-text query
* Date range
* Calendar filter
* Past/future filter
* All-day filter
* Recurring-event filter

### Ranking

Recommended order:

1. Exact title match
2. Title prefix
3. Title contains
4. Location match
5. Notes match
6. Calendar-name match

For equally relevant events, sort future events before past events.

### Privacy

Search terms should remain local and should not be included in analytics or logs.

---

# Phase 1I — Dragging, resizing, and undo

## 1.14 Move event

When dragging:

* Display a floating time label.
* Snap to the selected interval.
* Allow temporary override of snapping.
* Show the destination date.
* Indicate conflicts.
* Do not save continuously during the drag.
* Commit one transaction when the event is dropped.

### Cancel behavior

Dragging back to the original position or dismissing the gesture should make no database change.

## 1.15 Resize event

* Top handle modifies start.
* Bottom handle modifies end.
* Enforce minimum duration.
* Preserve the opposite endpoint.
* Update conflict display during resize.
* Commit after release.

## 1.16 Undo system

Support undo for:

* Delete
* Move
* Resize
* Change calendar
* Duplicate
* Bulk visibility changes where practical

The undo banner should identify the action:

```text
“Calculus Review” moved to 7:30 PM.    Undo
```

---

# Phase 1J — Time-zone features

## 1.17 Time-zone settings

Provide:

* Device time zone
* Event’s original time zone
* Optional secondary time zone
* Time-zone search
* “Lock event to this time zone” behavior

### Travel behavior

When device time zone changes:

```text
Event created:
8:00 PM America/Detroit

Device changes to America/Los_Angeles:
Display as 5:00 PM
```

All-day events must not shift dates.

### Dual-time display

For travel-related events, optionally show:

```text
5:00 PM local
8:00 PM Detroit
```

This can be hidden by default in Phase 1 but should be supported by the view model.

---

# Phase 1K — ICS import and export

## 1.18 ICS import

Import flow:

1. User opens or shares an `.ics` file.
2. Parse the file locally.
3. Validate its components.
4. Display an import preview.
5. Let the user select the destination calendar.
6. Identify possible duplicates.
7. Import within a transaction.
8. Display imported, skipped, and failed counts.

### Import requirements

Support initially:

* VEVENT
* DTSTART
* DTEND
* DURATION
* SUMMARY
* DESCRIPTION
* LOCATION
* URL
* UID
* RRULE
* EXDATE
* RECURRENCE-ID
* VALARM
* TZID

Preserve unsupported properties in a raw metadata field where feasible so exporting does not unnecessarily destroy information.

## 1.19 ICS export

Allow exporting:

* One event
* One recurring series
* A date range
* An entire local calendar

Generate standards-compatible iCalendar content based on RFC 5545. ([RFC Editor][9])

---

# Phase 1L — Settings

## 1.20 Calendar settings

Include:

* Default calendar
* Default event duration
* Default reminder
* First day of week
* Show weekends
* Time format
* Default calendar view
* Time-zone override
* All-day reminder time
* Event snap interval
* Appearance
* Reduce calendar animation
* Export data
* Delete all local data

### Developer diagnostics

In debug or beta builds:

* Database schema version
* Pending notification count
* Event count
* Recurrence-master count
* Exception count
* Database export
* Notification reconciliation
* Load sample calendar
* Reset database

Do not expose sensitive diagnostics in production without safeguards.

---

# Phase 1M — Performance and reliability

## 1.21 Performance targets

Use internal targets such as:

* Cold launch to usable calendar: under two seconds on supported devices
* Event save reflected in interface: under 100 milliseconds
* Day-range query: under 100 milliseconds for typical data
* Search response: under 200 milliseconds for 10,000 events
* Smooth scrolling without loading all historical events
* No recurrence expansion beyond the requested visible range

These are design targets that should be validated on real lower-end supported devices.

## 1.22 Data integrity

Every event write should use a transaction covering:

* Event
* Recurrence rule
* Reminders
* Exceptions
* Search index
* Mutation journal

If any mandatory operation fails, roll back the complete change.

Notification scheduling occurs after the database commit because system-notification operations are outside the SQLite transaction. Failed notification scheduling should be retried through reconciliation.

## 1.23 Crash recovery

On launch:

1. Open the database.
2. Run migrations.
3. Check database integrity.
4. Recover incomplete import operations.
5. Reconcile notification requests.
6. Remove expired undo records.
7. Refresh the current date and time zone.
8. Load only the initial visible date range.

---

# Phase 1N — Quality and release criteria

## Required test scenarios

Before Phase 1 is complete, verify:

* Event starts before midnight and ends after midnight.
* Event spans multiple days.
* All-day event remains unchanged after a time-zone switch.
* Timed event displays correctly after a time-zone switch.
* Recurrence crosses a daylight-saving boundary.
* February 29 yearly recurrence behaves correctly.
* Monthly recurrence begins on the 29th, 30th, or 31st.
* One recurring occurrence is edited.
* One recurring occurrence is deleted.
* Event has multiple reminders.
* Notification permission is denied.
* Event is moved while offline.
* Calendar containing events is deleted.
* ICS file contains an unknown time zone.
* ICS import contains duplicate UIDs.
* Search includes accented characters.
* Dynamic Type is set to the largest size.
* VoiceOver can navigate events in chronological order.
* Database migrates from every previous Phase 1 beta.

## Phase 1 exit criteria

Phase 1 is complete when:

* All functionality works without an account or network connection.
* Users can create, edit, delete, duplicate, move, and resize events.
* Day, week, month, and agenda views are stable.
* Recurrence and exceptions work correctly.
* Timed and all-day events behave correctly across time zones.
* Notifications are scheduled, canceled, and reconciled.
* Search works against a large local calendar.
* ICS import and export pass compatibility tests.
* Accessibility testing has been completed.
* No known bug can cause silent event loss.
* The app is ready for internal TestFlight distribution.

The result should be a genuinely usable local calendar—not merely a visual prototype. Once this foundation is stable, Phase 2 can connect Apple Calendar through EventKit without forcing a redesign of event identity, recurrence, reminders, or time-zone handling.

[1]: https://developer.apple.com/documentation/swiftui/?lang=en&utm_source=chatgpt.com "SwiftUI | Apple Developer Documentation"
[2]: https://github.com/groue/GRDB.swift?utm_source=chatgpt.com "GitHub - groue/GRDB.swift: A toolkit for SQLite databases, with a focus on application development · GitHub"
[3]: https://developer.apple.com/documentation/Foundation/Calendar?utm_source=chatgpt.com "Calendar | Apple Developer Documentation"
[4]: https://www.rfc-editor.org/rfc/rfc5545.html "www.rfc-editor.org"
[5]: https://docs.developer.apple.com/documentation/eventkit/creating-a-recurring-event?utm_source=chatgpt.com "Creating a recurring event | Apple Developer Documentation"
[6]: https://docs.developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app?utm_source=chatgpt.com "Scheduling a notification locally from your app | Apple Developer Documentation"
[7]: https://developer.apple.com/documentation/swiftui/view-accessibility?changes=_7&utm_source=chatgpt.com "Accessibility modifiers | Apple Developer Documentation"
[8]: https://developer.apple.com/documentation/swiftui/search?language=swift&utm_source=chatgpt.com "Search | Apple Developer Documentation"
[9]: https://www.rfc-editor.org/info/rfc5545/?utm_source=chatgpt.com "RFC 5545: Internet Calendaring and Scheduling Core Object Specification (iCalendar) | RFC Editor"
