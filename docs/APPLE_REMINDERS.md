# Apple Reminders — Stage 1 (read-only)

Stage 1 reads Apple Reminders through EventKit so reminders can appear next to academic work. It **never creates, edits, completes or deletes** a reminder, and reminder content is **never sent off the device**. Write-back, AI estimation and scheduling are separate, later stages.

## Permission and connection flow
- Connections › **Apple Reminders** → *Request Reminders access…* calls `requestFullAccessToReminders()`. This is the only call that can show the macOS prompt, and only after the user presses the button.
- Launch, change notifications and periodic refresh call `syncIfAuthorized()`, which reads `EKEventStore.authorizationStatus(for: .reminder)` and does nothing unless it is `fullAccess`. Application startup therefore never prompts.
- Packaging adds `NSRemindersFullAccessUsageDescription`. The app is unsandboxed, so no entitlement is added (same as Calendar). Write-only access is treated as unusable and the UI explains how to grant Full Access.
- Revocation (`denied`, `restricted`, `writeOnly`, including mid-read): the in-memory snapshot is cleared immediately, the change observer is cancelled, and the UI says how to re-enable access.

## What is imported
Per reminder: title, notes, due date (date-only or date+time, with time zone when set), priority (EventKit 1–4 → High, 5 → Medium, 6–9 → Low), completion state and date, http(s) URL, recurrence flag + short summary, last-modified date, device identifier (`calendarItemIdentifier`), cross-device identifier (`calendarItemExternalIdentifier`), and the owning list (identifier, title, account/source identifier and title). All accessible lists are read.

## EventKit limitations (public API, verified against `EKReminder`/`EKCalendarItem`)
| Feature | Status |
|---|---|
| Subtasks / parent-child hierarchy | **Not exposed.** `EKReminder` has no public parent or children property. `ReminderItem.parentID` exists and the UI nests subtasks when it is set, but the EventKit adapter always leaves it `nil`; today every reminder is top-level. Do not infer hierarchy from titles or notes. |
| Sections / columns, tags, smart lists, flags | Not exposed. |
| Attachments, images, scanned documents | Not exposed. |
| URL | `EKCalendarItem.url` is read when present, but links added through the Reminders app's own URL field are frequently not returned by EventKit. Only http(s) is retained. |
| Location / "early reminder" alarms | Alarms exist in EventKit but are not imported in Stage 1. |
| Recurring reminders | EventKit returns one entry per series with its **current** due date, not expanded occurrences. The app shows it once, flagged *Repeats*; future occurrences are not projected onto the calendar. |
| Floating (time-less) due dates | Treated as the whole day in the current time zone; overdue only after that day ends. |
| Shared lists / account differences | Whatever EventKit returns for the signed-in accounts; not independently verified. |
| Live behaviour | Not verified: development used mocks and synthetic fixtures only. |

## Safety properties (each is test-enforced)
- `RemindersClient` has no write members; the EventKit adapter contains no `save`, `remove`, `commit`, field assignment, or write-access request.
- Reminder code references no database, network, file, defaults, logging or AI-provider type. Content is memory-only and is discarded on exit or revocation. The production application uses live data only.
- Reminders are **markers, not events**: they never enter `UnifiedTimeline`, the scheduler, availability, or `busyIntervals`.
- Failed reads keep the last good snapshot visibly flagged out-of-date; permission loss clears it. Overlapping syncs are skipped.
- Dedup: same list + same external ID collapses to the most recently modified item; otherwise the device identifier is the key. Reminders in lists that no longer exist are dropped; items that disappear between reads are removed and counted. In-session only — Stage 1 stores no history.

## UI
- **Reminders** page: list navigation with open counts and account names, reminder list (completion indicator, due date, priority, repeat), detail pane, read-only notice. Completion circles are indicators only, not controls.
- **Academic tasks** panel: collapsible *Reminders* section with overdue and next-14-days items.
- **Day / Week / Month**: dashed teal circle chips ("Due" row in Day/Week; under events in Month). They occupy no time slot. Toggle in the sidebar (*Reminder due dates*). Clicking a chip or task opens it on the Reminders page.

## Refresh
On launch, on `EKEventStoreChanged` (coalesced to one read per second), and every 5 minutes while the app runs. The same notification also fires for Calendar changes; the extra read is cheap and harmless.

## Extension points for later stages (not implemented)
- Add a *separate* `RemindersWriting` protocol so Stage 1 code can never obtain write capability; use `externalID` + list ID as the write-back key.
- Conflict resolution and 30-day deletion history need a persisted store (Stage 1 has none); `RemindersSyncReport.removedItems` is the hook.
- Canvas duplicate linking can key on `ReminderItem.id`/`externalID`; AI estimation must keep to the local-provider boundary; per-subtask scheduling depends on Apple exposing hierarchy; Calendar publishing continues to use the existing preview-and-approve path.

## Manual verification (user-led)
1. Open the rebuilt app. Reminders must not prompt at launch.
2. Connections › Apple Reminders › *Request Reminders access…* → choose Full Access.
3. Confirm lists/counts match the Reminders app; open a reminder and compare due date, priority, notes.
4. Check the Timeline due chips (Day/Week/Month) and the panel's Reminders section; confirm they do not change free/busy time or Plan preview.
5. Complete or edit a reminder in the Reminders app; the planner updates within ~1 s–5 min, and nothing changes in the Reminders app from this app.
6. Revoke access in System Settings and confirm content disappears and the message appears.
