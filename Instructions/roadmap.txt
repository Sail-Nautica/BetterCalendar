# Better Calendar: Implementation Roadmap

Better Calendar should be built as an **offline-first, provider-neutral calendar platform**. Google Calendar, Apple Calendar, Gmail, and U-M should be connected accounts feeding a common Better Calendar interface rather than becoming the internal foundation of the application.

The recommended first ecosystem is:

* Native iPhone, iPad, Mac, and Apple Watch applications
* A Better Calendar cloud backend
* Apple Calendar access through EventKit
* Google Calendar through the Google Calendar API
* U-M authentication through Shibboleth/OIDC
* Gmail assistance added only after the calendar platform is stable

## Recommended architecture

```text
iPhone / iPad / Mac / Apple Watch
        │
        ├── Local SQLite calendar database
        ├── EventKit adapter → Apple/iCloud/device calendars
        ├── WatchConnectivity → Apple Watch
        └── Better Calendar API
                    │
                    ├── PostgreSQL
                    ├── Authentication and account linking
                    ├── Calendar synchronization workers
                    ├── Google Calendar adapter
                    ├── Gmail processing adapter
                    ├── U-M identity adapter
                    ├── Notification scheduler
                    └── APNs / Google Pub/Sub
```

### Suggested technology stack

**Apple applications**

* Swift and SwiftUI
* A shared Swift package for models, networking, synchronization, and business logic
* SQLite with GRDB for the production local database
* EventKit and EventKitUI
* WidgetKit
* WatchConnectivity
* App Intents and Shortcuts
* UserNotifications and ActivityKit
* MapKit and Contacts where appropriate

**Backend**

* TypeScript with NestJS
* PostgreSQL
* Redis or a managed job queue
* Google Cloud Run
* Google Pub/Sub
* Google Secret Manager or another managed key-management system
* Apple Push Notification service

GCP is a practical backend choice because Gmail mailbox notifications already use Google Cloud Pub/Sub. Gmail watches must be renewed periodically, and the application must still perform fallback synchronization because notifications can occasionally be delayed or dropped. ([Google for Developers][1])

---

# Features in implementation order

## Phase 0 — Product and data-model foundation

Build this before designing the complete interface.

### Product decisions

1. Define Better Calendar’s primary advantage:

   * Unified personal, school, and work calendar
   * Better time-blocking and schedule planning
   * Email-to-calendar automation
   * Strong Apple-device experience
   * Student-specific workload management

2. Separate three concepts:

   * **Better Calendar account:** identity used to sync preferences and Better-specific data.
   * **Connected calendar account:** Google, Apple, U-M, Outlook, or CalDAV.
   * **Event source:** the provider that owns the authoritative event.

3. Establish an event ownership rule:

   * A Google event remains owned by Google.
   * An Apple/iCloud event remains owned by its EventKit calendar.
   * A Better Calendar event is owned by Better Calendar.
   * Mirrored events must not accidentally be recreated in another provider.

### Core data model

Create these entities before implementing views:

* User
* ConnectedAccount
* Calendar
* Event
* RecurringEventRule
* RecurrenceException
* Attendee
* Reminder
* Attachment
* ConferenceLink
* Location
* Task
* TimeBlock
* AvailabilityRule
* SyncCursor
* PendingMutation
* DeletedEventTombstone
* NotificationPreference

Every synchronized object should contain:

```text
internalID
provider
providerAccountID
providerCalendarID
providerObjectID
providerVersion or ETag
lastModifiedAt
syncStatus
deletedAt
```

Pay special attention to:

* Time zones
* Daylight-saving changes
* All-day events
* Floating times
* Recurrence rules
* Canceled occurrences
* Edited individual occurrences
* Organizer versus attendee permissions
* Tentative, accepted, declined, and needs-action statuses

These are harder to retrofit than interface features.

---

## Phase 1 — Offline iPhone calendar MVP

Start with iPhone only and do not connect external accounts yet.

### Essential features

1. Day, week, month, and agenda views
2. Create, edit, move, duplicate, and delete events
3. All-day events
4. Event colors and calendar colors
5. Locations, URLs, notes, and attachments
6. Multiple reminders
7. Recurring events
8. Search
9. Time-zone support
10. Drag-and-drop rescheduling
11. Undo after moving or deleting an event
12. Light mode, dark mode, and accessibility
13. Local notifications
14. Offline operation
15. Import and export through ICS files

