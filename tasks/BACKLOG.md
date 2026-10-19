# Implementation Backlog

Priority: P0 required for MVP, P1 after MVP. Real services remain gated on user/institution setup; fixture-based adapters and tests are safe to develop offline.

| ID | Milestone | Priority | Task | Evidence of completion | Status |
|---|---|---|---|---|---|
| T001 | M0 | P0 | Compare stacks and record ADR | Weighted decision with macOS API evidence | Complete |
| T002 | M0 | P0 | Scaffold app, test harness and CI | Local Swift build/tests; macOS CI workflow | Complete |
| T003 | M0 | P0 | Confirm API scopes and consent constraints | Feasibility checklist; no account access | Complete |
| T004 | M1 | P0 | Implement canonical entities and migrations | SQLite migrations and serialization tests | Complete |
| T005 | M1 | P0 | Build sample-data timeline and review UI | Timeline, review inbox, availability settings | Complete |
| T006 | M2 | P0 | Canvas incremental importer | Mock pagination/retry, transactional import, repeat-sync tests | Complete for polling merge: active courses, assignments/deadlines, calendar events, pagination, retries, timezone, idempotent SQLite merge, last-success status; Canvas has no shared delta cursor for these endpoints |
| T007 | M2 | P0 | Microsoft Graph PKCE and mail importer | Mock auth, delta and filtering tests | Gated: app registration/scopes unknown |
| T008 | M2 | P0 | EventKit adapter | Dedicated-calendar idempotency tests | Gated: no permission prompt or account access |
| T009 | M3 | P0 | Provider-independent AI gateway | Schema validation and failure tests | Partial: protocol and fixture provider only |
| T010 | M3 | P0 | Academic email classification and extraction | Precision review on fixtures | Not started |
| T011 | M3 | P0 | Assignment decomposition and effort estimates | Editable outputs and evidence | Partial: deterministic editable effort and stage breakdown in local plan UI; provider interface/validator remain fixture-only |
| T012 | M4 | P0 | Constraint scheduler | No-overlap, deadline, protected-time tests | Partial: deterministic core and UI proposal; fixed events, protected rest, breaks, priority, source, and local rescheduling covered; no calendar publication |
| T013 | M4 | P0 | Approval, conflict, audit and undo | Conflict and rollback tests | Partial: conflict/approval/audit storage, no UI/write/undo |
| T014 | M5 | P0 | Package and document macOS release | Clean-install smoke test | Partial: ad-hoc-signed local `.app`; no Developer ID signing/notarization |
| T015 | Future | P1 | AI conversation and daily briefings | Deferred | Deferred |
| T016 | Future | P1 | Hybrid study tracking and learning | Deferred | Deferred |
