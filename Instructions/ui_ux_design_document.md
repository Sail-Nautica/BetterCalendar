# Better Calendar: UI/UX Design Document

Native iPhone MVP with a scalable Apple-platform design system

**Scope:** Phase 0 product foundation and Phase 1 offline calendar experience
**Prepared for:** product, design, engineering, and usability testing

Version 1.0 · August 2, 2026

> This is a markdown transcription of `Better_Calendar_UI_UX_Design_Document.docx.pdf`. All text content is preserved; the PDF remains the source of record for the phone-mockup illustrations, which are not reproduced here.

---

## Document Control

| Field | Specification |
|---|---|
| Product | Better Calendar |
| Document | UI/UX Design Document |
| Version | 1.0 |
| Date | August 2, 2026 |
| Primary platform | iPhone / iOS |
| Future platforms | iPadOS, macOS, watchOS |
| MVP scope | Local calendars, events, recurrence, reminders, search, day/week/month/agenda views, ICS import/export |
| Out of scope for this version | Google sync, Apple EventKit sync, Gmail, U-M SSO, cloud accounts, collaboration, AI scheduling |

> **Design intent**
> Better Calendar should feel familiar enough that a first-time iPhone user can operate it immediately, while improving schedule density, free-time visibility, event creation speed, and future task integration.

### How to Use This Document

* Product and design use it to approve scope, hierarchy, terminology, and behavior.
* Engineering uses screen identifiers, component rules, states, and acceptance criteria for implementation.
* Quality assurance converts acceptance criteria and edge states into test cases.
* Usability research uses the task flows and success metrics to create moderated and unmoderated studies.

---

## Contents

1. Experience vision and scope
2. Users and jobs to be done
3. Experience principles
4. Information architecture
5. Navigation model
6. Design system
7. Core screen specifications
8. Interaction patterns
9. States, errors, and recovery
10. Accessibility and inclusive design
11. Responsive platform expansion
12. Usability validation plan
13. Developer handoff and release checklist
- Appendix A — UI copy standards
- Appendix B — Screen inventory
- Appendix C — References

---

## 1. Experience Vision and Scope

### 1.1 Product experience statement

Better Calendar is a calm, high-information calendar that helps users understand what is happening, what time remains, and what action to take next. The interface prioritizes schedule comprehension over decoration and speed over configuration.

### 1.2 Experience outcomes

| Outcome | UX implication | MVP measure |
|---|---|---|
| Understand today instantly | Today, current time, conflicts, and next commitment must dominate hierarchy. | User identifies next event in under 5 seconds. |
| Create events quickly | Quick Add includes only the minimum required fields; advanced options are secondary. | Basic event saved in under 20 seconds. |
| Trust the calendar | Time zones, all-day events, recurrence, and deletion behavior must be transparent. | No silent event loss or unexplained time shifts. |
| Control information density | Views adapt to available width and reveal detail progressively. | Event titles remain readable at supported text sizes. |
| Recover from mistakes | Move, resize, and delete actions support visible undo and clear confirmations. | Common mistakes recoverable without recreating an event. |

### 1.3 MVP design boundaries

* The MVP is offline-first and stores Better Calendar events locally on the iPhone.
* External account connection surfaces are represented only as future placeholders in architecture, not functional controls.
* Tasks and intelligent scheduling are not included; the calendar model leaves space for later time-block overlays.
* The app follows the device's system appearance instead of adding an independent theme selector.
* Advanced settings do not interrupt initial use; defaults are usable without onboarding configuration.

> **Non-negotiable**
> A calendar interface can be visually polished and still fail if recurrence, dates, or undo behavior is ambiguous. Interaction clarity takes priority over visual novelty.

---

## 2. Users and Jobs to Be Done

### 2.1 Primary persona: university power scheduler

| Dimension | Definition |
|---|---|
| Context | A student using iPhone and Mac who manages classes, assignments, meetings, travel, exercise, and personal commitments. |
| Current behavior | Uses Google or Apple Calendar, notes, reminders, email, and mental tracking across separate systems. |
| Needs | Fast creation, dense week comprehension, reliable recurrence, clear schedule conflicts, and simple calendar filtering. |
| Frustrations | Too many taps, weak visualization of free time, duplicate accounts, inconsistent all-day behavior, and lost context when rescheduling. |
| Success | Can confidently answer: What is next? What is fixed? Where is my free time? What changed? |

### 2.2 Core jobs to be done

| Job | Trigger | Desired outcome |
|---|---|---|
| Capture a commitment | A date, class, appointment, or deadline is learned. | Save it before details are forgotten. |
| Plan a day | The user opens the app in the morning or before a work block. | Understand commitments and available time. |
| Change plans | A meeting moves or a study block needs adjustment. | Reschedule safely and see conflicts immediately. |
| Find something | The user remembers partial event information. | Locate the event through one search location. |
| Prepare for an event | A reminder arrives or the next event approaches. | Open time, location, link, and notes with minimal effort. |
| Recover from error | The user deletes, moves, or resizes accidentally. | Undo without rebuilding the event. |