### Interaction goals

* Add an event in no more than two taps from the main screen.
* Allow typing “Physics study session tomorrow at 7.”
* Support precise editing without forcing natural-language input.
* Make week view useful on smaller iPhones.
* Preserve scroll position and selected date across launches.

### Initial milestone

At the end of this phase, Better Calendar should be usable as a completely local calendar even without an account.

---

## Phase 2 — Production-quality event engine

Before connecting Google or Apple, make the local event engine reliable.

### Add

1. Full recurrence-rule editor
2. “This event,” “future events,” and “entire series” editing
3. Conflict detection
4. Free/busy calculations
5. Event version history
6. Local change journal
7. Outbox for offline edits
8. Idempotent save operations
9. Deleted-event tombstones
10. Optimistic concurrency
11. Automatic retry for failed changes
12. Duplicate-event detection
13. Time-zone conversion tests
14. Recurrence test suite
15. Database migrations and recovery

The synchronization engine should never send a provider change directly from a screen. A screen writes to the local database; a synchronization worker processes the pending mutation.

```text
User edit
   ↓
Local database transaction
   ↓
Pending mutation/outbox
   ↓
Provider synchronization
   ↓
Success, retry, or conflict
```

This design keeps the application responsive and makes offline editing possible.

---

## Phase 3 — Apple Calendar and device-calendar integration

Use EventKit to access the calendars already configured on an iPhone, iPad, or Mac. EventKit supports creating, retrieving, and editing calendar events and reminders, while EventKitUI provides Apple-managed event editing and calendar-selection interfaces. ([Apple Developer][2])

### Features

1. Request calendar permission with a clear explanation
2. Display available EventKit calendars
3. Let users choose which calendars appear
4. Read existing events
5. Create and edit EventKit events
6. Delete events where permissions allow
7. Respect read-only calendars
8. Sync EventKit changes into the local database
9. Detect changes made in Apple Calendar
10. Allow choosing a default destination calendar
11. Integrate Apple Reminders optionally
12. Preserve provider-specific metadata
13. Show the owning account and calendar for every event

### Important duplication rule

A Google calendar may already appear in EventKit because the user added Google under Apple’s system account settings. Later, Better Calendar may also connect to that same Google account directly.

Better Calendar must detect this situation and ask the user to choose one connection method:

* **Device connection:** access the Google calendar through EventKit
* **Direct connection:** access it through the Google Calendar API

Do not synchronize both copies independently.

### Apple-specific security

Calendar access requires the appropriate permission descriptions, and sandboxed macOS applications require the calendar entitlement. ([Apple Developer][3])

---

## Phase 4 — Better Calendar account and cloud synchronization

Now introduce the Better Calendar backend.

### Account features

1. Sign in with Apple
2. Email-based account recovery
3. Device-management screen
4. Session revocation
5. Export user data
6. Delete account and data
7. Account-linking support
8. Optional guest/local-only mode

Because the app will support Google or U-M sign-in, include Sign in with Apple as a primary equivalent authentication choice. Apple’s current review guidelines impose additional requirements when third-party login is used to create or authenticate an app’s primary account. ([Apple Developer][4])

### Cloud synchronization

1. Sync Better-owned events across devices
2. Sync preferences and selected calendars
3. Sync custom tags, tasks, and time blocks
4. Push updates to all active devices
5. Support offline writes from multiple devices
6. Resolve simultaneous edits
7. Maintain per-device synchronization cursors
8. Maintain an encrypted token vault
9. Add audit logs for account connections
10. Add server-side rate limiting

### Conflict behavior

Use a visible conflict model rather than silently discarding edits:

* Automatically merge edits to different fields.
* Use the newest edit when a single low-risk field conflicts.
* Ask the user when time, recurrence, deletion, or attendees conflict.
* Preserve both versions until the conflict is resolved.

