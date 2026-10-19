# Development Status

Updated: 2026-10-19 (Europe/London)

Current position: **M0–M1 complete; Canvas sync, local completion tracking, demo/live separation, and Microsoft Outlook integration are implemented and verified with fixtures. M2–M5 remain partial overall; real Microsoft sign-in awaits user registration and consent.** No live Canvas, Outlook, Apple Calendar, or AI provider access occurred during this development work.

## Latest milestone task — Microsoft Outlook integration (2026-10-19)

### Implemented features

- Multiple independent Microsoft accounts: public-client authorization code + S256 PKCE, random state, strict callback validation, common authority for organisational/personal accounts, browser account selection, and Graph profile identity checks. No passwords or client secrets are accepted. Tokens use account-specific macOS login Keychain items and refresh rotation; account metadata and opaque sync cursors use local SQLite.
- Connections supports client-ID configuration, Add account, per-account Test connection, Synchronise now, last successful sync, account-specific errors, and Disconnect. Disconnect removes that account's credential and stops polling while preserving cached data and local completion statuses. The app bundle registers the Microsoft callback URL scheme.
- Read-only Inbox sync initially covers the last 30 days. It handles pagination, per-account delta checkpoints, immutable message IDs, repeat-sync deduplication, partial-message hydration, removed/moved messages, HTTP 410 checkpoint reset, transient failures, 401 refresh, 429/5xx retries, and bounded Retry-After delays. Credentials are sent only to the fixed Microsoft/Graph HTTPS endpoints; Graph requests are GET only. Cross-origin/collection links and redirects are blocked.
- Optional polling (5–1440 minutes, off by default) uses persisted settings while the app is running in Live data mode. Operations are shared across windows to prevent overlapping account refresh/sync actions. A future notification trigger can call the same sync boundary; no webhook service or subscription exists.
- Both accounts share configurable keywords, exact-sender/domain allowlists, attachment privacy settings, and timezone. A provider-independent interface has a working local deterministic implementation for tutorials, meetings, appointments, deadlines, tasks, cancellations, and rescheduling notices. Explicit dates are extracted with evidence and confidence; ambiguous dates require manual review. Off-device providers are blocked, so no email is transmitted to cloud AI.
- Relevant PDF/DOCX attachments are analyzed automatically within size/count/page/expansion/text limits. PDFKit extracts text only. DOCX parsing is in memory with bounded ZIP decompression, CRC validation, disabled XML external entities, and rejection of macro/embedded/external content. Attachment skips are reported. Full email bodies and original attachment files are not persisted; review excerpts, hashes, source references, and decisions are.
- Review Inbox supports multi-selection approval/rejection, date/duration correction, account and email/attachment references, original-email links, confidence, duplicate hints, and conflicting dates/overlaps. Batch decisions commit atomically with audit entries. Approved dated events enter the local Timeline and planning constraints; unapproved proposals never do. Exact title/kind/start/duration duplicates merge source references. Cancellation/reschedule approval records an advisory review without changing protected commitments.
- Live data now includes Canvas and approved Outlook events; Demo Mode remains isolated. Existing Canvas sources and completion choices are preserved. No destructive schema migration was needed: Outlook state uses a namespaced row in the existing `app_settings` table.

### Tests and build results

- Debug: **83 tests passed, 0 failures**. Release: **83 tests passed, 0 failures**. This adds 31 Outlook/analysis/attachment tests to the prior 52-test suite.
- New coverage: PKCE test vector and random state, malformed callbacks, OAuth exchange and per-account refresh rotation, revoked refresh, cached token reuse, initial date filter, pagination, delta refresh/reset, account identity mismatch, duplicate message IDs across accounts, bounded throttling/network errors, unsafe links, partial-message hydration, changed/deleted source preservation, cloud-provider rejection, shared rules, timezone parsing, untrusted HTML, PDF and stored/deflated DOCX extraction, unsafe/macro/external/bomb/corrupt files, attachment privacy opt-out, conflict detection, batch rollback/approval, SQLite reopen, polling, Canvas progress preservation, user-corrected date/duration preservation across unchanged-source metadata updates, and invalid XML encoding rejection.
- A synthetic DOCX test-builder expression initially exceeded Swift's type-checking limit; splitting it into small statements resolved the compiler error. Subsequent debug/release runs passed.
- Sandbox restrictions blocked Swift package manifest loading; approved execution outside the sandbox was used for builds/tests. One approval-service usage-limit failure executed nothing; the user requested a retry and subsequent approval succeeded.
- Final release application packaging succeeded. Ad-hoc signing, `codesign --verify --deep --strict`, and `plutil -lint` passed. Latest runnable app: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app). The app was not launched, and real Microsoft authentication, Keychain access, Canvas/Outlook reads, mailbox changes, or calendar writes were not performed.

### Files created or changed