### 2.3 Priority usage contexts

* One-handed use while walking between classes.
* Fast checks from the lock screen or during a conversation.
* Detailed planning while seated, often in landscape or later on iPad/Mac.
* Low-light use at night and high-brightness use outdoors.
* Intermittent or absent network connectivity.

---

## 3. Experience Principles

| # | Principle | Application |
|---|---|---|
| 01 | Schedule first | Navigation, animation, and chrome should recede behind calendar content. |
| 02 | Fast by default | The common path is short; advanced configuration is progressively disclosed. |
| 03 | One action, one result | Every edit has an immediate, visible effect and a clear recovery path. |
| 04 | Time is explicit | Dates, time zones, recurrence scope, and all-day behavior are never inferred invisibly. |
| 05 | Color supports meaning | Color identifies calendars and states, but labels and shapes provide redundant cues. |
| 06 | Gestures are optional accelerators | Every gesture has an onscreen or accessibility alternative. |
| 07 | Density adapts | The interface becomes more compact or detailed based on device size, orientation, and text size. |
| 08 | Future integrations remain attributable | Every event will eventually display its owner and source without changing the base layout. |

Apple's current Human Interface Guidelines emphasize hierarchy, harmony with the platform, and consistency across sizes and displays. Better Calendar applies those principles through native navigation, system typography, adaptive colors, and familiar control behavior. [1]

---

## 4. Information Architecture

```text
Better Calendar Information Architecture

                    Primary App Shell
                          │
        ┌─────────────────┼─────────────────┐
     Calendar           Agenda             Search
        │                  │                  │
      Day               Chronological       Query
      Week              List                Filters
      Month             Date Groups         Results
      Event Detail      Quick Actions

Global: Add Event · Calendars · Settings · Import / Export
```

*Figure 1. Phase 1 information architecture*

### 4.1 Top-level destinations

| Destination | Purpose | Default entry |
|---|---|---|
| Calendar | Spatial schedule views: day, week, and month. | Today in the last-used view. |
| Agenda | Chronological list optimized for scanning and quick actions. | Today, with nearby future events prefetched. |
| Search | Global search and filtering across all local events. | Empty state with recent or suggested filters, not private query history by default. |
| Calendars | Visibility, ownership, color, default selection, and deletion. | Presented as a sheet or secondary navigation destination. |
| Settings | Behavior defaults, display preferences, notifications, data import/export, and diagnostics. | Secondary destination from the profile/settings control. |

### 4.2 Event object hierarchy

1. Calendar views display occurrences, not raw recurrence masters.
2. Selecting an occurrence opens Event Detail with source, time, location, recurrence, and actions.
3. Edit transitions to Event Editor and prompts for recurrence scope when needed.
4. Delete and move actions commit locally, display Undo, then perform notification reconciliation.
5. Search results open the same Event Detail screen to preserve consistent behavior.

---

## 5. Navigation Model

### 5.1 Primary navigation

Use a bottom tab bar with Calendar, Agenda, and Search. The currently selected destination is persistent. Add Event is a prominent contextual action, not a fourth destination.

| Element | Behavior | Rationale |
|---|---|---|
| Tab bar | Persistent on primary screens; hidden in full-screen editors when necessary. | Keeps the three highest-frequency destinations one tap away. |
| View switcher | Segmented Day / Week / Month control inside Calendar. | Changes representation without changing destination. |
| Today action | Returns to current date; first tap selects today, second tap may center current time. | Supports rapid temporal recovery. |
| Add Event | Floating or toolbar action, consistent on Calendar and Agenda. | High-frequency action receives strong visual priority. |
| Calendars | Toolbar control opens a visibility and ownership sheet. | Filtering should not displace the current view. |
| Settings | Secondary toolbar or menu action. | Low-frequency configuration remains accessible but quiet. |

### 5.2 Navigation behavior

* Horizontal swipes move between adjacent days, weeks, or months only when they do not conflict with nested horizontal controls.
* Back navigation preserves scroll position and selected date.
* Modals are used for focused creation, editing, filters, and destructive confirmations.
* Deep links should open the event detail or target date, then preserve normal back behavior.
* Search is treated as a single global location because the product's content is conceptually unified. Apple's search guidance recommends a primary, clearly scoped search location when search is important. [5]

---

## 6. Design System

### 6.1 Visual personality

* Calm rather than playful: neutral surfaces, limited accent usage, and restrained motion.
* Dense but not cramped: information appears compactly while maintaining readable spacing and touch targets.
* Native but distinctive: system patterns with a recognizable Better Blue accent and clear calendar-color language.
* Trustworthy: destructive actions, sync ownership, and recurrence scope use explicit language.

### 6.2 Color tokens

