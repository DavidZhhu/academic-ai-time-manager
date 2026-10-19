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
- Current schema migration history has versions 1–3. Version 3 adds `assignment_progress`, keyed by stable assignment ID, with local status (`notStarted`, `inProgress`, or `completed`) and an update timestamp. Missing rows mean Not Started. Canvas imports never update or delete this table.
- Optional source-record assignment metadata retains a due date (including an explicitly missing deadline) and minimal current-user submission evidence: submission timestamp and workflow state. It never contains submission bodies or grades. These imported facts are separate from the user's local completion decision; old source JSON remains readable.
- Planning filters out completed, overdue (deadline at or before the current instant), and undated assignments before generating study activities. Completed takes precedence over overdue for display. Reopening restores Not Started, but a past deadline still prevents scheduling. Proposals expire at the earliest eligible deadline and are invalidated when local status changes or Canvas sync succeeds.