- New core: `MicrosoftAuth.swift`, `MicrosoftGraph.swift`, `OutlookModels.swift`, `EmailAnalysis.swift`, `AttachmentExtraction.swift`, and `EmailReviewRules.swift` in `Sources/AcademicCore/`.
- New UI: `Sources/AcademicTimeManager/OutlookUI.swift`.
- New system module: `Sources/CZlib/shim.h` and `module.modulemap`; uses macOS's existing zlib, with no downloaded dependencies.
- New tests: `Tests/AcademicTimeManagerTests/OutlookIntegrationTests.swift` and `EmailAnalysisAttachmentTests.swift`.
- Updated: `Package.swift`, `Sources/AcademicCore/Database.swift`, `AcademicDataset.swift`, `Sources/AcademicTimeManager/App.swift`, and `scripts/package-macos.sh`.
- Documentation: new `docs/MICROSOFT_SETUP.md`; updated README, architecture, security, integrations, data model, roadmap, backlog, and this report.

### Remaining limitations and user steps

1. Register an Entra **Mobile and desktop** public client supporting **any organisational directory and personal Microsoft accounts**, with redirect `msauth.org.example.AcademicTimeManager://auth`. Configure delegated **User.Read**, **Mail.Read**, and **offline_access** consent; no client secret is needed. Oxford may require administrator approval. Do not bypass university policies.
2. Review [Microsoft setup](../docs/MICROSOFT_SETUP.md), then open the rebuilt app, enter the client ID, save settings, and add each account interactively. Verify identities before using each account's Synchronise now. No credentials should be sent to Codex.
3. Inspect extracted proposals and manual date/duration edits before batch approval. Verify restart persistence and duplicate handling, then optionally enable polling. The browser callback, actual tenant consent, Keychain prompts, and UI have not been live-tested.
4. Current sync is Inbox-only. Initial filtered batches reaching 5,000 distinct changes, 200 pages, or 30 MB stop without committing a checkpoint. High-volume Inboxes need a future broader paging/window strategy. Polling needs an open app; no push notifications or sleep wakeups are implemented.
5. The local extractor is conservative, not a general language model. Relative dates, complex prose, date ranges, recurrence, and quoted-thread semantics can require manual correction. Legacy DOC, DOCM, image-only/encrypted PDF, embedded/reference attachments, and DOCX external relationships are unsupported. PDFKit has a checked between-page time budget, not hard preemption of an individual parser call.
6. Cancellation/rescheduling notices do not yet have an explicit target-event edit workflow; they remain reviewable advisories. No Apple Calendar publication is implemented. Exact duplicate matching is deterministic and does not establish semantic equivalence.
7. SQLite metadata/review excerpts are not encrypted by the app. Full retention/deletion controls, indexed mail-history tables, distribution signing/notarization, and live UI/security smoke testing remain hardening work. A final check found a local Git repository on `main` with no remote. Changes remain uncommitted; no remote operation was performed.

Development stops here before real Microsoft authentication, pending the user's review and interactive setup.

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
| M2 — Account integrations | Partial | Oxford Canvas read-only sync is implemented and mock-tested. Microsoft Graph multi-account PKCE/Inbox delta/local analysis/batch review is implemented with mocks; real login awaits user setup. EventKit is not implemented; no real account or permission prompt was used. |
| M3 — Academic intelligence | Partial | Provider-independent interfaces and validation exist. Local email/attachment extraction, editable estimates, and deterministic stages are implemented; no cloud/general-language inference provider is active. |
| M4 — Scheduling and calendar | Partial | Day/week/month calendar UI and deterministic local proposals are implemented. No EventKit publication, approval workflow, undo, or audit-linked scheduling is wired. |
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
- Microsoft Graph needs user-supplied app registration/client ID, registered redirect URI, tenant consent where required, and interactive login verification. OAuth, read-only mail sync, local classification/attachment extraction, and batch review are implemented and mock-tested.
- EventKit permission handling, calendar discovery, managed-calendar setup, preview/approval, and duplicate-safe writes remain unimplemented. No permission was requested and no calendar was changed.
- General-language AI inference remains unavailable. Email date extraction is deterministic and conservative; automatic effort estimation remains unimplemented.
- Plan proposals are not persisted or approval/audit-linked. Calendar publication and undo are absent.
- SQLite application data is not encrypted at the application layer; retention and user deletion controls remain future hardening work.
- A local Git repository is now available on `main`, with no configured remote. Current changes are uncommitted; no push or merge was performed.

## Next priorities

1. User opens the rebuilt app and verifies completion/reopening and restart persistence using the steps above; optionally initiates a sync to verify preservation and submission suggestions. No token needs to be sent to Codex.
2. Add fixture coverage for calendar batches beyond ten course contexts and explicit SQLite rollback on commit failure; consider a documented reconciliation policy for remotely changed/deleted items.
3. Decide whether the app needs a documented server-side delta mechanism or if periodic paginated refresh is acceptable for Canvas; widen or configure the event date window if required.
4. User registers the Microsoft public client, confirms delegated scopes/consent, and interactively verifies both accounts with the new setup guide. Do not initiate real login on the user's behalf.
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