| Token | Hex / system role | Use |
|---|---|---|
| Better Blue | `#4F7CFF` | Primary action, selected state, current date, focus accent. |
| Better Blue Dark | `#315BD8` | Text on pale blue surfaces and emphasized links. |
| Navy | `#17233C` | Primary text and high-emphasis headers. |
| Ink | `#1D2433` | Body text. |
| Secondary Gray | `#5D6678` | Metadata and supporting labels. |
| Border | `#D9DEEA` | Dividers, card outlines, and inactive controls. |
| Surface | System background / `#F5F7FB` reference | Grouped fields and subtle depth. |
| Success | `#2FA96B` | Confirmed or completed state. |
| Warning | `#E68A2E` | Potential conflict or attention state. |
| Destructive | `#D94C4C` | Delete, cancellation, and errors. |

Implementation should prefer semantic system colors for backgrounds and text, with custom colors supplied in light, dark, and increased-contrast variants. Apple recommends system colors where possible and warns against using color as the only differentiator. [3]

### 6.3 Calendar color behavior

* Calendar color appears as a leading rail or dot, not a full saturated background for every event.
* Timed event cards use a pale tint derived from the calendar color with high-contrast text.
* All-day events may use a stronger fill because they occupy less vertical space.
* Conflict state adds an icon, outline, or label; it does not rely on red tint alone.
* At least eight curated colors should be tested in light, dark, and increased-contrast settings.

### 6.4 Typography

| Role | Recommended style | Usage |
|---|---|---|
| Large title | Large Title / Title 1 | Date or destination title where space permits. |
| Section title | Title 2 / Title 3 | Agenda date groups and modal titles. |
| Event title | Headline or Body Semibold | Primary event identification. |
| Event metadata | Subheadline or Footnote | Time, location, calendar, recurrence. |
| Control label | Body / Callout | Buttons, segmented controls, form rows. |
| Micro label | Caption 1 | All-day, time-grid labels, secondary annotations. |

Use the system font and Dynamic Type text styles. Layouts must adapt across all supported text sizes rather than scaling a fixed pixel specification. Apple's typography guidance specifically recommends testing layouts at larger accessibility sizes and minimizing truncation. [4]

### 6.5 Spacing and sizing

| Token | Value | Use |
|---|---|---|
| 4 | 4 pt | Micro gaps and icon/text optical correction. |
| 8 | 8 pt | Tight component spacing. |
| 12 | 12 pt | Event-card internal spacing. |
| 16 | 16 pt | Standard screen margin and grouped rows. |
| 24 | 24 pt | Section separation. |
| 32 | 32 pt | Major modal or empty-state separation. |
| 44 minimum | 44 x 44 pt | Baseline interactive touch target. |
| 56 | 56 pt | Primary floating action diameter target. |

### 6.6 Components

| Component | Specification |
|---|---|
| Event card | Leading calendar rail, title, time, optional location, optional status icon. Minimum visible height supports one-line title and time. |
| All-day chip | Compact rounded rectangle, calendar tint, one-line label, overflow behavior. |
| Date header | Day/date, optional weather or secondary information later, Today state, selected state. |
| Segmented view switcher | Day / Week / Month, persistent within Calendar. |
| Time grid | Hour labels, subtle lines, current-time rule, optional 15/30-minute snap markers during interaction. |
| Form row | Label left, current value right, disclosure or inline control where appropriate. |
| Undo banner | Action summary plus Undo; never obscures the primary Save or destructive confirmation. |
| Filter chip | Compact, removable, and labeled with active scope. |
| Empty state | Short explanation, primary action, optional illustration; no blame-oriented wording. |
| Conflict badge | Icon plus text or outline, with details available on selection. |

### 6.7 Iconography and motion

* Use SF Symbols for standard calendar, search, add, location, link, reminder, recurrence, visibility, and navigation actions.
* Use filled symbols only for selected states or high-priority actions; use consistent rendering modes.
* Motion should clarify continuity: date-page transitions, event movement, editor presentation, and undo recovery.
* Respect Reduce Motion by replacing spatial transitions with fades or immediate state changes.
* Haptics confirm drop, snap boundary, save, and destructive completion, but are not required to understand state.

---

## 7. Core Screen Specifications

The following screens define the Phase 1 experience. Each specification includes purpose, information hierarchy, interactions, states, and acceptance criteria.

### 7.1 Day View · `CAL-DAY-01`

**Purpose**
Provide the clearest representation of today or a selected date, emphasizing current time, overlaps, event duration, and available gaps.

**Primary actions**
* Navigate dates
* Return to today
* Open event
* Create at selected time
* Drag or resize event
* Switch calendar view

**Content hierarchy**
* Date title and view switcher
* All-day row
* Time grid and current-time indicator
* Timed event cards
* Persistent Add Event action
* Primary tab bar

**Interaction rules**
* Tap empty time to prefill Quick Add
* Tap event for Event Detail
* Long-press and drag to move
* Drag resize handles after selection
* Snap to 15 or 30 minutes with haptic feedback
* Auto-scroll near viewport edges

**States**
* Empty day
* Past date
* Today with current-time rule
* Overlapping cluster
* Overnight event
* Large text simplified layout
* Hidden calendars excluded

