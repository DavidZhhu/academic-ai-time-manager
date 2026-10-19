# Architecture Constraints and Candidate Design

## Stack selection is a milestone, not a presupposition
At M0 Codex must evaluate Swift/SwiftUI, Python/PySide6, and Tauri/React/Rust, including macOS EventKit, Keychain, notifications, packaging, OAuth callback handling, test tooling, AI/document parsing, and maintainability. Record selection in `docs/DECISIONS.md` before major implementation.

## Logical components
1. Desktop UI: onboarding, timeline, review inbox, assignment/task view, plan editor, sync health, preferences.
2. Local application service: orchestration, jobs, permissions, error reporting.
3. Integration adapters: Canvas REST API, Microsoft Graph API, Apple EventKit.
4. Normalization and provenance: canonical event/task schema, deduplication, timezone normalization, source records.
5. AI gateway: pluggable providers, structured outputs with schema validation, content minimization, prompt-injection resistance.
6. Planning engine: deterministic hard constraints and prioritization; AI provides task breakdown/effort estimates, not unchecked calendar mutations.
7. Local database: SQLite or equivalent with migrations, audit history, sync cursors, task state, user preferences.
8. Credential service: macOS Keychain.
9. Future cloud boundary: optional sync/notification workers behind interfaces, no cloud dependency for MVP.

## Core data flow
Canvas/Graph -> sync adapters -> source records -> normalization + dedup -> classification/extraction -> review/conflict detection -> canonical tasks/events -> AI task decomposition -> constraint scheduler -> proposed plan -> approval policy -> dedicated Apple Calendar.

## Scheduling invariants
- `AcademicDataset` scopes both assignments and fixed commitments before planning, and supplies the same scoped records to Timeline and Review Inbox. The default is Live data; Demo Mode is an explicit session choice. Switching clears the proposal. No storage deletion or status reset is involved.
- Scope follows stored source provenance, never event titles. Existing `Canvas` and `Outlook` sources are live; known sample source IDs and `Canvas (sample)`/`Outlook (sample)` providers are demo. Every referenced source must resolve to the chosen mode; unknown/mixed provenance is excluded, with records preserved. Future adapters must define their origin before their records enter planning.
- Fixed events and user-defined protected hours are hard constraints.
- No overlapping AI-managed blocks, no calendar writes without appropriate permissions.
- Deadlines are hard endpoints unless explicitly marked uncertain.
- Prefer early progress and buffer time; show unallocated work explicitly.
- User overrides outrank AI proposals; preserve original source facts.
- Any change affecting protected commitments requires explicit confirmation.

## Near-real-time caveat
Microsoft Graph change notifications may require a publicly reachable HTTPS endpoint and subscription lifecycle management; Canvas may not expose equivalent per-user push events. MVP should use robust polling/delta sync with backoff and catch-up. Evaluate push mechanisms separately and do not promise instant delivery while Mac is off.

## Test strategy
Unit tests for extraction schemas, date parsing, deduplication, conflict policies, scheduler invariants; mocked integration tests for Canvas/Graph/EventKit; manual smoke tests on macOS; permission-denial and offline cases; DST regression fixtures; provider failures; calendar rollback tests.


## Current implementation boundary (2026-10-19)

The app uses SwiftUI, a Swift domain library, and SQLite. `CanvasImporter` is read-only and transport-injected; it retrieves active courses, course assignments, and course calendar events. Canvas supplies pagination links but does not expose a shared delta cursor for these endpoints, so each sync refreshes the relevant course and event windows and merges by stable provider/external IDs. This is an idempotent local incremental merge, not a server-side delta feed; the app never removes Canvas records on a sync. Tests use fixture responses only. `AssignmentAnalysisProvider` currently has a fixture-only provider and deterministic output validation, not an inference backend. The scheduler consumes local availability, protected rest windows, and imported fixed events and returns local proposals. The separate CalendarAwarePlanning entry point adds user-requested Apple Calendar busy intervals; AppleCalendarService publishes only an explicitly approved preview through EventKit. The Canvas token store uses macOS login Keychain ACLs for the ad-hoc-signed local app. Microsoft Graph multi-account authentication, read-only Inbox sync, and local analysis are implemented with mocks; real authentication awaits user registration/consent and interactive testing. The implemented EventKit adapter requires user-initiated full access and separate calendar/setup/publication approval; development uses only mocks. See `tasks/STATUS.md` for remaining acceptance work.

## Outlook implementation decision (2026-10-19)