CloudKit can move app-owned data between a user’s Apple devices, but it should not be the only backend here. Better Calendar needs server endpoints for Google push notifications, Gmail processing, collaboration, scheduling pages, and potential future non-Apple clients. Apple describes CloudKit as complementary synchronization infrastructure with limited offline caching rather than a replacement for the application’s own data model. ([Apple Developer][5])

---

## Phase 5 — Direct Google Calendar integration

This is the first major external-provider integration.

### Connection flow

1. User selects “Connect Google.”
2. Open Google OAuth in a secure system browser session.
3. Request read-only access initially.
4. Import calendars and events.
5. Let the user enable write access separately.
6. Store refresh tokens encrypted.
7. Maintain a separate synchronization cursor per calendar.
8. Establish push-notification channels.
9. Perform periodic reconciliation.

Google recommends requesting the narrowest possible scopes and using incremental authorization—for example, requesting write access only when the user attempts a write action. Public applications using qualifying Calendar scopes may need OAuth verification. ([Google for Developers][6])

### Features

1. Select calendars to synchronize
2. Read and create events
3. Edit and delete events
4. Guest lists
5. Invitation responses
6. Organizer controls
7. Google Meet links
8. Recurrence support
9. Event attachments
10. Free/busy lookup
11. Working locations where available
12. Calendar sharing visibility
13. Resource and room calendars
14. Incremental synchronization
15. Push-triggered synchronization
16. Recovery from expired sync tokens
17. API quota and exponential-backoff handling

The Calendar API supports incremental synchronization and push notification channels; quota-aware retries should be part of the original implementation rather than added after launch. ([Google for Developers][7])

### MVP cutoff

A strong public beta could ship after Phase 5 with:

* iPhone application
* Better account
* Apple Calendar connection
* Google Calendar connection
* Reliable cross-device synchronization
* Day, week, month, and agenda views
* Search and notifications

---

## Phase 6 — Notifications, tasks, and daily planning

Once calendar synchronization is dependable, add Better Calendar’s daily workflow.

### Notification system

1. Event reminders
2. Leave-now reminders
3. Travel-time warnings
4. Event-change notifications
5. Invitation notifications
6. Conflict warnings
7. Daily agenda notification
8. Tomorrow preview
9. Missed-event follow-up
10. Configurable quiet hours
11. Per-calendar notification rules
12. Critical-event escalation, used sparingly
13. Notification actions:

* Join meeting
* Mark task complete
* Snooze
* Open directions
* Message attendees

### Task and planning system

1. Tasks with deadlines
2. Estimated duration
3. Priority
4. Flexible scheduling window
5. Task dependencies
6. Recurring tasks
7. Convert task to time block
8. Mark time block complete
9. Reschedule unfinished work
10. Pin protected focus blocks
11. Workload view
12. Daily plan screen
13. Calendar-plus-task unified agenda

Keep tasks and events distinct:

* An **event** happens at a committed time.
* A **task** needs completion.
* A **time block** reserves time to perform a task.

---

## Phase 7 — iPad and Mac applications

Do not simply enlarge the iPhone interface.

### Shared capabilities

* Same account and synchronization engine
* Same provider integrations
* Shared design system
* Shared event editor and models
* Keyboard shortcuts
* Drag-and-drop
* Multiple windows

### iPad-specific features

1. Three-column layout
2. Persistent mini-calendar
3. Split View and Stage Manager
4. Apple Pencil event creation
5. Drag tasks onto the calendar
6. External keyboard shortcuts
7. Context menus
8. Interactive widgets

### Mac-specific features

1. Menu-bar next-event display
2. Native multiwindow support
3. Global quick-add shortcut
4. Full keyboard navigation
5. Command palette
6. Drag email or text onto the calendar
7. Resizable sidebars
8. Printable calendar views
9. CSV and ICS exports
10. Open meeting links from notifications
11. Dock badge for outstanding schedule actions
12. Spotlight indexing
13. Share extension

A native SwiftUI Mac target is preferable to making the Mac experience an unchanged iPad window. Most business logic can still live in shared Swift packages.

---

## Phase 8 — Apple Watch, widgets, Siri, and system experiences

Build the Apple Watch application only after account and synchronization behavior is stable.

### Apple Watch application

