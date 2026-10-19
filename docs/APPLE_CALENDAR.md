# Apple Calendar integration

The Calendar implementation from `feature/calendar-integration` is integrated into `main` alongside Outlook, Canvas, and local assignment tracking. The application uses native EventKit on macOS 14 or later. Development and automated tests never instantiate `EKEventStore`, request Calendar permission, read personal calendars, or use credentials. The adapter compiles against the installed macOS SDK; live behavior remains a user-led verification step.

## User flow

1. Open **Connections → Apple Calendar** when ready. **Request Calendar access…** is the only permission-request path. Full access is needed to read busy times; write-only access is insufficient. Denied/restricted/revoked access provides System Settings guidance.
2. Choose the Calendar account, then explicitly approve creation of **Academic AI Time Manager**. Creating the calendar does not publish sessions. Existing calendars with that title are not adopted by name. Repeated setup uses only the persisted calendar identifier.
3. In live **Timeline**, busy Calendar occurrences appear after refresh as orange protected **Apple Calendar** rows with their original title. Titles are held only in transient local memory for rendering; notes, locations, attendees, URLs and calendar-account names are neither displayed nor persisted. App-owned sessions appear green with their study title. Exact same-title/time Canvas or Outlook mirrors collapse to one imported row. All-day and expanded recurring occurrences are included in Day, Week and Month views; free/canceled events do not block time or appear. EventKit change notifications refresh the visible range while the app is running.
4. In live **Plan preview**, generate a proposal. Once connected in this app session, generation reads the same busy intervals from all accessible calendars and adds them to the scheduler's hard constraints. Imported fixed events, deadlines, availability, and protected rest retain their existing behavior. Demo Mode never reads Calendar or publishes sample sessions.
5. Select **Preview Apple Calendar changes**, inspect before/after titles, dates, and zones, then **Approve exact changes**. Merely generating, previewing, or dismissing a plan makes no event writes. Previews expire after five minutes or the plan's earliest deadline, whichever comes first. Changed plans, progress, data mode, availability, or sync results invalidate the preview.
6. In Connections, inspect published sessions and choose **Preview cancellation** or **Preview undo of last event change**. Both require approval. Undo works one confirmed event operation at a time, in reverse order, survives restart, and rechecks ownership/conflicts. Restoring a past session is rejected.
7. After relaunch, the app checks EventKit's persisted authorization status without prompting. If full access is still granted, it automatically reads the active Timeline range and refreshes again as you switch Day, Week, or Month or navigate dates. If access has been revoked or is unavailable, the Timeline stays empty and Connections shows guidance. System Settings controls OS-level revocation.

## Modules and contracts

- `Sources/AcademicCore/AppleCalendar.swift`: injected main-actor `AppleCalendarClient`, value snapshots, exact-preview approval, ownership journal, audit, recovery and undo.
- `Sources/AcademicCore/EventKitCalendarClient.swift`: lazy native adapter. Permission requests, source/calendar operations, event predicates and writes are isolated here. No OAuth or Keychain access.
- `Sources/AcademicCore/CalendarAwarePlanning.swift`: adds transient busy intervals to existing scheduling constraints, without persisting or reclassifying personal events.
- `Sources/AcademicCore/UnifiedTimeline.swift`: combines persisted academic items with local, in-memory Calendar occurrences for Timeline display and exact duplicate suppression.
- `Sources/AcademicTimeManager/AppleCalendarUI.swift`: connection/setup, preview, approval, status, cancellation, recovery and undo controls.
- `Tests/AcademicTimeManagerTests/AppleCalendarTests.swift`: entirely synthetic client/store fixtures; no production adapter construction.

`App.swift` has small wiring changes. No Outlook code, SQLite migration, shared source classification, dependency, or package-target change is required. The existing package declared a missing Resources directory; `CalendarPrivacy.txt` supplies a tracked resource so clean worktree builds succeed. `scripts/package-macos.sh` includes the full-access usage description. Local builds remain unsandboxed and are now certificate-signed with an Apple Development identity so TCC sees a stable designated requirement across rebuilds. A future App Sandbox distribution must add Apple's calendar entitlement and undergo its own signing/permission verification. See [DEVELOPMENT_SIGNING.md](DEVELOPMENT_SIGNING.md).

## Ownership and duplicate prevention

Only the calendar ID created through the app is eligible for writes. Every managed event also needs a random UUID marker in both its URL and exact notes, a persisted internal key and EventKit identifier, and a matching last-confirmed snapshot. Internal keys use a length-delimited task ID plus session ordinal, independent of the scheduler's timestamp-based block IDs. Regenerating a task at a new time updates that slot after approval. A shorter plan does not implicitly cancel omitted sessions; cancellation is explicit in Connections.

Updates/deletes re-fetch the event and verify calendar ID, marker, title, absolute dates, timezone, busy state and eligibility. Changes to notes, URL, location, all-day status, recurrence, attendees or alarms make it ineligible for mutation. A personal event placed inside the dedicated calendar is still protected because no ownership record authorizes it. A copied marker, external move/edit/deletion, missing calendar or read-only calendar fails closed.

Changed provider identifiers can be recovered by marker within the recorded date range (plus one day each side). Missing known events are never recreated automatically. Marker recovery is deliberately bounded; it does not search arbitrary history or infer ownership from a title. Cross-account moves with changed IDs outside that range require manual inspection.

