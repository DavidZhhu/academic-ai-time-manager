# Development Status

Updated: 2026-10-19 (Europe/London)

Current position: **M0–M1 complete; Canvas sync, local completion tracking, demo/live separation, Microsoft Outlook integration, and unified Apple Calendar Timeline display are integrated on main and verified with fixtures. M2–M5 remain partial overall; real Microsoft sign-in awaits user registration and consent.** No live Canvas, Outlook, Apple Calendar, or AI provider access occurred during this development work.

## Latest task — stable development signing for Calendar permission persistence (2026-10-19)

### Root cause and investigation

- The bundle identifier was and remains `org.example.AcademicTimeManager`; the Microsoft OAuth callback remains `msauth.org.example.AcademicTimeManager`. Neither value caused the repeated Calendar prompt.
- The old packaging script always used `codesign --sign -`, producing an ad-hoc signature. Inspection of the prior bundle showed `flags=adhoc`, no TeamIdentifier, and a designated requirement containing only that build's `cdhash`. Recompiling changes the executable hash, so macOS TCC can no longer match the rebuilt code to the identity that received Full Calendar Access.
- The bundle had no signing entitlements. Canvas and Microsoft credentials use generic-password items in the login Keychain, with stable service/account names in their existing implementations.
- A read-only `security find-identity -v -p codesigning` check found exactly one valid Apple Development identity. Only public certificate name/hash/chain metadata was inspected; no private key was read, exported, or printed. Public-chain validation succeeded through the Apple Worldwide Developer Relations G3 intermediate to the Apple root. The certificate is valid until October 2027.

### Changes

- `scripts/package-macos.sh` now preserves the existing bundle ID and uses the sole Apple Development identity by default. If none or multiple identities are present, packaging fails with instructions instead of silently falling back to ad-hoc signing. `ACADEMIC_CODE_SIGN_IDENTITY` supports an explicit local selection; `ACADEMIC_ADHOC_SIGNING=1` is an explicit disposable-build escape hatch.
- Added `scripts/verify-macos-signature.sh`. It validates the Info.plist and CodeDirectory identifiers, strict/deep signature integrity, Apple trust anchor, TeamIdentifier, non-ad-hoc flags, and rejects a designated requirement tied only to a `cdhash`.
- Added `docs/DEVELOPMENT_SIGNING.md` and updated README, architecture, security, integration, and Calendar documentation. The guide covers Xcode certificate setup/renewal, identity selection, verification, TCC/Keychain transition behavior, and the separate Developer ID/notarization distribution boundary.
- No source integration, database, Keychain record, EventKit behavior, OAuth scope, or entitlement changed. No privacy permission was reset, no Keychain item was deleted, and no app/account was opened.

### Tests and build status