1. Next-event screen
2. Daily agenda
3. Event details
4. Join meeting
5. Directions
6. Accept or decline invitations
7. Mark task complete
8. Add a quick event using dictation
9. Start a focus block
10. Snooze reminders
11. Haptic alert before important events
12. Offline cache of the upcoming agenda

### Watch synchronization

Use both:

* Direct backend synchronization when the Watch has connectivity
* WatchConnectivity for efficient communication with the paired iPhone

WatchConnectivity supports immediate messages, queued background data transfers, application context, files, and complication updates. ([Apple Developer][8])

### Widgets and complications

1. Next event
2. Today’s timeline
3. Remaining free time
4. Current focus block
5. Assignment countdown
6. Quick-add button
7. Watch-face complication
8. Watch Smart Stack widget
9. Lock-screen widget
10. Mac desktop widget
11. Interactive task-completion widget
12. Live Activity for an active event or focus session

WidgetKit currently supports home-screen and lock-screen widgets, Mac widgets, Apple Watch complications and Smart Stack experiences, controls, and Live Activity-related presentation. ([Apple Developer][9])

### Siri and Shortcuts

Examples:

* “Add calculus review tomorrow at seven.”
* “What is my next event?”
* “Start my next study block.”
* “Move unfinished tasks to tomorrow.”
* “How much free time do I have Friday?”
* “Schedule 90 minutes for project work.”

---

## Phase 9 — U-M SSO and university integrations

Treat U-M identity and U-M Google data as separate connections.

### U-M identity connection

Use a backend-mediated login:

```text
Better Calendar app
      ↓
ASWebAuthenticationSession
      ↓
Better Calendar backend
      ↓
U-M Shibboleth OIDC or SAML
      ↓
U-M login and Duo
      ↓
Better Calendar session
```

U-M supports Shibboleth-based SAML service providers and documents OIDC service-provider configurations. Registration and attribute-release approval may be required. Duo should remain part of the U-M authentication flow rather than being implemented by Better Calendar. ([ITS Documentation][10])

### Important distinction

U-M SSO proves that the user is a member of the university. It does not automatically grant Better Calendar access to Gmail, Google Calendar, Canvas, or other university data.

Those require separate provider authorization or U-M API approval.

### U-M features in order

1. “Sign in with U-M”
2. Verify uniqname and university affiliation
3. Connect the user’s U-M Google Calendar
4. Import an official or user-provided class-schedule ICS file
5. Academic-term calendar
6. University holidays and breaks
7. Exam schedule
8. Class-location mapping
9. Campus travel-time calculation
10. MCommunity contact search, subject to API approval
11. Course and assignment integration, subject to available APIs
12. Campus room and resource search
13. Student-organization calendars
14. Dining, athletics, and university-event subscriptions

U-M maintains an API Directory for registering applications and obtaining OAuth access to approved APIs. Prefer a team-owned U-M developer application rather than tying production credentials to one individual account. ([ITS Documentation][11])

### U-M student mode

This could become a major differentiator:

* Class schedule separated from personal calendar
* Assignment workload timeline
* Exam countdowns
* Automatic study-block generation
* Walking time between buildings
* Warning when meetings overlap class
* Office-hours calendar
* Semester workload analytics
* Break and travel planning
* “Skip recurring class” handling for university holidays

---

## Phase 10 — Gmail-assisted scheduling

Implement Gmail late because its authorization and compliance burden is considerably higher than Calendar integration.

### Begin with minimal-access approaches

1. Share an email into Better Calendar
2. Paste email text into event creation
3. Detect dates from user-selected text
4. Gmail add-on or action that sends one selected message
5. Request mailbox-wide access only when the product clearly needs it

### Full Gmail features

1. Detect invitations that are not formal calendar invites
2. Detect deadlines
3. Detect travel reservations
4. Detect flight, hotel, and restaurant confirmations
5. Detect interviews and appointment confirmations
6. Suggest events without creating them automatically
7. Attach the originating message to an event
8. Show unread schedule-related messages
9. Draft scheduling replies
10. Find proposed times in an email thread
11. Compare proposed times against availability
12. Convert messages into tasks
13. Update events when a reservation changes
14. Notify the user when a meeting is canceled by email
15. Provide an “Upcoming schedule actions” inbox

### Required safeguards