**Acceptance criteria**
* Next event is identifiable within five seconds
* No event card text overlaps another card
* Movement commits only on drop
* All drag actions have edit-form alternatives
* Current-time rule updates while active

### 7.2 Month View · `CAL-MONTH-01`

**Purpose**
Support date-oriented planning, recurring-pattern recognition, and rapid movement between a month overview and a selected day's agenda.

**Primary actions**
* Move between months
* Select date
* Open event
* Create event on date
* Jump to today
* Switch to day view

**Content hierarchy**
* Month and year
* Weekday labels
* Calendar grid
* Today and selected states
* Event markers or bars
* Selected-day agenda

**Interaction rules**
* Tap date to select
* Second tap or event tap opens detail/day view
* Swipe horizontally between months
* Long-press date to create
* Continuous bars represent multi-day events where space permits

**States**
* Month with no events
* High-density month
* Selected date with no events
* Multi-day event crossing week boundary
* Large text list-forward layout

**Acceptance criteria**
* Selected date is distinct from Today
* Events do not rely on dots alone at accessibility sizes
* Month navigation preserves selected day where valid
* Overflow count is actionable

### 7.3 Quick Add · `EVT-QUICK-01`

**Purpose**
Capture a basic event rapidly without forcing the user through every possible property.

**Primary actions**
* Enter title
* Adjust start/end
* Toggle all-day
* Select calendar
* Set a reminder
* Open More Options
* Save or cancel

**Content hierarchy**
* Title receives initial focus
* When group
* Calendar
* Reminder
* More Options
* Save action

**Interaction rules**
* Default start is the next sensible boundary
* Default duration is user-configured, initially one hour
* Changing start preserves duration until end is manually edited
* Save is enabled when date validation passes
* Keyboard action can submit

**States**
* Blank draft
* Validation error
* Notification permission not granted
* Unsaved changes
* Recurring preset selected
* Natural-language parsing future placeholder

**Acceptance criteria**
* Basic event can be saved in under 20 seconds
* No more than five primary field groups before More Options
* Cancel on untouched draft dismisses immediately
* Invalid end time is explained inline

### 7.4 Full Event Editor · `EVT-EDIT-01`

**Purpose**
Provide complete event control while maintaining scannable grouping and clear save, cancel, recurrence, and deletion behavior.

**Primary actions**
* Edit all event properties
* Change recurrence
* Add multiple reminders
* Move calendar
* Save
* Delete

**Content hierarchy**
* Title
* When
* Repeat
* Calendar
* Place and link
* Reminders
* Availability and privacy
* Notes
* Destructive action

**Interaction rules**
* Rows open inline controls or focused pickers
* Unsaved changes prompt on dismissal
* Recurring occurrence prompts for edit scope
* Converting all-day/timed preserves the most reasonable local date and duration
* Delete requires scope selection for recurring events

**States**
* New event
* Existing event
* Read-only future provider event
* Modified occurrence
* Validation error
* Notification permission denied

**Acceptance criteria**
* Field groups remain understandable at large Dynamic Type
* Save result is visible immediately
* Recurring scope language is explicit
* Destructive control is visually separated

### 7.5 Search · `SRCH-01`

**Purpose**
Find any local event from one clearly identified location using text, date, calendar, and event-type filters.

**Primary actions**
* Enter query
* Apply or remove filters
* Open result
* Clear query
* Return to previous destination

**Content hierarchy**
* Search field
* Scope/filter chips
* Suggestions or recent filters
* Ranked results
* Empty/no-result guidance

**Interaction rules**
* Search begins after a short debounce
* Exact and title matches rank ahead of notes
* Future results rank ahead of equally relevant past results
* Filter state is visible and removable
* Private query history is not shown by default

**States**
* Initial empty state
* Typing
* Results
* No results
* Index unavailable/rebuilding
* Large result set with pagination

**Acceptance criteria**
* Results appear within the performance target
* Current scope is always visible
* Query text is never logged or analyzed remotely
* VoiceOver reads result title, time, calendar, and location

### 7.6 Calendar Manager · `CAL-MGR-01`

**Purpose**
Control calendar visibility, naming, color, ordering, default ownership, and deletion without losing context in the current schedule view.

**Primary actions**
* Show or hide calendar
* Create calendar
* Rename
* Change color
* Set default
* Reorder
* Delete or move owned events

**Content hierarchy**
* Calendar group
* Color indicator
* Name and ownership state
* Visibility toggle
* Default status
* Add action
* Local-only explanation

**Interaction rules**
* Visibility changes preview immediately
* Done commits preference state
* Default calendar cannot be deleted without replacement
* Deleting a populated calendar offers move, delete-all, or cancel
* Color selection includes non-color labels

**States**
* Single calendar
* Many calendars
* Hidden calendar
* Default calendar
* Calendar containing events
* No calendars after data reset

**Acceptance criteria**
* Visibility is reversible
* Ownership is explicit
* No calendar deletion silently deletes events
* Color contrast passes both appearances

### 7.7 Week View · `CAL-WEEK-01`