- Debug suite: **118 tests passed, 0 failures**.
- Release suite: **118 tests passed, 0 failures**.
- Release packaging succeeded with a certificate-backed Apple Development signature. The verifier reported identifier `org.example.AcademicTimeManager`, a nonempty TeamIdentifier, an Apple-anchored designated requirement, and no `adhoc` flag. The bundle contains no new entitlements.
- Latest runnable app: [build-output/AcademicTimeManager.app](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- The app was not launched. Tests use mocks and temporary storage; no EventKit store, personal Calendar data, Canvas/Outlook account, credential, or production database was accessed.

### Remaining manual verification and limits

1. Because the previous installed bundle was ad-hoc signed, macOS may request Calendar authorization once when this Apple Development-signed identity first runs. The work did not reset TCC. Grant access interactively only if macOS presents the normal prompt for the expected app.
2. The signing-identity transition may also produce a one-time login Keychain access prompt for existing Canvas or Microsoft items. The app preserved the item service/account names and does not migrate or delete them.
3. Quit all old copies, open the rebuilt bundle, verify Calendar events load, quit, rebuild again with the same certificate, and reopen. Full Calendar Access should persist across the second certificate-signed rebuild without a new prompt.
4. Certificate renewal/replacement can change the designated requirement and cause another one-time prompt. Use Xcode **Settings → Accounts → Manage Certificates**, select the intended identity explicitly if several exist, and rerun the verifier. No certificate creation is currently required because a valid identity is installed.
5. This is local development signing. Independent distribution remains blocked on a Developer ID Application certificate, Apple Developer program configuration, and notarization; none was requested or changed. Gatekeeper acceptance for third-party distribution is not claimed.

## Previous task — automatic Apple Calendar Timeline loading (2026-10-19)

### Root cause

- Timeline launch and navigation already calculated the active Day, Week, or Month range, but called a refresh method that returned before constructing the Calendar service. The service was only created by the manual **Refresh connection** control, so a persisted full-access authorization was never checked after relaunch.

### Delivered behavior

- The app now constructs the Calendar service at Timeline startup and checks only the persisted EventKit authorization state. Existing Full Calendar Access automatically initializes the local connection and loads busy events for the visible range without calling the permission-request API.
- Switching Day, Week, and Month and navigating dates reloads exactly the newly visible interval. EventKit change notifications continue to refresh the active range while the app runs.
- Undetermined access leaves the existing noninteractive status unchanged. Denied, restricted, write-only, revoked, journal, and EventKit errors clear stale Timeline values and show local guidance without prompting for access.
- Original titles remain transient local Timeline data. Personal events remain protected and read-only, and no notes, attendees, locations, URLs, account details, SQLite records, logs, AI inputs, or Calendar modifications are introduced.
- Manual **Refresh connection** remains available and still invalidates a pending Calendar publication preview. Changing the Timeline range does not invalidate that preview.

### Tests and build status

- Debug suite: **118 tests passed, 0 failures**.
- Added mock regression coverage for startup loading with persisted full access and zero permission requests, revoked authorization with zero reads/prompts, and distinct active-range reloads. Tests use synthetic events and a memory journal only.
- Release suite: **118 tests passed, 0 failures**.
- Release packaging completed through scripts/package-macos.sh; the arm64 bundle was rebuilt, ad-hoc signed, and plist-validated. Latest runnable app: [build-output/AcademicTimeManager.app](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).

### User verification after rebuilding

1. Quit all copies of the app, then open the rebuilt application while **Academic Time Manager** still has Full Calendar Access in System Settings.
2. Open **Timeline**. Busy events in the initial Week range should appear without selecting **Refresh connection** and without a permission prompt.
3. Switch Day, Week, and Month; then use Previous, Next, and Today. The corresponding Calendar events should load for each range.
4. To verify revocation handling, remove Calendar access in System Settings, return to the app, and navigate the Timeline. The events should clear and Connections should show the access guidance; the app should not prompt automatically.

## Previous task — show Apple Calendar event titles in Timeline (2026-10-19)

### Delivered behavior

- Busy personal Apple Calendar occurrences now retain and display their original event title in the local Day, Week, and Month Timeline. The source label (**Apple Calendar**), orange color, dates, times, all-day display, recurring-occurrence expansion, exact duplicate suppression, protected state, and read-only treatment are unchanged.
- The title exists only in the transient in-memory Timeline projection needed to render it. It is never written to SQLite, source records, Review Inbox data, the Calendar ownership journal, persistent logs, or an AI-analysis input. Notes, attendees, locations, URLs, calendar names, and account identifiers remain excluded from the projection.
- Empty or whitespace-only provider titles display as **Untitled Calendar event**. App-owned Calendar sessions keep their separate managed source and remain the only Calendar events eligible for previewed, approved writes.
- Refreshing the Timeline remains a user-initiated, full-access Calendar read. It does not alter, delete, reschedule, or otherwise modify any existing Apple Calendar event. Busy intervals remain protected scheduling constraints; free/cancelled events remain excluded.

### Tests and build status

- Debug suite: **115 tests passed, 0 failures**.
- Release suite: **115 tests passed, 0 failures**.
- Added mock coverage for original personal titles, whitespace-title fallback, no personal-event journal writes, all-day entries, recurring occurrences, protected state, exact Canvas duplicate collapse, and read-only behavior. Tests use only synthetic Calendar values and a memory journal.
- Release packaging completed through scripts/package-macos.sh; the arm64 bundle was rebuilt, ad-hoc signed, and plist-validated. Latest runnable app: [build-output/AcademicTimeManager.app](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- No EventKit store, permission prompt, personal Calendar event, Canvas/Outlook account, credential, production database, or network access occurred during this work. The application was not launched.

### User verification after rebuilding

1. Open the rebuilt app and, only when ready, select **Connections → Apple Calendar → Refresh connection** after granting access yourself.
2. In live **Timeline**, inspect Day, Week, and Month views. Busy personal events should show their Calendar title with the orange **Apple Calendar** source label and protected indicator.
3. Confirm an all-day or recurring test event appears in each applicable range, a free event does not appear, and a Canvas/Outlook event with the same title and time appears only once.
4. Personal events remain read-only; only sessions in **Academic AI Time Manager calendar** offer the existing preview-and-approval change path.

## Previous task — unified Apple Calendar Timeline (2026-10-19)

### Delivered behavior

- Live Timeline now combines Oxford Canvas records, approved Outlook events, and busy Apple Calendar occurrences in Day, Week, and Month views. Calendar entries are orange and labelled **Apple Calendar**; app-owned study sessions are green and labelled **Academic AI Time Manager calendar**. Canvas remains blue, Outlook purple, and demonstrations muted.
- External Calendar occurrences are presented as protected **Apple Calendar** entries with a title held only in transient memory. The app excludes notes, locations, attendees, URLs, calendar/account names and other personal metadata. It never writes these events to SQLite, source records, review data, analysis inputs, or the ownership journal.
- Only events already proven journal-owned by their UUID marker and exact saved record display their study title and remain eligible for the existing preview/approval/cancel/undo path. Other events, including personal events placed in the dedicated calendar, remain read-only.
- The Timeline uses overlap-based date selection, so all-day and multi-day entries appear in every affected Day, Week, and Month. EventKit supplies recurring occurrences within the selected range; each occurrence has an in-memory start/end-specific identity. Free/canceled items are omitted, preserving the existing busy-time conflict policy.
- An exact same-title/time Canvas or Outlook mirror collapses to the imported academic item. Duplicate detection uses a process-local normalized title hash and never persists raw personal content. Calendar change notifications reload the active visible range after a persisted full-access authorization initializes at launch.
- Existing scheduling constraints, Canvas synchronization, assignment completion state, demonstration isolation, Calendar approval and recovery rules are unchanged. No Apple Calendar event is modified, deleted, rescheduled, or imported into persistent storage by Timeline refresh.

### Tests and build status

- Debug suite: **113 tests passed, 0 failures**. It includes two new mocked Calendar Timeline tests for privacy redaction, Canvas deduplication, protected state, all-day entries, recurring occurrences, owned-session distinction, notification observation, and no journal persistence for personal events.
- Release suite: **114 tests passed, 0 failures**. Packaging succeeded through `scripts/package-macos.sh`; ad-hoc signing, strict deep signature verification and plist validation passed for the arm64 bundle. Latest runnable app: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- Tests construct only injected mock Calendar clients and temporary stores; no EventKit store, permission prompt, Canvas, Outlook, credential, or production database was accessed. The app was not launched during this development run.

### User verification after rebuilding

1. Open the rebuilt app after granting full access yourself. The Timeline begins its read automatically without a prompt.
2. Check Day, Week, and Month views: existing busy events should appear as orange, protected **Apple Calendar** entries with their original titles. App-owned study sessions should be green.
3. Change or add a test Calendar event and return to the current Timeline range; EventKit change notifications should refresh the displayed commitments. Confirm free events do not appear or block time.
4. Use only a test calendar and synthetic future work for the existing preview/approval flow. Timeline refresh does not authorize any personal-event change.

## Latest task — integrate Apple Calendar into main (2026-10-19)

### Integration result

- Verified a clean working tree on `main` at `381296a` before starting. `backup/before-calendar-merge` also pointed to `381296a` and was preserved. Merged `feature/calendar-integration` at `e86a624` with a two-parent merge, retaining its implementation commit `53b454c` and the complete Outlook parent history. The merge is explicitly user-authorized; no push was performed.
- Resolved three conflicted files: `App.swift`, `docs/ARCHITECTURE.md`, and this status report. Connections now contains Canvas, Outlook and Apple Calendar controls; neither side's working feature was replaced by its old placeholder. Both architecture sections and historical implementation reports were retained.
- Calendar-aware planning, permission/setup controls, exact preview/approval, ownership checks, idempotent publication, cancellation, undo, audit and uncertain-write recovery are integrated with the existing app. Calendar permission and every publication remain separate user actions.
- Canvas import/authentication, local completion/reopening, overdue exclusion, demo isolation, Outlook multiple-account authentication, Inbox sync, attachment analysis, polling and batch review remain intact. No database migration, deletion of imported data, or credential-store change was introduced.
- Added a conservative integration fix: Outlook import/review invalidates the study proposal and Calendar approval before attempting the SQLite reload. A reload failure therefore cannot retain a previously prepared Calendar approval. Successful Canvas sync and changes to completion, estimates, priorities, availability or data mode also invalidate previews.
- The packaged bundle retains both the Microsoft OAuth callback scheme and Calendar full-access usage description, under the existing `org.example.AcademicTimeManager` signing identity.

### Verification

- Initial combined debug suite: **110 passed, 0 failures**.
- Final complete debug suite: **111 passed, 0 failures**. Final complete release suite: **111 passed, 0 failures**. No compiler warnings or compilation errors were reported.
- Added one integration regression covering a temporary SQLite database with Canvas active/completed/overdue assignments, a demo commitment spanning the planning window, pending then approved Outlook tutorial, mock Calendar busy time, explicit study publication, repeat Canvas import, database reopen, preserved completion/review records, and no implicit cancellation when work is completed. Existing 83 main tests and 27 Calendar branch tests remain in the suite.
- Release packaging succeeded via `scripts/package-macos.sh`. Ad-hoc signing, strict deep signature verification, plist validation, callback scheme and Calendar usage-description checks passed. Executable is macOS arm64.
- Latest runnable bundle: [`build-output/AcademicTimeManager.app`](/Users/davidzhu/Desktop/academic-time-manager/build-output/AcademicTimeManager.app).
- Logs for this run: `/private/tmp/academic-integration-debug.log`, `/private/tmp/academic-integration-release.log`, `/private/tmp/academic-integration-package.log` (temporary, not committed).
- `git diff --check` passed. Git metadata writes and Swift builds/tests required approved execution outside the sandbox. These commands performed local merge/build operations only.
- The app was not launched. Tests use mocks and synthetic temporary storage; no real Outlook account, Canvas credential/data, Apple Calendar store, permission prompt, Microsoft login, or production app database was accessed.

### Changed files

- Added from Calendar branch: `Sources/AcademicCore/AppleCalendar.swift`, `CalendarAwarePlanning.swift`, `EventKitCalendarClient.swift`; `Sources/AcademicTimeManager/AppleCalendarUI.swift`, `Resources/CalendarPrivacy.txt`; `Tests/AcademicTimeManagerTests/AppleCalendarTests.swift`; `docs/APPLE_CALENDAR.md`.
- Integrated/updated: `Sources/AcademicTimeManager/App.swift`, `scripts/package-macos.sh`, `README.md`, `docs/ARCHITECTURE.md`, `docs/INTEGRATIONS.md`, `docs/SECURITY.md`, `tasks/ROADMAP.md`, and `tasks/STATUS.md`. The Calendar test file also contains the new combined regression.
- Generated locally: `build-output/AcademicTimeManager.app` (ignored build artifact).

### Remaining issues and user checks

- No unresolved merge conflict, failing test, or build/package blocker remains. M2/M4/M5 remain partial pending live acceptance and existing hardening work; this integration does not claim complete MVP acceptance.
- Live Microsoft login/consent and macOS Calendar permission/account behavior remain untested. Open the rebuilt main-project bundle after quitting other copies. Check that all three Connections panels scroll correctly in normal/full-screen windows, and cached Canvas data/completion choices remain visible. Connecting accounts or requesting Calendar access is up to the user.
- For Calendar acceptance, follow `docs/APPLE_CALENDAR.md` with synthetic future work and a dedicated test calendar. Preview/dismiss first, then explicitly approve a small plan; verify repeat publication, cancellation and undo. Do not run multiple copies against the ownership journal concurrently.
- Personal Calendar events constrain planning and now appear as title-only, transient Timeline entries after a user refresh. Published sessions remain until explicitly canceled even if their assignment is completed or omitted from a new proposal.
- Remote Calendar propagation is not confirmed by local EventKit saves. Uncertain writes deliberately block retries pending read-only recovery. Existing limits include no Developer ID/notarization, no multi-process journal coordination, conservative email extraction and user-led visual checks.
- Historical reports below describe their original branch/session state; this integration section supersedes earlier “unmerged,” “unimplemented,” and old application-path statements.

## Previous milestone task — Microsoft Outlook integration (2026-10-19)

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

## Calendar branch implementation — Apple Calendar integration (2026-10-19)

### Scope and delivered behavior

Implemented the user-authorized Apple Calendar integration slice on `feature/calendar-integration`, in `/Users/davidzhu/Desktop/academic-time-manager-calendar`. The original project working files were not modified. No next milestone was started, no branch was merged, and no remote is configured. M2/M4 remain partial overall; this historical branch report is retained; the integration report above supersedes its unmerged state.

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
| M2 — Account integrations | Partial | Oxford Canvas read-only sync is implemented and mock-tested. Microsoft Graph multi-account PKCE/Inbox delta/local analysis/batch review is implemented with mocks; real login awaits user setup. EventKit authorization, busy constraints, transient title-only Timeline display, and approved publication are implemented with mocks; no real account or permission prompt was used. |
| M3 — Academic intelligence | Partial | Provider-independent interfaces and validation exist. Local email/attachment extraction, editable estimates, and deterministic stages are implemented; no cloud/general-language inference provider is active. |
| M4 — Scheduling and calendar | Partial | Day/week/month unified calendar UI and deterministic local proposals are implemented. EventKit preview/approval, safe publication, cancellation, undo, ownership audit, transient personal-event display and refresh are wired. End-to-end live acceptance remains unverified. |

| M5 — Hardening and packaging | Partial | Debug/release suites pass; local Apple Development-signed bundle has strict signature checks. No notarization, Developer ID signing, or in-app visual smoke test. |

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
- EventKit permission handling, busy-time discovery, managed-calendar setup, preview/approval, duplicate-safe writes, cancellation, recovery, undo, and title-only transient Timeline display are integrated and mock-tested. Live permission/account behavior and Timeline refresh from a real Calendar remain unverified. No permission was requested and no calendar was changed during development.
- General-language AI inference remains unavailable. Email date extraction is deterministic and conservative; automatic effort estimation remains unimplemented.
- Study proposals remain transient. Calendar publication has exact-preview approval and a persistent ownership/audit/undo journal; estimates and full proposal history are not persisted.
- SQLite application data is not encrypted at the application layer; retention and user deletion controls remain future hardening work.
- The authorized Calendar merge is recorded on `main`, preserving both parent histories and the pre-merge backup. No remote push was performed.

## Next priorities

1. User opens the rebuilt app and verifies completion/reopening and restart persistence using the steps above; optionally initiates a sync to verify preservation and submission suggestions. No token needs to be sent to Codex.
2. Add fixture coverage for calendar batches beyond ten course contexts and explicit SQLite rollback on commit failure; consider a documented reconciliation policy for remotely changed/deleted items.
3. Decide whether the app needs a documented server-side delta mechanism or if periodic paginated refresh is acceptable for Canvas; widen or configure the event date window if required.
4. User registers the Microsoft public client, confirms delegated scopes/consent, and interactively verifies both accounts with the new setup guide. Do not initiate real login on the user's behalf.
5. User verifies the integrated Calendar flow with synthetic future assignments and a dedicated test calendar using `docs/APPLE_CALENDAR.md`. Live permission, creation and event writes require explicit user actions. Unified Calendar event display remains future work.
6. Persist user effort estimates/proposals and connect approvals/audit to the plan. Keep AI inference behind the existing provider interface and require review for uncertain extracted deadlines.
7. Perform a user-led visual smoke test, then address code signing/notarization and local data retention/deletion before distribution.

## Manual verification

1. Open `build-output/AcademicTimeManager.app`.
2. In **Connections**, ensure Oxford Canvas shows the saved/connected state. If it does not, use **Test saved connection**; never paste the token into Codex.
3. Press **Sync** in the toolbar. Observe the progress indicator, imported counts, and last-success timestamp.
4. Return to **Timeline**. Switch Day/Week/Month, navigate dates, and confirm Oxford Canvas records have an imported badge while fixtures say **Demonstration data**. Expand event details to inspect source/timezone.
5. In **Plan preview**, adjust effort and priority for deadlines, generate a proposal, and check that protected events/rest are avoided. After a sync, generate again because the prior proposal is invalidated.
6. Test the Connections page in a normal and full-screen window; confirm vertical scrolling reaches the token field and status.