* Never create events silently by default.
* Show the source message.
* Explain why an event was suggested.
* Allow per-sender and per-category rules.
* Avoid sending email without explicit confirmation.
* Process only the minimum necessary message content.
* Provide retention and deletion controls.

Mailbox-reading Gmail scopes are categorized as restricted. Apps using restricted scopes may require OAuth verification and, when restricted data is stored or transmitted through a server, a recurring third-party security assessment. ([Google Help][12])

This is the main reason Gmail should not be part of the first MVP.

---

## Phase 11 — Invitations, collaboration, and scheduling links

### Calendar collaboration

1. Invite attendees
2. Accept, decline, or tentatively accept
3. Propose a new time
4. View attendee availability
5. Add optional attendees
6. Add rooms and resources
7. Delegate calendar management
8. Shared family, team, and organization calendars
9. Event comments
10. Event change history
11. Poll attendees for preferred times

### Scheduling pages

1. Public booking link
2. Multiple appointment types
3. Minimum notice
4. Buffers before and after meetings
5. Daily and weekly booking limits
6. Round-robin scheduling
7. Collective availability
8. Approval-required bookings
9. Custom intake questions
10. Time-zone-aware display
11. Automatic conference link
12. Cancellation and rescheduling
13. Waitlists
14. Payment support only if it becomes a business requirement

### External-service connections

Add provider adapters for:

* Zoom
* Microsoft Teams
* Google Meet
* Webex
* Slack
* Microsoft Outlook and Exchange
* Todoist
* Notion
* GitHub
* Learning-management systems
* Travel services

Each integration should be independently disconnectable and have its own permission summary.

---

## Phase 12 — Better Calendar intelligence

Only build intelligent scheduling after the app has accurate event, task, duration, availability, and completion data.

### Natural-language calendar actions

* “Move my study sessions around the exam.”
* “Find two hours this week for my project.”
* “Schedule lunch with Alex when we are both free.”
* “Give me 20 minutes between North Campus and Central Campus.”
* “Protect my mornings for deep work.”
* “Move anything flexible if tomorrow becomes overloaded.”

Always preview multi-event changes before applying them.

### Smart planning features

1. Automatic time blocking
2. Reschedule incomplete tasks
3. Protect high-priority blocks
4. Energy-based planning
5. Preferred working hours
6. Meeting-density limits
7. Travel buffers
8. Preparation and follow-up blocks
9. Deadline risk detection
10. Overcommitment warnings
11. Schedule-quality score
12. Focus-time preservation
13. Suggested meeting declines
14. Semester study planner
15. “What can I realistically complete today?”
16. Weekly planning review
17. Schedule-change explanations

### Personal preference engine

Learn explicit preferences such as:

* No meetings before 9:00 a.m.
* Lunch between noon and 1:30 p.m.
* At least 30 minutes between difficult classes
* Prefer study blocks of 60–90 minutes
* Do not move classes or exams
* Avoid more than three meetings consecutively
* Reserve exercise time
* Add campus travel time automatically

Users must be able to inspect, edit, disable, and delete learned preferences.

---

## Phase 13 — Security, reliability, and public release

Security should be developed throughout the project, but this phase completes launch readiness.

### Security requirements

1. OAuth with PKCE for native clients
2. System-browser authentication
3. Refresh-token encryption
4. Keychain storage on Apple devices
5. Server-side secrets in managed secret storage
6. Encryption in transit and at rest
7. Account-session revocation
8. Least-privilege scopes
9. Audit trail for sensitive operations
10. Rate limiting
11. Abuse detection
12. Dependency scanning
13. Static analysis
14. Penetration testing
15. Data-retention controls
16. Full account deletion
17. Privacy policy and data inventory
18. Incident-response plan
19. Provider-token revocation on disconnect
20. No event details in server logs

### Reliability requirements

1. Automated recurrence tests
2. Time-zone and daylight-saving tests
3. Provider contract tests
4. Offline/online transition tests
5. Duplicate-event tests
6. Large-calendar performance tests
7. Push-notification reconciliation
8. Background-sync monitoring
9. Dead-letter queue
10. Provider outage handling
11. Database backups
12. Point-in-time recovery
13. Status page
14. Analytics that exclude private event content
15. Staged rollout and TestFlight beta