| Area | Specification |
|---|---|
| Purpose | Compare commitments and free time across several days while retaining enough event detail to support planning. |
| Portrait behavior | Use an adaptive three-day or horizontally paged week representation if a seven-day grid becomes unreadable. |
| Landscape behavior | Display all seven days with a persistent all-day row and shared vertical time scale. |
| Navigation | Swipe between periods, tap a date header for Day View, use Today to recover current week. |
| Event movement | Drag vertically to change time and horizontally to change day; announce destination date and time during accessibility interaction. |
| Density | Allow compact and comfortable density later, but use one validated default in Phase 1. |
| Acceptance | Event titles remain legible; horizontal and vertical scrolling do not compete unexpectedly; selected date remains identifiable. |

### 7.8 Agenda · `AGD-01`

| Area | Specification |
|---|---|
| Purpose | Present a chronological, list-based schedule optimized for scanning, large text, and quick actions. |
| Grouping | Sticky date headers; all-day events first; timed events in chronological order. |
| Loading | Fetch bounded date ranges and prefetch as the user approaches the end. |
| Quick actions | Open, edit, duplicate, move, and delete through context menus or swipe actions with button alternatives. |
| Past events | Visually de-emphasize without reducing contrast below accessibility requirements. |
| Empty days | Omit by default; optionally display a concise free-day marker when navigating a selected range. |
| Acceptance | Scrolling remains smooth with 10,000-event fixture; VoiceOver order matches chronology; Today jump is always available. |

### 7.9 Event Detail · `EVT-DETAIL-01`

| Area | Specification |
|---|---|
| Purpose | Provide a readable summary and launch point for all event actions. |
| Header | Calendar color/source, title, time, and status. |
| Content | Location, URL, notes, recurrence summary, reminders, availability, and future provider ownership. |
| Primary actions | Edit, open link, open location, duplicate, move, share, export, delete. |
| Recurring occurrence | Show both occurrence date and recurrence summary; actions must prompt for scope where required. |
| Privacy | Do not surface private notes in screenshots, widgets, or notification previews unless the user allows it. |
| Acceptance | The next useful action is accessible without scrolling on typical events; every row has a meaningful accessibility label. |

### 7.10 Recurrence Editor · `REC-01`

| Area | Specification |
|---|---|
| Presets | Never, daily, weekly, every two weeks, monthly, yearly, weekdays, custom. |
| Custom fields | Frequency, interval, weekdays, monthly rule, end never, end after count, end on date. |
| Summary | Generate human-readable text such as "Every 2 weeks on Monday and Wednesday, ends after 12 occurrences." |
| Scope prompt | Use This Event, This and Future Events when supported, All Events, and Cancel. |
| Danger prevention | Show the number or range of affected occurrences when it can be calculated safely. |
| Acceptance | Summary updates as fields change; impossible rules are blocked or explained; daylight-saving behavior is not described misleadingly. |

### 7.11 Reminder Editor · `REM-01`

| Area | Specification |
|---|---|
| Presets | At time, 5/10/15/30 minutes, 1/2 hours, 1 day, 1 week, custom. |
| Multiple reminders | Show ordered rows; Add Reminder action remains available until a reasonable product limit is reached. |
| All-day behavior | Use a configurable alert clock time and clearly state the resulting date/time. |
| Permission denied | Retain the reminder configuration, show disabled system status, and offer Open Settings. |
| Acceptance | No repeated permission prompting; removing a reminder cancels its pending notification; time-zone changes trigger reconciliation. |

### 7.12 Settings · `SET-01`

| Group | Settings |
|---|---|
| Defaults | Default calendar, duration, reminder, all-day alert time. |
| Calendar display | First day of week, show weekends, default view, snap interval. |
| Time | 12/24-hour display follows locale by default, time-zone override, optional secondary zone. |
| Accessibility | Reduce calendar animation; most accessibility behavior follows system settings rather than duplicating them. |
| Data | Import ICS, export calendar/date range, delete all local data. |
| About | Version, privacy, acknowledgments, feedback. |
| Diagnostics | Debug/TestFlight only: schema version, event count, notification reconciliation, sample data. |

---

## 8. Interaction Patterns

### 8.1 Tap, press, drag, and keyboard behavior

| Action | Primary behavior | Alternative |
|---|---|---|
| Tap event | Open Event Detail. | VoiceOver Activate. |
| Tap empty time | Open Quick Add prefilled with selected date/time. | Add button, then choose start time. |
| Long-press event | Enter move/resize mode or open context menu based on target. | Edit form with explicit date/time controls. |
| Drag event | Move; preview date/time and conflicts; commit on drop. | Edit start/end fields. |
| Resize handle | Change start or end with snapping. | Edit start/end fields. |
| Swipe period | Move to adjacent day/week/month. | Previous and next buttons. |
| Swipe list row | Reveal quick actions. | Context menu or Event Detail actions. |
| External keyboard | Command shortcuts for add, search, today, and view switching on iPad/Mac later. | Onscreen controls. |

