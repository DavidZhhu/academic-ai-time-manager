# Microsoft Outlook setup and operating boundaries

## Registration requiring the user's involvement

No real Microsoft authentication was initiated during development. Configure an app registration before clicking **Add Microsoft account**:

1. In Microsoft Entra **App registrations**, register an application with **Accounts in any organizational directory and personal Microsoft accounts**. Oxford may restrict registration or require administrator approval for third-party apps. Follow that policy; do not try alternate tenants to evade it.
2. Add the **Mobile and desktop applications** platform with this exact custom redirect URI:
   `msauth.org.example.AcademicTimeManager://auth`
   The local app bundle registers the same URL scheme. This is a public desktop client using authorization code + PKCE, not a confidential web application. Do not create or enter a client secret. Do not enable implicit access/ID-token grants.
3. Configure delegated Microsoft Graph permissions **User.Read** and **Mail.Read**. The authorization request also requests **offline_access** to obtain a refresh token. No Mail.ReadWrite, Mail.Send, application permissions, or calendar write permissions are used. Obtain Oxford administrator consent if required.
4. Copy the non-secret **Application (client) ID** into Connections → Microsoft Outlook accounts and save Microsoft settings.
5. Click **Add Microsoft account** to sign in to Oxford through Microsoft's browser flow, then repeat for personal Outlook/Hotmail. Choose the intended account each time. Each account has its own Keychain credential, identity check, Inbox cursor, and last-success time.
6. Choose **Test connection**, then **Synchronise now** on each account. Inspect Review Inbox before enabling periodic polling. No Microsoft password or token should be pasted into the application or Codex.

Microsoft documentation supports custom redirects for mobile/desktop registrations; the exact registration and callback still require a user-led smoke test on the actual tenant and signed bundle: [Redirect URI setup](https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-redirect-uri), [authorization code and PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow).

## Sync and privacy

- Initial sync reads the last 30 days of **Inbox** only. Sent items, archives, junk, shared mailboxes, and other folders are not scanned. Each account uses `/me/mailFolders/inbox/messages/delta` with a received-date filter, follows the returned links, and persists the final cursor only with the whole successful batch. Folder delta is supported for personal and work/school delegated accounts: [message delta](https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0).
- Immutable message IDs are requested on every Graph call; account identity is part of every local message/source key. A deleted or moved email withdraws its review proposals but never deletes an approved protected commitment. An expired cursor triggers a fresh last-30-days scan, preserving previously reviewed events. [Immutable Outlook IDs](https://learn.microsoft.com/en-us/graph/outlook-immutable-id).
- Sync stops without committing if a batch reaches 5,000 distinct changes, 200 pages, or 30 MB of delta responses. High-volume Inboxes need a future paging/window strategy.
- Polling is off by default. Enable it in shared settings and choose 5–1440 minutes. It runs while the application is open. It cannot wake a sleeping/closed Mac. A trigger type leaves room for later change notifications; no webhook server/subscription has been deployed.
- Read operations use GET against Graph, with origin/path validation, redirect blocking, bounded responses, retries, refresh-on-401, and throttling delays. Only Microsoft's token endpoint receives OAuth POST requests. Mailbox bodies, flags, attachments, and submissions are never modified.
- Access/refresh credentials live only in macOS login Keychain using the existing ACL model. Account metadata, sync cursors (not bearer credentials), revision hashes, review excerpts, source links, local decisions, and approved events are saved in SQLite. Full email bodies and attachment files are not saved. SQLite data is not encrypted by the app; it inherits the existing local storage boundary.
- Disconnect removes that account's Keychain credential and disables polling. It preserves cached academic data and local progress. Revoke Microsoft consent separately if desired. Adding the same account again reconnects its existing identity.

## Analysis, attachments, and review

Both accounts use the same configurable keywords, sender allowlist, attachment setting, and timezone (Europe/London default). Changing classification settings resets cursors for a last-30-days re-evaluation. The included provider is a working local deterministic extractor behind `EmailAnalysisProvider`; it is not a general language model. No cloud AI provider is enabled, and an off-device provider is rejected by the sync boundary.

Explicit ISO timestamps and common UK numeric/month-name dates with times can become proposed dates. Relative dates, missing times, and other ambiguous language remain undated for review. Default meeting/tutorial duration is 60 minutes, editable in Review Inbox. Extraction is conservative and will miss some prose, recurrence, date ranges, and quoted-thread relationships; confidence does not certify correctness.

Relevant emails may have up to three supported attachments analyzed automatically. PDF text uses PDFKit, without rendering or invoking actions; image-only/encrypted PDFs are unsupported. DOCX uses a bounded in-memory ZIP/UTF-8 XML parser, without executing Word, scripts, macros, or external entities. Legacy `.doc`, `.docm`, inline files, attached emails, cloud/reference attachments, embedded binaries, and external DOCX relationships are skipped. Limits: 5 MB/file, 20 MB attachment downloads/sync, 50 PDF pages, 50,000 extracted characters, 200 DOCX entries, 20 MB archive expansion, and a 100:1 entry expansion ratio. PDF extraction checks a three-second budget between pages; it cannot preempt a single PDFKit call. Skipped attachments are reported. [Graph attachment access](https://learn.microsoft.com/en-us/graph/api/attachment-get?view=graph-rest-1.0).

Review Inbox supports selecting and approving/rejecting multiple proposals in one SQLite transaction. Undated proposals need a date first. Each card retains account, message reference, attachment provenance, evidence, and confidence. Approved dated events enter the **local** Timeline and real planning constraints. Exact title/type/time/duration duplicates merge source references; differing dates or overlaps are flagged for inspection. Duplicate matching is deterministic, not semantic equivalence.

Cancellation/rescheduling proposals are **advisory**: approving records that they were reviewed and does not alter existing commitments. Choosing a target event and applying a cancellation/reschedule is not implemented. No unapproved email event enters planning and nothing is published to Apple Calendar.

## Manual smoke test

After reviewing the implementation, quit the old app and open `build-output/AcademicTimeManager.app`. Complete registration above, connect each account, and verify the displayed identities. Sync separately; compare last-success times and account labels in Review Inbox. Reject an irrelevant proposal, edit an uncertain date, and approve a small batch. Confirm local Timeline changes, then sync again to check duplicate prevention. Restart to check persistence. Enable polling only when satisfied. Disconnect one account and verify the other stays connected. No live smoke test was performed during development.