---

# Recommended release sequence

## Release 0.1 — Prototype

* iPhone
* Local events
* Day, week, month, and agenda views
* Recurrence
* Search
* Notifications

## Release 0.2 — Apple beta

* EventKit integration
* Apple/iCloud calendars
* Better account
* Cloud synchronization
* iPad application

## Release 0.3 — Connected beta

* Google Calendar
* Invitations
* Push synchronization
* Mac application
* Widgets

## Release 0.4 — Apple ecosystem

* Apple Watch
* Complications
* Siri and Shortcuts
* Live Activities
* Menu-bar application

## Release 0.5 — Michigan edition

* U-M SSO
* U-M Google connection
* Class schedules
* Academic calendar
* Campus travel and workload tools

## Release 0.6 — Smart scheduling

* Tasks and time blocks
* Automated rescheduling
* Scheduling pages
* Availability sharing
* Planning assistant

## Release 1.0 — Production launch

* Security review
* Google OAuth verification
* Data export and deletion
* Accessibility review
* Performance testing
* TestFlight feedback incorporated
* App Store launch

## Release 1.1 or later — Gmail

* Selected-email processing first
* Schedule-action inbox
* Reservation and deadline detection
* Broader mailbox integration only after compliance readiness

---

# Most important implementation rules

1. **Do not build Gmail first.** Calendar synchronization is already a substantial systems problem, and Gmail adds restricted-scope compliance.

2. **Do not use EventKit and direct Google synchronization for the same account without deduplication.**

3. **Build recurrence and time-zone correctness before AI features.**

4. **Keep Better Calendar identity separate from provider accounts.**

5. **Make every integration optional and independently disconnectable.**

6. **Treat external providers as authoritative for their events.**

7. **Store local edits in an outbox instead of calling providers directly from the interface.**

8. **Build Apple Watch after the iPhone and backend synchronization model is stable.**

9. **Use U-M SSO for identity, but use separate authorization for U-M Google and university APIs.**

10. **Make intelligent schedule changes explainable, previewable, and reversible.**

The best first target is **Phases 0–5**. That produces a credible Better Calendar beta without allowing Gmail, university systems, AI, and collaboration features to destabilize the core calendar engine.

[1]: https://developers.google.com/workspace/gmail/api/guides/push?utm_source=chatgpt.com "Configure push notifications in Gmail API  |  Google for Developers"
[2]: https://developer.apple.com/documentation/eventkitui?utm_source=chatgpt.com "EventKit UI | Apple Developer Documentation"
[3]: https://developer.apple.com/documentation/eventkit/accessing-the-event-store?utm_source=chatgpt.com "Accessing the event store | Apple Developer Documentation"
[4]: https://developer.apple.com/app-store/review/guidelines/?utm_source=chatgpt.com "App Review Guidelines - Apple Developer"
[5]: https://developer.apple.com/documentation/cloudkit?utm_source=chatgpt.com "CloudKit | Apple Developer Documentation"
[6]: https://developers.google.com/workspace/calendar/api/auth?utm_source=chatgpt.com "Choose Google Calendar API scopes  |  Google for Developers"
[7]: https://developers.google.com/workspace/calendar/api/guides/sync?utm_source=chatgpt.com "Synchronize resources efficiently  |  Google Calendar  |  Google for Developers"
[8]: https://developer.apple.com/documentation/WatchConnectivity/WCSession/transferUserInfo%28_%3A%29?utm_source=chatgpt.com "transferUserInfo (_:) | Apple Developer Documentation"
[9]: https://developer.apple.com/documentation/widgetkit?utm_source=chatgpt.com "WidgetKit | Apple Developer Documentation"
[10]: https://documentation.its.umich.edu/node/766?utm_source=chatgpt.com "Set Up a SAML Service Provider for use with Shibboleth at U-M / ITS Documentation"
[11]: https://documentation.its.umich.edu/api-directory?page=1&utm_source=chatgpt.com "API Directory / ITS Documentation"
[12]: https://support.google.com/cloud/answer/13464321?hl=en&utm_source=chatgpt.com "Verification requirements - Google Cloud Platform Console Help"
