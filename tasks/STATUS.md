# Development Status

Updated: 2026-10-19 (Europe/London)

Current position: **M0–M1 complete; Canvas polling sync, calendar UI, deterministic assignment planning, and local assignment completion tracking are implemented and verified with fixtures. M2–M5 remain partial overall.** No live Canvas, Outlook, Apple Calendar, or AI provider access occurred during this development work.

## Latest task — Apple Calendar integration (2026-10-19)

### Scope and delivered behavior

Implemented the user-authorized Apple Calendar integration slice on `feature/calendar-integration`, in `/Users/davidzhu/Desktop/academic-time-manager-calendar`. The original project working files were not modified. No next milestone was started, no branch was merged, and no remote is configured. M2/M4 remain partial overall; this report supersedes the older EventKit “not implemented” notes below.

- Native, lazy EventKit adapter with explicit macOS full-access permission action, denied/restricted/write-only/revoked handling, account selection, and separate approval for dedicated **Academic AI Time Manager** calendar creation. No automatic permission or calendar read on launch.
- Existing calendar busy times participate in live planning and publication conflict checks. Demo Mode does not read Calendar or publish samples. Personal events stay transient; no new source-classification or SQLite coupling with Outlook.
- Exact before/after previews and explicit approval for create/update/cancel/undo. Approval expires after five minutes or the earliest plan deadline; input/progress/mode/sync changes invalidate proposals. Reads and ownership/conflict checks repeat before writes, including between operations.
- Stable task/session keys, UUID markers, exact content checks and persistent calendar/event identifiers prevent repeated publication and protect unrelated events. A personal event in the dedicated calendar is still not eligible for mutation. External edits/moves/deletion/recurrence/alarms and duplicate markers stop updates.
- Atomic mode-0600 ownership journal with durable write intents, confirmation audit, undo history and read-only recovery. No blind retry after uncertain create/save outcomes. Earlier confirmed operations in a partial batch remain visible. Undo requires a fresh preview and approval, one event operation at a time.
- A small UI bridge and packaging usage-description entry; modular Calendar source files minimize Outlook merge conflicts. A tracked privacy resource fixes the pre-existing missing directory declared by Package.swift in this clean worktree.

### Files changed

New: `Sources/AcademicCore/AppleCalendar.swift`, `EventKitCalendarClient.swift`, `CalendarAwarePlanning.swift`; `Sources/AcademicTimeManager/AppleCalendarUI.swift`, `Resources/CalendarPrivacy.txt`; `Tests/AcademicTimeManagerTests/AppleCalendarTests.swift`; `docs/APPLE_CALENDAR.md`.

Modified: `Sources/AcademicTimeManager/App.swift`, `scripts/package-macos.sh`, `README.md`, `docs/ARCHITECTURE.md`, `docs/INTEGRATIONS.md`, `docs/SECURITY.md`, and `tasks/STATUS.md`. No Outlook implementation or database schema file changed.

### Verification

- Debug: `swift test --disable-sandbox` — **79 passed, 0 failures**.
- Release: `swift test -c release --disable-sandbox` — **79 passed, 0 failures**.
- Includes all 52 existing tests plus 27 Calendar tests: explicit permissions, stale/replayed/expired approval, duplicate prevention/restart, ownership, external changes, busy/free/all-day boundaries, conflict races, revocation, unavailable accounts, storage failures, partial writes, crash recovery, cancellation, undo, DST, actual planner constraints and Demo isolation.
- The tests use only injected in-memory clients, synthetic events, and temporary journal files. They never construct the native EventKit adapter, access real Calendar/Keychain/credentials, or request permissions. Native EventKit and SwiftUI compile in both configurations.
- `git diff --check` passes. The initial debug build found the missing Resources directory; adding the tracked privacy resource fixed it. Final builds have no compiler warnings.
- `sh scripts/package-macos.sh` succeeded. Ad-hoc signing, `codesign --verify --deep --strict`, and `plutil -lint` passed; the full-access usage description is present. Bundle: `/Users/davidzhu/Desktop/academic-time-manager-calendar/build-output/AcademicTimeManager.app`. The app has not been launched.
- Implementation commit: `53b454c` (`Implement approval-controlled Apple Calendar integration`). Documentation/status are recorded in a separate local commit. No push or merge was performed.

### Limitations and manual gate

