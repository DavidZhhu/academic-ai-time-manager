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

The app uses SwiftUI, a Swift domain library, and SQLite. `CanvasImporter` is read-only and transport-injected; it retrieves active courses, course assignments, and course calendar events. Canvas supplies pagination links but does not expose a shared delta cursor for these endpoints, so each sync refreshes the relevant course and event windows and merges by stable provider/external IDs. This is an idempotent local incremental merge, not a server-side delta feed; the app never removes Canvas records on a sync. Tests use fixture responses only. `AssignmentAnalysisProvider` currently has a fixture-only provider and deterministic output validation, not an inference backend. The scheduler consumes local availability, protected rest windows, and imported fixed events and returns local proposals; it does not write calendar events. The Canvas token store uses macOS login Keychain ACLs for the ad-hoc-signed local app. Microsoft Graph is implemented with mocks; real authentication awaits user registration/consent and interactive testing. EventKit remains unimplemented and gated on explicit permission. See `tasks/STATUS.md` for remaining acceptance work.


## Outlook implementation decision (2026-10-19)

- Native AuthenticationServices + explicit authorization-code/PKCE protocol keeps the existing dependency footprint small. A public Entra app ID and registered callback are required; no client secret is embedded. OAuth state and challenge are generated with system cryptographic randomness. Account identity is established by Graph `/me`, not by decoding an unverified ID token. Login, test, refresh, and sync use injected transports for tests.
- `OutlookState` lives under a namespaced `app_settings` SQLite row. It holds account metadata, cursors, revision hashes, rules, and review proposals; credentials are exclusively in `MicrosoftCredentialStore`/Keychain. Import and review commit atomically with canonical source/event/audit records. Existing schema and Canvas progress tables are preserved. This compact store suits the current single-user application; large histories should move to indexed tables before scaling.
- The shared app-level `OutlookViewModel` prevents overlapping UI/polling operations across windows. Each request creates a per-account session that refreshes credentials through a coalesced task. Polling uses persisted settings and backs off after failed attempts. The same sync function can later be triggered by authenticated change notifications; no listener or subscription exists yet.
- Message/attachment text is untrusted data. `EmailAnalysisProvider` output is validated for source/account identity, evidence, confidence, pending decision, and limits. The implemented provider runs locally and handles explicit dates conservatively. Cloud providers are disallowed until a separate disclosure/consent configuration is implemented.
- Pending email proposals do not enter planning. Explicit local approval creates protected canonical events or deadlines; reviewed cancellation/reschedule advisories preserve existing events. Demo sources remain excluded from real planning and conflict checks. Exact title/kind/start/duration duplicates merge provenance; conflicting proposals remain visible for human review.
