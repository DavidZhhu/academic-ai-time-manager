# Product Requirements Document

## Vision
An AI-assisted personal academic time manager that automatically gathers university commitments and converts academic work into a realistic, explainable study plan while preserving user control and personal time.

## Target user and platform
One university student, intermediate programming ability, macOS desktop. Initially single-user, local-first, with future optional cloud workers.

## Confirmed decisions (25-question discovery)
- Semi-autonomous changes: flexible study blocks may move automatically; important commitments require approval.
- Canvas LMS for course information, assignments, announcements, timetable/deadlines where available.
- Microsoft 365 Outlook via Graph for tutorial/event information and relevant academic emails.
- Apple Calendar as the calendar integration.
- AI estimates workload, decomposes academic assignments, prioritizes tasks, and schedules study.
- Long-term: adaptive planning from timer, manual progress, optional permission-based activity tracking; daily briefings, notifications, dashboard and AI chat.
- Model provider is interchangeable (cloud and local); cloud AI may process relevant academic content with disclosure.
- Near-real-time sync where practical, periodic catch-up otherwise.
- Local-first initially, cloud-ready later.
- Hybrid email relevance filter (approved senders/folders + AI classification + corrections).
- Conflicts between sources are surfaced for confirmation, not silently resolved.
- GitHub plus autonomous milestone implementation, with review/approval at each milestone.
- End-to-end MVP first; MVP scope is **Intelligent Academic Planner**.

## MVP functional requirements
**FR-01 Account setup:** Configure Canvas API access and Microsoft 365 OAuth; show connection health and actionable errors.

**FR-02 Ingestion:** Import Canvas courses, assignments, due dates, relevant course events and announcements (subject to API availability). Import relevant Outlook emails and meeting details, and read busy times from Apple Calendar with user permission. Sync on launch, periodically, and on supported notifications.

**FR-03 Relevance and extraction:** Filter Outlook messages by user-defined senders/folders and AI-assisted classification; extract tentative event details with source link, timezone, confidence, and evidence. Show review queue for uncertain items.

**FR-04 Unified timeline:** Show classes, tutorials, deadlines, existing calendar commitments, and AI-managed study blocks, with source attribution and sync status.

**FR-05 Academic task understanding:** Interpret assignment instructions and permitted attachments, split work into actionable subtasks, estimate effort and difficulty, and let user edit estimates or reject AI suggestions.

**FR-06 Scheduling:** Plan flexible study blocks around hard commitments, configurable availability, protected rest, deadlines, priorities, and workload. Avoid overlapping blocks and show unschedulable work rather than hiding it.

**FR-07 Calendar write-back:** Write approved/eligible study blocks to a dedicated Apple Calendar. Make writes idempotent and reversible; changes to important commitments require approval.

**FR-08 Conflict management:** When sources disagree about a deadline or meeting, show both, preserve provenance, and ask the user to resolve the conflict.

**FR-09 Controls:** User can edit or override task estimates, study blocks, and priority; disconnect sources; request sync; inspect proposed changes.

**FR-10 AI provider configuration:** Provider-agnostic interface with at least one working implementation in MVP, clear provider configuration, failure fallback, and disclosure of external processing.

## Nonfunctional requirements
- Security: Keychain secrets, least-privilege access, no credentials in logs, secure local storage.
- Reliability: restart-safe, idempotent imports, retry/backoff, offline-safe operation, duplicate prevention.
- Correctness: timezone/DST-aware dates; provenance and confidence; deterministic conflict checks.
- Accessibility: keyboard-accessible desktop UI, clear error and review states.
- Maintainability: isolated adapters and business logic, automated tests, versioned database migrations.
- Observability: local privacy-preserving diagnostics and sync status.

## MVP acceptance scenarios
1. A new Canvas assignment appears once, with correct title, source, and due time, after repeated syncs.
2. A relevant tutor email generates a proposed tutorial event with extracted time, evidence, and confidence; ambiguous information requires review.
3. A problem sheet can be decomposed into editable subtasks with estimated work hours.
4. The planner allocates study blocks before the deadline without collisions or protected-time violations; impossible schedules produce an explicit warning.
5. Approved study blocks appear in a dedicated Apple Calendar and update without duplicates.
6. Contradictory Canvas and Outlook deadlines are shown as a conflict; the system does not silently overwrite either.
7. Restart, offline mode, expired authentication, and DST changes have tested behavior.
8. A user can disconnect integrations and remove locally cached source data through a documented flow.

## Explicitly post-MVP
Conversational assistant; study timer; manual progress tracking; optional automatic activity tracking; learning productivity patterns; sophisticated adaptive prioritization; daily briefings; broad notification automation; always-on cloud worker; cross-device sync.

## Open UX settings (use configurable defaults, do not block M0)
Study hours, break duration, protected time, sync frequency, notification preferences, AI provider credentials, relevant senders/folders, time estimate calibration, timezone display, and retention policy.