- EventKit confirms local saves, not remote iCloud/Exchange sync completion. Offline cached reads cannot establish server freshness. Conflict checks cannot make external Calendar edits transactionally atomic with writes.
- A missing uncertain create stays blocked; recovery never guesses or blindly recreates it. Missing/externally changed ownership and same-name calendar conflicts need manual inspection. The journal must be retained.
- Existing managed sessions count as busy during regeneration. Omitted sessions are kept until explicitly canceled. Reads are user-initiated and bounded to a year; personal events are not yet imported into the app's persistent Timeline. Published sessions appear in Connections and Apple Calendar.
- One running app instance is supported; multi-process journal locking and retention/encryption policy remain hardening work. Signing is local ad-hoc, not notarized distribution. Live permission/account behavior and visual accessibility require user testing.
- When ready, follow [the test-account checklist](../docs/APPLE_CALENDAR.md#user-led-manual-verification-only-when-ready): confirm no launch prompt, denial/revocation handling, dedicated-calendar setup, busy-time avoidance, preview without writes, approved repeat/update/cancel/undo, external-edit protection and DST. Start Calendar permission testing only at the user's direction.
- Approval gate: user review/manual verification of this integration before any next milestone or merge. No next milestone approval is assumed.

## Previous task — separate Canvas data and Demo Mode (2026-10-19)

### Delivered behavior

- The app defaults to **Canvas data** on every launch, including when viewing previously synced data offline. An empty live cache remains empty; samples are never substituted. Successfully testing a Canvas connection also selects Canvas data.
- An explicit **Demo Mode** control at the top of each page selects the preserved sample records. Timeline (day/week/month), Plan Preview, and Review Inbox use the same data selection. A visible banner identifies the current mode. Sync is disabled in Demo Mode; changing modes is disabled during an active sync.
- Both assignment selection and protected-event selection are scoped before planning. Demo assignments cannot create real study work, and demo lectures/events cannot block real study sessions. Real protected events still block real study work; demo plans use only demo commitments.
- Switching modes clears the proposal without changing stored assignments or completion status. All imported records and sample records remain in SQLite. No migration, deletion, token change, or Canvas write was added.
- Existing source provenance works without a re-sync: `Canvas` identifies imports; known sample IDs and sample provider names identify demonstrations. Titles do not determine origin. Missing, unknown, or mixed provenance is excluded from display/planning but remains stored. Future adapters must define origin classification before participating.
- Availability settings remain shared local user preferences. Mode selection is session-only and resets to Canvas data on restart.

### Files and verification

- New: `Sources/AcademicCore/AcademicDataset.swift` — shared read-only selection and scoped planning entry point.
- New: `Tests/AcademicTimeManagerTests/AcademicDatasetTests.swift` — six tests covering default/empty live selection, demo-vs-live busy time, isolated review/conflict data, legacy/missing/mixed provenance, undated assignments, and database/status preservation across mode switches, repeat import, and reopen.
- Modified: `Sources/AcademicTimeManager/App.swift`, `README.md`, `docs/ARCHITECTURE.md`, and `tasks/STATUS.md`.
- Debug tests: **52 passed, 0 failures**, including all 46 previous tests.
- Release tests: **52 passed, 0 failures**. The initial sandboxed command was blocked during Swift manifest loading; the approved rerun outside the sandbox passed.
- Release app packaging succeeded. Ad-hoc signing, `codesign --verify --deep --strict`, and `plutil -lint` passed. Latest app: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- No real account, credential, or personal application database was accessed. All tests used synthetic records and temporary SQLite storage. The application has not been launched for a visual check.

### Manual check after rebuilding

1. Quit the running copy and open `build-output/AcademicTimeManager.app`. Confirm **Canvas data** is selected and only your cached imports appear in Timeline and Plan Preview; no new sync is required.
2. Generate a proposal and confirm sample assignments are absent. Existing completion choices should remain unchanged.
3. Select **Demo Mode**. Confirm sample events/assignments and the sample review/conflict appear, imported work is hidden, and the prior proposal clears.
4. Return to **Canvas data**, regenerate, then restart. Confirm the app returns to Canvas data and completion statuses remain saved.

## Previous task — local assignment completion tracking (2026-10-19)

### Delivered behavior

- Plan Preview provides **Not Started**, **In Progress**, and **Completed** for every listed assignment. Status saves immediately in SQLite; errors preserve the previous in-memory status and display a retry message. Controls are disabled when local storage is unavailable.
- SQLite migration 3 adds a separate `assignment_progress` table keyed by stable assignment ID. Status and update timestamp survive restarts, repeated imports, and changed source titles/deadlines. Canvas upserts never touch this table. Missing status defaults to Not Started.
- Assignments appear under **Upcoming assignments**, **Overdue**, **No deadline**, or **Completed**. Completed takes precedence over overdue. **Reopen** restores Not Started; reopening a past-deadline assignment leaves it overdue and ineligible for scheduling.
- Only unfinished assignments whose deadlines are strictly in the future enter task breakdown and scheduling. Completed, overdue, and undated assignments produce neither new study blocks nor unallocated-work warnings. Legitimate capacity warnings remain for future work that cannot fit.
- Local status changes and successful syncs invalidate old proposals. An open Plan Preview refreshes deadline grouping every minute; proposals reaching their earliest included deadline are hidden pending regeneration. Generation itself uses the current instant, including exact-deadline and UK DST boundaries.
- The read-only assignment fetch requests current-user submission evidence. Only a submission timestamp plus a recognized submitted/pending-review/graded state enables a suggestion. **Mark completed locally** requires an explicit user click; no imported submission automatically changes local status. Submission bodies and grades are not retained. Invalid optional evidence is ignored safely.
- Existing cached dated assignments support progress immediately. Metadata for previously cached undated assignments and submission suggestions requires the next user-initiated sync. No live sync was initiated during development.

### Root cause and fixes

The previous Plan Preview passed all deadline items into task breakdown, including deadlines already in the past. The scheduler correctly found no time before those deadlines, then emitted warnings for their individual study stages. Filtering eligibility before task breakdown removes those misleading warnings and replaces them with overdue/completed indicators.

A related availability bug constructed a reversed date interval when today's study window had already ended. The builder now skips that window before creating the interval; a regression test covers generation after study hours.

### Files created or changed

- New: `Sources/AcademicCore/AssignmentProgress.swift` — statuses, source evidence, grouping, shared scheduling entry point, proposal expiry.
- New: `Tests/AcademicTimeManagerTests/AssignmentProgressTests.swift` — nine persistence, migration, import-preservation, scheduling, reopening, compatibility, and date-boundary tests.
- Changed: `Sources/AcademicCore/Database.swift`, `Models.swift`, `CanvasImporter.swift`, and `Scheduler.swift` — migration/storage, optional source metadata, read-only evidence import, availability fix.
- Changed: `Sources/AcademicTimeManager/App.swift` — assignment status controls, sections, submission suggestions, error handling, and eligibility-aware proposals.
- Changed: `Tests/AcademicTimeManagerTests/AcademicCoreTests.swift` and `CanvasImporterTests.swift` — migration expectation and mocked submission-evidence regression coverage.
- Changed: `README.md`, `docs/DATA_MODEL.md`, `docs/INTEGRATIONS.md`, and `tasks/STATUS.md` — usage, storage/eligibility rules, API contract, and results.
- Rebuilt artifact: `build-output/AcademicTimeManager.app`.

### Verification and boundaries

- Debug `swift test`: **46 tests passed, 0 failures**.
- Release `swift test -c release`: **46 tests passed, 0 failures**. Ten new tests extend the previous 36-test suite.
- Release app packaging succeeded; the rebuilt bundle is ad-hoc signed, `codesign --verify --deep --strict` passed, and `plutil -lint` passed. Latest runnable application: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- Tests use synthetic SQLite databases (including file-backed close/reopen and version-2 upgrade), mock credentials, and mocked API responses. Tests assert that imported submission evidence never automatically changes local status and requests remain GET with no body.
- Release testing required an approved execution outside the sandbox after Swift manifest loading failed with `sandbox_apply: Operation not permitted`; the rerun passed. Packaging encountered the same restriction and used the same approved approach.
- The application was not launched and no actual Canvas data, token, Keychain item, or application database was accessed during development. UI compilation passed; visual interaction remains a user check.
- Completion is assignment-level only. Effort estimates and proposals are still not persisted, and In Progress does not automatically reduce estimated effort. No new milestone or unrelated integration work was started.

### User verification

1. Quit any running copy and open [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
2. In **Plan preview**, change an upcoming assignment to **In Progress**, then **Completed**. Confirm it moves to Completed and disappears from a newly generated proposal.
3. Quit and reopen the app; confirm the saved status remains. Choose **Reopen**, then generate again: future assignments become eligible; expired ones remain under Overdue.
4. Confirm past-deadline assignments show Overdue without generating scheduling warnings. They can still be marked completed locally.
5. Optionally initiate **Sync** yourself. Confirm your local statuses remain and any available submission evidence offers a suggestion rather than changing status. No token needs to be shared with Codex.

## Milestone status

| Milestone | Status | Current result |
|---|---|---|
| M0 — Architecture and scaffolding | Complete | Weighted stack decision, native Swift app shell, project setup, feasibility review. |
| M1 — Local app and canonical model | Complete | SQLite persistence, provenance, demo timeline, review decisions, availability settings. |
| M2 — Account integrations | Partial | Oxford Canvas read-only sync is implemented and mock-tested. Microsoft Graph UI/registration remains outside this branch. EventKit adapter, controlled authorization/setup and mock-tested writes are implemented; no real account or permission prompt was used. |
| M3 — Academic intelligence | Partial | Provider-independent analysis protocol and validation exist. Editable effort estimates and deterministic assignment stages are available; no inference provider or email extraction is active. |
| M4 — Scheduling and calendar | Partial | Day/week/month calendar UI and deterministic local proposals are implemented. EventKit preview/approval, safe publication, cancellation, undo and ownership audit are wired. End-to-end live acceptance and unified Calendar event import remain unverified. |
| M5 — Hardening and packaging | Partial | Debug/release suites pass; local ad-hoc-signed app bundle builds. No notarization, Developer ID signing, or in-app visual smoke test. |

## Previous session — implemented behavior

- Canvas sync reads the existing token from macOS Keychain only after the user presses **Sync**. The token is passed only in HTTPS `GET` authorization headers. No Canvas write or delete request exists in the importer.
- Sync fetches active enrolled courses, each course's assignments and due dates, plus course calendar events for a rolling window (30 days back through 365 days ahead). Calendar contexts are grouped in batches of at most 10, matching Canvas's documented `context_codes[]` limit. Courses, assignments (including undated records), deadlines, and calendar events are stored locally with stable Canvas source IDs and provenance.
- Canvas pagination is followed only on the configured HTTPS origin. Redirects are blocked by the production transport. HTTP 429/5xx and transient transport failures receive bounded retries. Errors avoid response bodies and token text.
- Imported source records and academic items are upserted in one SQLite transaction. A successful sync timestamp is committed with that data; failed syncs leave the prior timestamp and imported rows unchanged. Existing demo data remains in the database and is labeled **Demonstration data**, while real records are labeled **Imported from Oxford Canvas**.
- Canvas API timestamps are parsed as absolute ISO-8601 instants, and course IANA timezone identifiers are retained for display. UK DST and protected-rest window tests cover spring/fall boundary behavior.
- Timeline is now a day/week/month calendar with date navigation, event type colors/icons, protected/flexible labels, expandable source details, and Canvas source links. The Sync toolbar action shows activity, status, last-success time, and failures.
- Study planning now offers editable per-deadline effort and priority. Each assignment is split deterministically into requirement review, focused work, and final review. Scheduling uses imported fixed events, configured protected rest periods, priorities, deadlines, and session breaks; unallocated work is reported. A new Canvas sync invalidates the previous proposal so it can be regenerated against updated commitments.
- The Microsoft Graph and EventKit work discussed immediately before the stop request was not started; they remain untouched and are not represented as delivered.

## Incremental-sync limitation

The implementation performs an idempotent local merge using stable provider/external IDs. It does **not** use a server-side delta cursor: the current Canvas course, assignment, and calendar-event requests are paginated refreshes. Calendar events use the bounded date window above. This avoids relying on an undocumented cursor, but means sync downloads the relevant data again and may not discover events outside that window. The Canvas docs describe course enrollment filters and calendar event date/context filters; this limitation is an implementation boundary, not a claim that no Canvas endpoint can ever support delta behavior: [Courses API](https://canvas.instructure.com/doc/api/courses.html), [Calendar Events API](https://canvas.instructure.com/doc/api/calendar_events.html), [Assignments API](https://canvas.instructure.com/doc/api/assignments.html).

## Previous session — files changed

- `Sources/AcademicCore/CanvasImporter.swift` — active course/assignment/calendar import, pagination, retry, provenance, timezone, safe errors.
- `Sources/AcademicCore/CanvasSyncService.swift` — new Keychain-backed-on-demand fetch coordinator and sync report.
- `Sources/AcademicCore/Database.swift` — atomic Canvas upserts and persisted last-successful-sync timestamp.
- `Sources/AcademicCore/Models.swift` — optional display title on source records for imported course names.
- `Sources/AcademicCore/Scheduler.swift` — editable effort estimate, deterministic task breakdown, protected-rest availability windows.
- `Sources/AcademicTimeManager/App.swift` — Sync UI/status, Canvas provenance, day/week/month calendar, workload controls, schedule from persisted items.
- `Tests/AcademicTimeManagerTests/CanvasImporterTests.swift` — paginated events, duplicate prevention, timezone, retry, failure safety, database/token boundaries.
- `Tests/AcademicTimeManagerTests/AcademicCoreTests.swift` — effort breakdown, rest-window, and UK DST tests.
- `docs/ARCHITECTURE.md` — current sync behavior and API delta limitation.
- `tasks/BACKLOG.md` — updated Canvas and planning task status.
- `tasks/STATUS.md` — this report.
- `build-output/AcademicTimeManager.app` — rebuilt local application bundle.

## Previous session — verification

- Debug: `swift test` — **36 tests passed, 0 failures** (macOS arm64, Xcode 27.1 / Swift 6.4).
- Release: `swift test -c release` — **36 tests passed, 0 failures**.
- Packaging: `scripts/package-macos.sh` succeeded. The local bundle was ad-hoc signed with identifier `org.example.AcademicTimeManager`; `codesign --verify --deep --strict` and `plutil -lint` passed.
- Latest runnable app: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- Tests use mock transports and a fake in-memory token store. The app was not launched for live account verification; no credential, personal file, Canvas account, Microsoft account, or calendar was accessed.
- The workspace is not a Git repository, so no local commit or remote operation was possible.

## Remaining bugs, risks, and blockers

- Canvas sync is polling/upsert, not server-side delta sync. It refreshes a 30-day-past/365-day-future calendar range, so older/far-future events outside that range are not retrieved. The importer preserves previously imported rows; it does not reconcile remote deletions.
- The user's supplied screenshot shows a successful user-initiated Oxford Canvas sync. No live account verification or sync was performed by the development agent. Permission scopes and token policy remain user/institution choices.
- No visual UI check was performed in a launched app. Confirm the new calendar layouts at normal/full-screen sizes and inspect the Connections scroll behavior manually.
- Microsoft Graph needs an app registration/client ID, redirect URI registration, and tenant consent decision. No OAuth flow, mail retrieval, classification, or review import was implemented.
- EventKit permission handling, calendar discovery, managed-calendar setup, preview/approval, and duplicate-safe writes remain unimplemented. No permission was requested and no calendar was changed.
- AI inference remains fixture-only. Estimates in the new plan UI are user-editable assumptions; automatic effort estimation and email date extraction are not implemented.
- Plan proposals are not persisted or approval/audit-linked. Calendar publication and undo are absent.
- SQLite application data is not encrypted at the application layer; retention and user deletion controls remain future hardening work.
- No Git metadata/remote exists in this workspace; changes are uncommitted and cannot be reported as a commit.

## Next priorities

1. User opens the rebuilt app and verifies completion/reopening and restart persistence using the steps above; optionally initiates a sync to verify preservation and submission suggestions. No token needs to be sent to Codex.
2. Add fixture coverage for calendar batches beyond ten course contexts and explicit SQLite rollback on commit failure; consider a documented reconciliation policy for remotely changed/deleted items.
3. Decide whether the app needs a documented server-side delta mechanism or if periodic paginated refresh is acceptable for Canvas; widen or configure the event date window if required.
4. Obtain the Microsoft public-client registration details and agreed delegated scopes before implementing the OAuth PKCE UI and mock-only Graph mail import. Keep real login disabled until user initiated.
5. Implement and mock-test EventKit authorization, read-only event discovery, a dedicated managed calendar, preview/approval, and stable duplicate-safe updates. Do not request permission or write events until the user initiates.
6. Persist user effort estimates/proposals and connect approvals/audit to the plan. Keep AI inference behind the existing provider interface and require review for uncertain extracted deadlines.
7. Perform a user-led visual smoke test, then address code signing/notarization and local data retention/deletion before distribution.

## Manual verification

1. Open `build-output/AcademicTimeManager.app`.
2. In **Connections**, ensure Oxford Canvas shows the saved/connected state. If it does not, use **Test saved connection**; never paste the token into Codex.
3. Press **Sync** in the toolbar. Observe the progress indicator, imported counts, and last-success timestamp.
4. Return to **Timeline**. Switch Day/Week/Month, navigate dates, and confirm Oxford Canvas records have an imported badge while fixtures say **Demonstration data**. Expand event details to inspect source/timezone.
5. In **Plan preview**, adjust effort and priority for deadlines, generate a proposal, and check that protected events/rest are avoided. After a sync, generate again because the prior proposal is invalidated.
6. Test the Connections page in a normal and full-screen window; confirm vertical scrolling reaches the token field and status.
