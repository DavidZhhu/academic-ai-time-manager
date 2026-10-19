# Project start guide

Read `AGENTS.md`, the product/architecture/security/integration/data-model documents, and `tasks/ROADMAP.md`, `tasks/BACKLOG.md`, and `tasks/STATUS.md` before making changes.

The stack decision and M0 scaffold are recorded in `docs/adr/ADR-000-stack-selection.md`. M1 is implemented. Current development is fixture-only for Canvas, analysis, and scheduling. Check `tasks/STATUS.md` before continuing so offline and consent boundaries stay clear.

## Safe local checks

- `swift test`
- `swift test -c release`
- `swift run AcademicTimeManager` on macOS 14 or later
- `./scripts/package-macos.sh` to create an unsigned local app bundle

Do not access personal files, live university accounts, credentials, or calendar data. Do not initiate OAuth consent or EventKit permission prompts, call an external AI provider, incur costs, push remotely, or publish calendar events without the necessary explicit user request and implementation review. Keep examples synthetic and connectors mocked.