Apple's accessibility guidance recommends using simple gestures for common interactions and providing alternatives to gestures. Better Calendar therefore treats gestures as accelerators rather than the only way to complete an action. [2]

### 8.2 Drag-and-drop state model

1. Press establishes selection and displays movement affordance.
2. The event lifts visually and retains a ghost at its original position.
3. A floating label announces proposed date and time.
4. Conflict preview updates as the event crosses occupied intervals.
5. Snap boundaries provide subtle haptic feedback.
6. Drop commits one database transaction; cancel returns to the original state without writing.
7. An Undo banner identifies the event and new time.

### 8.3 Save and dismissal

| Situation | Behavior |
|---|---|
| Untouched new event | Cancel dismisses immediately. |
| Modified unsaved event | Dismissal asks Keep Editing or Discard Changes. |
| Successful save | Editor dismisses; destination view scrolls to or highlights the saved occurrence. |
| Database failure | Editor remains open with values preserved and a recoverable error. |
| Notification failure | Event saves; nonblocking warning explains reminders may not fire until permission or reconciliation succeeds. |
| Recurring edit | Scope is selected before commit, not after. |

---

## 9. States, Errors, and Recovery

### 9.1 State inventory

| State | Presentation | Required action |
|---|---|---|
| Loading | Prefer skeleton or immediate cached content; avoid blocking spinner for local queries. | None unless load exceeds threshold. |
| Empty calendar | Explain local-only state and show Add Event. | Create event or import ICS. |
| No search results | Repeat active scope and offer filter removal. | Edit query or clear filters. |
| Permission denied | Explain system-level impact and offer Settings link. | Open Settings or continue without reminders. |
| Validation error | Inline near the field plus summary if offscreen. | Correct field; preserve all input. |
| Import partial success | Show imported, skipped, and failed counts with details. | Review or export failure report later. |
| Database recovery | Use plain language; preserve a backup if possible. | Retry, export diagnostics, or reset only as last resort. |
| Destructive confirmation | Name the object and consequence. | Confirm or cancel. |
| Undo available | Temporary banner with action description. | Undo or allow expiry. |

### 9.2 Error-copy rules

* State what happened in user language, not framework terminology.
* State whether the event was saved, not saved, or partially completed.
* Provide one primary recovery action when possible.
* Preserve entered data after recoverable errors.
* Do not blame the user or use vague labels such as "Unknown error."
* Do not expose event content in diagnostic identifiers.

### 9.3 Destructive action examples

| Action | Recommended title | Body / options |
|---|---|---|
| Delete event | Delete "Calculus Review"? | This removes the event from this device. Delete / Cancel. |
| Delete recurring occurrence | Delete recurring event | This Event / All Events / Cancel. |
| Delete calendar with events | Delete "School"? | Move 42 events / Delete calendar and events / Cancel. |
| Delete all data | Delete all local calendar data? | This cannot be undone after the confirmation period. Export Data / Delete / Cancel. |

---

## 10. Accessibility and Inclusive Design

Accessibility is a release criterion, not a post-MVP enhancement. Apple's guidance recommends supporting substantially larger text, simple interactions, gesture alternatives, Voice Control, and recoverability for difficult actions. [2]

### 10.1 Dynamic Type

* Support all iOS Dynamic Type sizes, including accessibility categories.
* At large sizes, convert dense grids into simplified cards or list-forward layouts rather than clipping text.
* Allow event titles to wrap where view density permits; retain full content in Event Detail.
* Scale meaningful SF Symbols with text styles.
* Avoid fixed-height form rows when text may wrap.

### 10.2 VoiceOver and Voice Control

| Element | Accessibility behavior |
|---|---|
| Event card | Single grouped element by default: title, start/end, calendar, location, conflict status. Custom actions: Open, Edit, Move, Delete. |
| Time grid | Hour labels are navigational landmarks; empty time slots should not become hundreds of unnecessary focus stops. |
| Month cell | Read date, today/selected state, event count, and first event summaries; activate to select or open list. |
| Calendar color | Announce calendar name and visibility, not color alone. |
| Drag operation | Provide Move Event action with date/time picker; announce preview changes when direct manipulation is used. |
| Recurrence scope | Buttons use complete labels and explain the affected series. |
| Custom controls | Provide accessibility label, value, hint, traits, and predictable focus order. |

### 10.3 Contrast, color, and appearance

* Use semantic text and background colors wherever possible.
* Test light, dark, increased-contrast, and differentiate-without-color settings.
* Use calendar rails, labels, icons, patterns, or outlines in addition to hue.
* Respect system Dark Mode instead of forcing a separate app preference. Apple advises apps to respond to the system appearance and to verify both light and dark designs. [6]
* Target strong contrast for small calendar text; avoid pale text placed directly on saturated calendar fills.

### 10.4 Motor and cognitive accessibility

