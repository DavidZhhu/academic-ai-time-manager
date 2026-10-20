# Proposed Canonical Data Model

- `SourceConnection`: id, provider, account_label, auth_state, last_sync_at, sync_cursor, permissions.
- `SourceRecord`: id, provider, external_id, content_hash, fetched_at, source_uri, payload_reference, retention_class.
- `AcademicEvent`: id, title, starts_at, ends_at, timezone, kind, fixed, status, verification_state, source_record_ids.
- `Deadline`: id, task_id, due_at, timezone, verification_state, source_record_ids.
- `Assignment`: id, course_id, title, description_ref, due_at, source_record_ids, user_overrides.
- `Subtask`: id, assignment_id, title, estimated_minutes, difficulty, priority, dependency_ids, status.
- `StudyBlock`: id, subtask_id, start_at, end_at, state, calendar_external_id, plan_revision.
- `AvailabilityRule`: id, recurrence, protected, start/end local times, timezone, priority.
- `Conflict`: id, field, candidate_values, source_record_ids, state, resolution, resolved_by.
- `Approval`: id, action_type, proposed_diff, risk_level, decision, decided_at.
- `AuditEntry`: id, actor, action, target_id, before/after references, timestamp.
- `AIAnalysis`: id, provider, model, input_refs, schema_version, result, confidence, user_correction.

All timestamps must be stored unambiguously with timezone context. Distinguish unknown values from inferred ones. Define migrations and retention behavior before using real accounts.


## Implementation notes

- Source records, academic items, review items, availability settings, conflicts, approvals, audit entries, and schema migration versions are stored in SQLite.
- Conflicts retain all candidate values and source IDs as unresolved until a future user-facing resolver is added. The sample review inbox displays a synthetic Canvas/Outlook deadline conflict; the detector never chooses a winner.
- Approval and audit records can be persisted locally; current plan preview does not use them to trigger calendar writes.
- Current schema migration history has versions 1–4. Version 4 is additive: `canvas_record_status(record_id, record_kind, state, payload_json)` records whether a Canvas source record or academic item is `withdrawn` or `active`, with a reason and time. Opening an older store only creates the empty table; no existing row changes. Version 3 and earlier are described next. Version 3 adds `assignment_progress`, keyed by stable assignment ID, with local status (`notStarted`, `inProgress`, or `completed`) and an update timestamp. Missing rows mean Not Started. Canvas imports never update or delete this table.
- Optional source-record assignment metadata retains a due date (including an explicitly missing deadline) and minimal current-user submission evidence: submission timestamp and workflow state. It never contains submission bodies or grades. These imported facts are separate from the user's local completion decision; old source JSON remains readable.
- Planning filters out completed, overdue (deadline at or before the current instant), and undated assignments before generating study activities. Completed takes precedence over overdue for display. Reopening restores Not Started, but a past deadline still prevents scheduling. Proposals expire at the earliest eligible deadline and are invalidated when local status changes or Canvas sync succeeds.


## Canvas reconciliation

`items()` and `sourceRecords()` return active records only; `allItems()`, `allSourceRecords()` and `canvasRecordStatuses()` expose history. A complete fetch withdraws records Canvas no longer provides, but only inside what that fetch verifiably covered: an assignment only when its course's assignment pages were all read; an event only when every event request succeeded and its start lies inside the requested window (minus a one-day margin on each side); an assignment or course only when the active-course list was read and omits that course. An empty course list never withdraws anything. A cleared due date withdraws the deadline item but keeps the undated assignment. An item that also carries approved non-Canvas sources (for example an accepted Outlook event) is kept and loses only its Canvas source IDs. Each change writes an `AuditEntry` (actor `canvas-sync`). Local completion status is never touched, repeated syncs are idempotent, and a partial fetch is not recorded as the last successful sync.

## Outlook local state

The existing `app_settings` table stores an `outlook_state` value; no destructive schema migration is needed. Account IDs hash client ID plus the Graph profile ID. Message/source IDs include account identity and immutable message ID, preventing same-ID collisions across accounts. State stores accounts, shared rules, final delta cursors, message revision hashes, and `EmailProposal` records with evidence/confidence, account/message/attachment references, review decision, withdrawn state, and duplicate/conflict annotations. Full message bodies, original attachments, and authentication credentials are absent.

Imports save source references and the final cursor with review changes in one SQLite transaction. Batch review saves canonical events, decisions, and audit entries atomically. Stable imports preserve decisions when evidence is unchanged. Changed/removed sources withdraw old proposals without removing approved commitments. Completion tracking and Canvas data retain their existing identities and storage.