- Native AuthenticationServices + explicit authorization-code/PKCE protocol keeps the existing dependency footprint small. A public Entra app ID and registered callback are required; no client secret is embedded. OAuth state and challenge are generated with system cryptographic randomness. Account identity is established by Graph `/me`, not by decoding an unverified ID token. Login, test, refresh, and sync use injected transports for tests.
- `OutlookState` lives under a namespaced `app_settings` SQLite row. It holds account metadata, cursors, revision hashes, rules, and review proposals; credentials are exclusively in `MicrosoftCredentialStore`/Keychain. Import and review commit atomically with canonical source/event/audit records. Existing schema and Canvas progress tables are preserved. This compact store suits the current single-user application; large histories should move to indexed tables before scaling.
- The shared app-level `OutlookViewModel` prevents overlapping UI/polling operations across windows. Each request creates a per-account session that refreshes credentials through a coalesced task. Polling uses persisted settings and backs off after failed attempts. The same sync function can later be triggered by authenticated change notifications; no listener or subscription exists yet.
- Message/attachment text is untrusted data. `EmailAnalysisProvider` output is validated for source/account identity, evidence, confidence, pending decision, and limits. The implemented provider runs locally and handles explicit dates conservatively. Cloud providers are disallowed until a separate disclosure/consent configuration is implemented.
- Pending email proposals do not enter planning. Explicit local approval creates protected canonical events or deadlines; reviewed cancellation/reschedule advisories preserve existing events. Demo sources remain excluded from real planning and conflict checks. Exact title/kind/start/duration duplicates merge provenance; conflicting proposals remain visible for human review.

## Apple Calendar boundary

The native adapter, approval service, busy-time planning wrapper and SwiftUI controls live in separate Calendar files. An atomic ownership journal stores app-owned mappings, write intents, audit and undo without adding a SQLite migration. Personal event snapshots remain in memory. Every update/cancellation checks the dedicated calendar ID, per-event UUID marker and last-confirmed snapshot; ambiguous outcomes disable further publication pending read-only reconciliation. See [APPLE_CALENDAR.md](APPLE_CALENDAR.md) for contracts, safety limits and merge guidance.

## Combined main integration (2026-10-19)

- Connections hosts the existing Canvas controls, multi-account Outlook controls, and Apple Calendar controls together. The shared app-level planner owns the Calendar service/UI state; Outlook remains shared across windows. Creating the UI does not construct an EventKit store or request access.
- Both Canvas sync and Outlook import/review invalidate the local study proposal and any Calendar approval preview. Outlook reload invalidates before reading SQLite so a failed reload cannot leave an approval based on superseded commitments. Completion, estimates, availability, and mode changes also invalidate previews.
- The Calendar planning wrapper consumes the same live/demo dataset and local completion table as the original planner. Approved Outlook events and Canvas commitments remain hard constraints alongside transient Calendar busy intervals. Pending mail and demo records cannot enter live planning; completed/overdue work stays excluded. Calendar publication never changes mailbox contents, Canvas records, or assignment completion status.
- No schema migration or credential-store change is introduced by this merge. SQLite retains imported data, Outlook state and completion choices; the independent ownership journal retains only managed-event state. The bundle contains both the Microsoft OAuth callback scheme and Calendar full-access usage description, retaining the existing ad-hoc signing identity.
- Automated combined coverage uses temporary SQLite, mock Calendar events and synthetic Outlook review records, including repeated Canvas import and database reopen. Live permissions, OAuth, actual accounts and UI interaction remain user-led acceptance checks.

## Unified Apple Calendar Timeline (2026-10-19)

- `AppleCalendarService` projects busy EventKit occurrences into an in-memory `AppleCalendarTimelineEvent`; it does not create `SourceRecord` or SQLite rows. The user must first refresh a granted Calendar connection. EventKit change notifications then refresh the currently displayed Day, Week, or Month range while the app runs.
- The projection treats external busy events as protected commitments and retains each title only in the in-memory Timeline value used for local rendering. It retains no notes, locations, attendees, URLs, calendar account names, or other personal metadata. A process-local normalized title hash exists only long enough to collapse an exact Canvas/Outlook mirror; neither the hash nor the title is serialized. App-owned sessions are recognized only by the existing journal marker and last-confirmed record, and remain the only sessions eligible for change.
- EventKit returns recurring occurrences expanded within the queried range. Occurrence IDs include the start/end instant so separate recurrences display separately. All-day state is carried through the projection and old ownership journals decode with `isAllDay` defaulting to false. Timeline filtering uses date-interval overlap, so multi-day/all-day commitments appear in every applicable Day, Week, and Month view.