Busy state is re-read at preview, approval, and before each operation in a batch. Newly introduced conflicts abort remaining writes. These are local checks: EventKit supplies no remote transaction or compare-and-swap primitive, so a concurrent external change between the final check and save cannot be eliminated completely.

## Durability, errors and undo

The app atomically writes `~/Library/Application Support/AcademicTimeManager/apple-calendar-ownership.json` with mode 0600. It contains the dedicated calendar identifier, owned event snapshots, pending write intent, ID/action/time audit entries and undo history. Personal-event snapshots are transient and never written to this file or sent to AI. This file is separate from the planner SQLite database to minimize integration coupling. Back up this file with app data; deleting it loses ownership, and the app will not adopt existing managed calendars automatically.

Before each EventKit mutation, the exact intent and approval audit entry are persisted. After success, the returned snapshot, mapping, undo entry and confirmation audit are saved. Storage failure before intent prevents a write. A failed/uncertain EventKit mutation or a storage failure after a successful mutation leaves a pending intent and disables further writes. Partial batches retain already confirmed changes; they are not presented as all-or-nothing.

**Recover pending write (read only)** compares the observed event against the intended before/after states. It can confirm an applied change, confirm an unchanged previous state, or confirm an absent canceled event. It never retries a mutation. An absent attempted create remains unresolved because delayed sync could still reveal the event. Do not clear the journal to retry; inspect Calendar and retain the journal for diagnosis. No automatic background retry is implemented.

Undo itself uses a new explicit approval and the same checks/journal. It cannot overwrite external edits, create a new conflict, or restore a session in the past. Creating the empty dedicated calendar is not included in event undo; the app never deletes calendars.

## Known boundaries

- Save success means saved to the local EventKit store. iCloud/Exchange propagation, account outages and remote delivery are owned by macOS; the API does not provide a remote sync-completion receipt here. An empty cached event query cannot prove that every server commitment has arrived.
- Reads occur at startup and when the visible Timeline range changes, only after EventKit has already granted full access. EventKit change notifications refresh the visible range while the app runs. No background permission request, polling, or sync-triggered replanning is added.
- Planning reads at most 365 days. Proposed sessions must start within 366 days, last at most 24 hours, and be in the future. Calendar queries remain bounded well below EventKit's multi-year predicate limits.
- Existing published study sessions count as busy when generating a new plan. Regeneration can therefore propose moving a task's existing slots; the preview exposes these moves. Omitted slots remain published until canceled. No automatic completion-based cancellation is implemented.
- Personal Calendar events are read-only, transient Timeline entries as well as busy constraints. Their original titles are held only in memory for local Timeline rendering. They are not imported into SQLite, source records, review, AI analysis, or Calendar ownership storage. Full Calendar privacy controls are applied by the Calendar account.
- Undo/audit are local, unencrypted application data protected by file permissions and macOS. Retention/deletion policy and concurrent multiple-app-process journal coordination remain hardening work; use one running application instance.
- Denial/revocation, account availability, same-name calendars, external edits and uncertain creates deliberately stop publication. There is no force-adopt, bulk-delete or force-retry control.
- The app has not been launched during development. No actual permission prompts, personal events, account credentials or live provider data were accessed.

## User-led manual verification (only when ready)

Use a dedicated test Calendar account and synthetic future assignments for writes. Close other copies of the app before launching `build-output/AcademicTimeManager.app` from the main project.

1. Launch without pressing Connect. Confirm there is no Calendar permission prompt and Demo Mode remains usable without access.
2. Press **Request Calendar access…**, deny, and check the error. Then grant full access yourself through System Settings and refresh. Repeat with revocation after preview; approval must fail.
3. Select the test account and approve creation of the dedicated calendar. Repeat setup/restart/refresh; verify there is only one managed calendar. A manually created same-name calendar must not be adopted.
4. Add synthetic timed, recurring and all-day commitments in the test account. Generate a live proposal; verify those periods and protected rest are avoided. Preview/dismiss and verify no event was written.
5. Approve a small proposal, inspect the exact destination and timestamps, then preview the same proposal again without regenerating. It must report no changes. Restart, refresh and verify the published list survives.
6. Regenerate with changed estimates/time availability. Inspect and approve the proposed updates; verify no duplicate owned slot appears. Confirm omitted sessions remain until explicitly canceled.
7. Preview cancellation and approve one session; verify unrelated events remain. Preview/approve undo of the cancellation, update and creation. Check UK DST display in Calendar and the preview's displayed timezone note.
8. Edit/move a managed event manually or add an alarm/recurrence. An attempted app update/cancel must stop without overwriting that edit. Add a conflicting event after preview; approval must stop.
9. Review the UI at normal/full-screen sizes and with keyboard navigation. Inspect an unavailable/read-only account error. Remote sync/offline propagation must be checked in Apple's Calendar UI; never assume local save confirms cloud delivery.

## Apple references

- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store): permission boundaries and sandbox entitlement.
- [TN3152: Migrating to the latest Calendar access levels](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels): macOS 14 full-access API and usage descriptions.
- [Retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders): EventKit predicates and identifier lookup.
