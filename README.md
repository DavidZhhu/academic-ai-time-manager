# Academic Time Manager

A local-first macOS desktop application that connects Canvas LMS, Microsoft 365 Outlook, and Apple Calendar to build an AI-assisted academic schedule.

## MVP outcome
A user can securely connect accounts, see imported academic events and deadlines, inspect AI-extracted assignment tasks and workload estimates, approve important changes, and publish conflict-free study blocks to a dedicated Apple Calendar.

## Operating principles
- macOS-only; local-first and cloud-ready.
- Microsoft OAuth 2.0 / Graph API; Canvas token or approved API authentication; Apple Calendar via EventKit or equivalent supported macOS API.
- Store secrets in macOS Keychain. Do not commit credentials, tokens, email bodies, or student documents.
- Cloud AI is allowed for relevant academic material with clear disclosure and configurable provider selection.
- AI proposes interpretations and plans; deterministic validation and explicit approval govern important changes.
- Codex works milestone-by-milestone, runs tests, updates project records, and stops for user review.

## Getting started with Codex
1. Open this directory as the Codex project.
2. Ask Codex to read `AGENTS.md`, `docs/PRD.md`, `docs/ARCHITECTURE.md`, and `tasks/ROADMAP.md`.
3. Start with milestone M0: architecture decision record and project scaffolding; do not start account integrations before the user approves M0.
4. Provide secrets only through the application's secure configuration flow, never chat or committed files.

## Connect Oxford Canvas

In the running app, open **Connections**, paste your Canvas API token into the **Canvas API token** secure field, and select **Save token and test connection**. The app stores the token in macOS Keychain and checks it with a read-only request to Oxford Canvas. You can test a saved token again or remove it from Keychain in the same screen. Removing it from this app does not revoke the token in Canvas.

## Live data and Demo Mode

The app opens in **Live data** mode, showing cached Oxford Canvas data, approved Outlook commitments, and—when full Apple Calendar access already exists—protected Apple Calendar events for the visible Timeline range. Select **Demo Mode** using the data-mode control at the top of the page to explore the preserved samples. Timeline, Plan Preview, and Review Inbox follow the same selection. Sample assignments never enter real study plans, and sample events never block real study time.

Switching modes clears the current proposal without deleting records or changing completion status. Mode selection lasts for the current session; restarting returns to Live data. Sync is disabled in Demo Mode. An empty Canvas cache stays empty until you initiate a sync; it never falls back to sample assignments.

## Connect Microsoft Outlook

See [Microsoft setup](docs/MICROSOFT_SETUP.md) for the Entra registration and consent steps. In **Connections**, enter the non-secret client ID, save settings, and choose **Add Microsoft account** separately for Oxford and personal Outlook/Hotmail. Microsoft handles login in a browser; the application stores tokens in Keychain. Use each account's **Synchronise now** button, then review proposals in **Review inbox**. Polling is optional and off by default. Outlook sync and review never write to mailboxes or publish to Apple Calendar. Calendar publication uses the separate preview and approval flow below.

Both accounts use shared local classification rules. Relevant PDF/DOCX attachments are processed within safety limits. Uncertain dates need confirmation, and cancellation/rescheduling proposals remain advisory. No cloud AI transmission occurs.

## Track assignment progress

Open **Plan preview** and use each assignment's **Local status** menu to select **Not Started**, **In Progress**, or **Completed**. Changes are saved immediately in SQLite and survive restarts and Canvas sync. Completed assignments move to their own section; choose **Reopen** to return one to Not Started.

Only unfinished assignments with future deadlines receive new study sessions. Past deadlines appear under **Overdue**; undated assignments appear under **No deadline**. Reopening an overdue assignment does not change its deadline or schedule new work. Generate a new proposal after changing status. Where Canvas supplies submission evidence, the app offers a completion suggestion for you to confirm; it never changes your Canvas submission or automatically marks local work finished.

## Apple Calendar

When ready to test, open **Connections → Apple Calendar**, explicitly request Calendar access, select an account, and approve creation of the dedicated **Academic AI Time Manager** calendar. Generate a live plan, select **Preview Apple Calendar changes**, then approve the exact changes. Previewing alone makes no writes. Demo plans cannot be published.

Connections also offers previewed cancellation and undo of the last event change. Once you have granted full access, restarting the app automatically loads Apple Calendar events for the active Timeline range without another permission prompt. Busy personal events appear in Timeline as orange, protected **Apple Calendar** entries with their original title. The title remains only in local transient memory; notes, locations, attendees and URLs are not retained. Green entries are study sessions owned by the app. Only owned study sessions can be changed. See [Apple Calendar integration](docs/APPLE_CALENDAR.md) for recovery limits and the user-led test-account checklist. No real calendar was accessed during development.

## Project map
- `AGENTS.md` — Codex execution contract.
- `docs/PRD.md` — product requirements and acceptance criteria.
- `docs/ARCHITECTURE.md` — system boundaries and design constraints.
- `docs/SECURITY.md` — privacy, permissions, and threat controls.
- `docs/INTEGRATIONS.md` — Canvas, Microsoft Graph, Apple Calendar contracts.
- `docs/DATA_MODEL.md` — entities, provenance, and sync semantics.
- `docs/DECISIONS.md` — open architecture decisions and ADR template.
- `tasks/ROADMAP.md` — milestones, deliverables, and gates.
- `tasks/BACKLOG.md` — implementation tasks and priorities.
- `tasks/STATUS.md` — living execution log.

To create a local `.app` bundle, use the packaging script. It selects the sole available Apple Development identity, verifies the stable identifier and Apple trust chain, and fails if stable signing is unavailable:

```sh
./scripts/package-macos.sh
```

The bundle is written to `build-output/AcademicTimeManager.app` by default. An explicit ad-hoc escape hatch exists only for disposable builds and does not preserve macOS privacy identity. See [Development signing](docs/DEVELOPMENT_SIGNING.md) for identity selection, verification, certificate renewal, and distribution limits. Developer ID signing, notarization, and distribution are not configured.
