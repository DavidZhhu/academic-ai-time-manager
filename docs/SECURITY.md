# Security, Privacy, and Trust Boundaries

## Authentication
- Canvas: token or institution-approved OAuth; prefer least-privilege mechanism available; store secrets in Keychain.
- Microsoft: OAuth 2.0 authorization code with PKCE for a public desktop client; request the minimum Graph permissions actually required. Tenant consent may still be required.
- Apple Calendar: explicit EventKit authorization; use a dedicated calendar for AI-managed study blocks.

## Data processing
- Local-first persistence; encrypt sensitive data where practical and rely on macOS platform protections.
- Cloud AI may receive **relevant** academic excerpts, including approved email/document content, only with visible disclosure and provider configuration.
- Never upload unrelated personal emails, credentials, OAuth tokens, or unnecessary identifiers.
- Offer configurable retention, local deletion, provider disabling, and connection revocation.
- Log IDs/status/errors, not raw message bodies or attachments.

## Threat controls
- Treat emails, PDFs, HTML, and Canvas pages as untrusted; never execute their embedded instructions or let them override system policy.
- Validate model output against strict schemas and deterministic rules.
- Rate-limit/retry APIs, handle revoked permissions, and protect tokens from debug logs.
- Confirm protected event/deadline modifications and provide preview/undo for study-block changes.
- Test malicious prompt-injection examples, misleading dates, conflicting sources, and duplicated calendar writes.

## Consent and compliance
Verify university policies, applicable data handling rules, and API terms before connecting real student data. Record the actual scopes and disclosures during implementation.


## Implemented safeguards and gaps

- The Canvas importer requires an HTTPS base URL, blocks HTTP redirects, and validates pagination links against the configured origin before attaching bearer authorization. It performs read-only GET calls and applies bounded retries to 429/5xx responses.
- Canvas connection UI accepts a token through SwiftUI `SecureField`. The local ad-hoc-signed bundle stores it as a generic password item in the user's login Keychain with the file-based Keychain ACL model. It does not set `kSecUseDataProtectionKeychain` or `kSecAttrAccessible`: Apple derives Data Protection Keychain access groups from signing entitlements, which this local ad-hoc-signed distribution does not have. The app database has no token field or credential persistence path. API validation is an explicit read-only `GET /api/v1/users/self` to the fixed Oxford HTTPS origin; it uses the Bearer header, discards the response body, and reports status-specific errors without response bodies or token text. Token removal deletes this app's Keychain item but does not revoke it at Canvas.
- The package script ad-hoc signs the bundle with an explicit identifier matching `CFBundleIdentifier`; this provides a consistent local code identity for Keychain ACL prompts but does not add entitlements or a Developer ID signature. macOS login Keychain ACL authorization remains enabled. Keychain errors retain the OSStatus internally and present specific guidance for missing entitlements, denied interaction, and generic failures.
- Connection and importer tests use dummy fixture tokens and a mocked transport; they do not use network access or write to the real Keychain. Credentials are not included in logs or errors. A user-initiated network request is only made after pressing a connection-test button.
- Analysis output is validated for assignment identity, confidence range, unique task IDs, bounded effort estimates, non-empty evidence, and source-record identity. There is no live AI provider.
- The scheduler emits proposals only. Apple Calendar writes use a separate, exact-preview approval service and the dedicated-calendar ownership checks described in [APPLE_CALENDAR.md](APPLE_CALENDAR.md). Permission alone never authorizes publishing. Personal busy-event details are never sent to AI or persisted; owned snapshots and write intents use a mode-0600 local journal. Tests inject a fake client and never construct the native EventKit store.
- Apple Calendar Timeline display is transient and starts only after the user refreshes a full-access connection. External busy events are shown as protected **Apple Calendar** entries with their original title held only in the local in-memory projection. A process-local hash supports exact duplicate suppression; neither it nor the title is persisted. Notes, locations, attendees, URLs, calendar names and account identifiers are not displayed or stored. The Timeline projection is never submitted to an AI provider. Only journal-owned sessions can be modified.
- SQLite does not currently encrypt application data itself. Use only synthetic data until retention, deletion, and storage protections have been reviewed.


## Microsoft Outlook safeguards (2026-10-19)

- No real Microsoft login, Keychain access, mailbox read, send, or modification was performed during implementation. Tests inject fake credentials, mocked HTTP responses, temporary SQLite files, and synthetic PDF/DOCX documents.
- The public-client OAuth flow uses S256 PKCE, random state, strict callback validation, exact Microsoft login endpoints, and User.Read/Mail.Read/offline_access scopes. The registered custom scheme is present in the packaged app's Info.plist. Token JSON goes only to per-account macOS login Keychain items; raw responses/errors and credentials are never logged or included in SQLite.
- Graph traffic is GET-only, bound to HTTPS graph.microsoft.com and the expected `/me` collection. Redirects, cookies, and caches are disabled. Responses, pages, message counts, retries, and attachment expansion are bounded. Profile identity is verified before an Inbox cursor is used. Sync failures do not advance checkpoints; deleted emails do not delete approved commitments.
- PDFKit is used for text extraction only; no document actions are invoked. DOCX decompression and XML parsing occur in memory, with CRC checking, no filesystem extraction, no external entities, and macro/embedding/external-relationship rejection. Unsupported/encrypted/scanned documents may be skipped with a notice. PDFKit page parsing cannot be preempted mid-call; this remains a hardening limitation.
- Shared sender/keyword rules filter relevance before attachment retrieval. Review excerpts and provenance are persisted locally; full email bodies and original attachment files are not. Cloud transmission is blocked by the analysis boundary. Sync cursors are opaque synchronization state, not bearer credentials, and are not logged.
- Multi-selection approval/rejection is a local transaction with an audit entry per decision. No unapproved proposal reaches the Timeline or scheduler. Cancellation/rescheduling requires human follow-up and never silently changes a protected event. Disconnect removes only the selected account's credential and preserves imported data and local completion choices.