* Minimum interactive target should generally be 44 x 44 points, with additional spacing between adjacent destructive and confirm actions.
* Avoid time-limited actions except Undo; provide enough duration and an alternative recovery path.
* Use consistent placement for Save, Cancel, Today, and Add Event.
* Keep recurring-event language concrete and show examples or summaries.
* Avoid exposing too many simultaneous controls in the quick path.
* Support Reduce Motion and avoid unnecessary parallax or continuous animation.

---

## 11. Responsive Platform Expansion

### 11.1 iPadOS

| Pattern | Adaptation |
|---|---|
| Navigation | Three-column NavigationSplitView: calendar list, main schedule, inspector/detail. |
| Week view | Full seven-day grid in most orientations with drag-and-drop and hover/pointer states. |
| Event editor | Form in an inspector or resizable sheet while retaining schedule context. |
| Multitasking | Layouts adapt in Split View and Stage Manager; avoid assuming full-screen width. |
| Keyboard | Add event, search, today, view switching, date navigation, and save shortcuts. |
| Pencil | Optional direct selection and event creation; no Pencil-only functionality. |

### 11.2 macOS

| Pattern | Adaptation |
|---|---|
| Windowing | Multiple windows, resizable sidebars, persistent inspector, remembered window state. |
| Navigation | Sidebar and toolbar replace bottom tabs; command menu exposes all major actions. |
| Quick Add | Global shortcut and menu-bar entry point. |
| Interaction | Pointer hover, right-click context menus, drag-and-drop, keyboard-first editing. |
| Density | More columns and persistent metadata; user-adjustable sidebar and agenda widths. |
| System integration | Spotlight indexing, share extension, printable views, meeting-link menu bar item later. |

### 11.3 watchOS

| Pattern | Adaptation |
|---|---|
| Primary job | Glance at next event and today's agenda; take one immediate action. |
| Hierarchy | Time, title, location/link, and countdown; minimal secondary metadata. |
| Actions | Join, directions, accept/decline later, mark task complete later, snooze reminder. |
| Input | Dictation and App Intents for quick event capture. |
| Accessibility | Larger default text and limited scrolling; support at least 140 percent enlargement per Apple guidance. [2] |
| Complications | Next event, time until next event, and current focus block in later phases. |

### 11.4 Cross-platform continuity rules

* Terminology and event ownership remain identical across platforms.
* Calendar colors, recurrence summaries, and conflict language remain consistent.
* Platform-native navigation replaces forced visual sameness.
* The same event identifier deep-links to the appropriate local presentation.
* Editing behavior and recurrence scope remain logically equivalent even when controls differ.

---

## 12. Usability Validation Plan

### 12.1 Research rounds

| Round | Prototype | Participants | Focus |
|---|---|---|---|
| 1. Concept | Low-fidelity clickable prototype | 5–7 university students | Navigation labels, view switching, information hierarchy. |
| 2. Interaction | High-fidelity iPhone prototype | 6–8 mixed calendar users | Quick Add, recurrence, drag/resize, delete and undo. |
| 3. Accessibility | Instrumented build | VoiceOver, large text, motor-access users where available | Focus order, alternate actions, layout adaptation. |
| 4. Beta | TestFlight production-like build | 20–50 users over 2–4 weeks | Reliability, performance, real schedule density, ICS compatibility. |

### 12.2 Core usability tasks

1. Find the next event and state where it takes place.
2. Create a 90-minute event tomorrow at 7:00 PM in the School calendar.
3. Create a class that repeats every Monday and Wednesday for 12 occurrences.
4. Move one occurrence of a recurring event without changing the series.
5. Delete an event, then recover it using Undo.
6. Hide a calendar and restore it.
7. Find an event using a partial location or note keyword.
8. Import an ICS file and identify skipped duplicates.
9. Change the device time zone and explain why a timed event moved but an all-day event did not.

### 12.3 Success metrics

| Metric | Initial target |
|---|---|
| Task completion | At least 90% for basic create, find, edit, and delete tasks. |
| Quick Add time | Median under 20 seconds for title/start/end/calendar/reminder. |
| Next-event identification | Median under 5 seconds from launch. |
| Critical error rate | Zero silent event-loss errors in testing. |
| Recurrence comprehension | At least 85% correctly predict scope before confirmation. |
| Undo discovery | At least 80% notice and can use Undo after a prompted mistake. |
| System Usability Scale | Target 80+ after feature stabilization. |
| Accessibility completion | All critical tasks completable with VoiceOver and at largest supported Dynamic Type. |

### 12.4 Analytics boundaries

* Measure screen and action identifiers, durations, success/failure category, and performance timing.
* Never collect event titles, notes, locations, search queries, calendar names, or raw ICS content.
* Use local debug instrumentation before introducing production analytics.
* Document every analytics event and its privacy classification.

---

## 13. Developer Handoff and Release Checklist

### 13.1 Required design deliverables

* Figma library with semantic color, typography, spacing, icon, and component tokens.
* Responsive frames for standard and compact iPhone widths, landscape, and accessibility text sizes.
* Light, dark, and increased-contrast states.
* Component variants for default, selected, pressed, disabled, loading, error, read-only, and conflict states.
* Interaction prototypes for create, recurrence, move, resize, delete, undo, and search.
* Redlines or inspectable constraints, not screenshot-only specifications.
* Content inventory and localized-string keys.
* Accessibility annotations and expected VoiceOver order.

