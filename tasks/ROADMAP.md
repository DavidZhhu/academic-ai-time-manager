# Milestone Roadmap

Codex must stop and request approval at the end of **every** milestone.

## M0 — Architecture and scaffolding
Deliver stack comparison/ADR, repository structure, local dev setup, CI/test skeleton, sample data, app shell mock, privacy and API feasibility checklist. Gate: user approves stack and runnable scaffold.

## M1 — Local app + canonical model
Deliver database/migrations, source provenance, timeline UI with fixtures, availability settings, review state, calendar permission spike. Gate: tests pass and user can inspect sample academic schedule.

## M2 — Real account integrations
Deliver Canvas connector, Microsoft Graph OAuth and relevant mail ingestion, Apple Calendar read/write adapter, incremental sync, health/error UI, test fixtures. Canvas read-only fixture-tested importer is implemented. Microsoft Graph multi-account PKCE, Inbox delta sync, local email/attachment extraction and batch review are implemented with mocks. Real Microsoft login remains gated on Entra registration, consent, and user-led verification; EventKit remains unimplemented. Gate: user verifies test-account sync and no duplicate records; write operations limited to dedicated calendar.

## M3 — Academic intelligence
Deliver configurable provider gateway, email relevance filtering, structured event extraction, assignment breakdown, workload estimates, evidence/confidence and review UI. Typed analysis schema and validation are implemented with a fixture-only provider; live inference remains gated on explicit provider/disclosure/cost configuration. Gate: user validates representative academic cases; incorrect/uncertain data is not silently committed.

## M4 — Scheduling and calendar publication
Deliver constraint scheduler, task priority and availability settings, plan preview, approval policy, calendar write-back, conflicts and undo. Deterministic scheduling with breaks, local preview, conflict detection, and approval/audit persistence primitives are implemented; conflict resolution UI and EventKit write-back remain. Gate: end-to-end MVP acceptance scenarios in PRD pass.

## M5 — MVP hardening and packaging
Deliver macOS installer/build, permission/onboarding polish, error recovery, privacy review, end-to-end regression tests, release notes, and known limitations. Gate: user approves first usable release.

## Future phases (not MVP)
Conversational assistant, study timer, manual/automatic activity tracking, adaptive productivity model, briefings/notifications, optional cloud service.