### 13.2 Definition of ready for engineering

| Check | Required evidence |
|---|---|
| Scope approved | Screen and feature identifiers map to Phase 1 requirements. |
| States complete | Happy, empty, error, permission, and destructive states documented. |
| Responsive rules | Behavior specified for narrow width, landscape, and large text. |
| Data behavior | All-day, timed, recurrence, time-zone, and ownership rules linked to product specification. |
| Accessibility | Labels, actions, focus order, gesture alternatives, and contrast verified. |
| Copy reviewed | Titles, actions, errors, confirmation language, and permission rationale approved. |
| Assets ready | SF Symbol names or vector assets documented; no ambiguous raster screenshots. |
| Acceptance criteria | Each primary screen has testable behavior and performance expectations. |

### 13.3 Phase 1 design QA checklist

- [ ] Day, week, month, and agenda render correctly with empty, typical, and extreme event density.
- [ ] All-day and timed events remain visually distinct.
- [ ] Current time and Today states are visible but not confused with selected date.
- [ ] Overlapping events remain selectable and readable.
- [ ] Quick Add and Full Editor preserve user-entered data after errors.
- [ ] Recurring edit/delete scope appears before the change commits.
- [ ] Delete, move, and resize provide Undo.
- [ ] Dark Mode and increased contrast use appropriate semantic variants.
- [ ] Largest Dynamic Type does not clip primary actions.
- [ ] VoiceOver can complete all critical tasks.
- [ ] Notification-denied state does not repeatedly prompt.
- [ ] Search filters and scope remain visible.
- [ ] ICS partial import clearly reports outcomes.
- [ ] No user content appears in analytics or logs.

---

## Appendix A. UI Copy Standards

### A.1 Voice and tone

* Direct: "Event saved" rather than "Your event has successfully been saved."
* Specific: name the event, calendar, date, or consequence where privacy permits.
* Calm: avoid alarming language for recoverable problems.
* Actionable: errors tell the user what to do next.
* Consistent: use Create, Edit, Save, Move, Duplicate, Export, Delete, and Undo with stable meanings.

### A.2 Recommended labels

| Use | Avoid | Reason |
|---|---|---|
| Add Event | New Item | Names the object. |
| This Event | Only This One | Matches recurring-event mental model. |
| All Events | Entire Series Forever | Clearer and less dramatic. |
| Discard Changes | Close Without Saving | Focuses on consequence. |
| Open Settings | Fix Permissions | User controls system permission. |
| No events today | Nothing here | Specific and neutral. |
| Move Events | Keep Events | Names the actual action. |
| Import complete | Success! | Supports partial-result detail. |

### A.3 Permission rationale example

> **Notifications**
> Better Calendar uses notifications only for reminders you add to events. You can continue using the calendar without allowing notifications.

---

## Appendix B. Screen Inventory

| ID | Screen / surface | Release |
|---|---|---|
| ONB-01 | Local-only onboarding | MVP |
| CAL-DAY-01 | Day View | MVP |
| CAL-WEEK-01 | Week View | MVP |
| CAL-MONTH-01 | Month View | MVP |
| AGD-01 | Agenda | MVP |
| EVT-QUICK-01 | Quick Add | MVP |
| EVT-EDIT-01 | Full Event Editor | MVP |
| EVT-DETAIL-01 | Event Detail | MVP |
| REC-01 | Recurrence Editor | MVP |
| REM-01 | Reminder Editor | MVP |
| CAL-MGR-01 | Calendar Manager | MVP |
| SRCH-01 | Search | MVP |
| SET-01 | Settings | MVP |
| IMP-01 | ICS Import Preview | MVP |
| EXP-01 | ICS Export | MVP |
| PERM-01 | Notification Permission Education | MVP |
| ERR-01 | Recoverable Error | MVP |
| UNDO-01 | Undo Banner | MVP |
| ACC-01 | Connected Accounts | Future |
| TASK-01 | Tasks and Time Blocks | Future |
| AI-01 | Schedule Suggestions | Future |
| BOOK-01 | Scheduling Page | Future |

---

## Appendix C. References

1. Apple Human Interface Guidelines
2. Apple Human Interface Guidelines: Accessibility
3. Apple Human Interface Guidelines: Color
4. Apple Human Interface Guidelines: Typography
5. Apple Human Interface Guidelines: Searching
6. Apple Human Interface Guidelines: Dark Mode
7. RFC 5545: Internet Calendaring and Scheduling Core Object Specification

> **Reference note**
> Platform guidance changes over time. The product team should recheck Apple's current Human Interface Guidelines and relevant developer documentation before final visual design approval and App Store submission.

> **Design approval gates**
> Product scope · Information architecture · Core flows · Component library · Accessibility · Usability results · Engineering feasibility · Phase 1 design QA
