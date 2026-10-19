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
- The scheduler emits proposals only; there is no EventKit write implementation.
- SQLite does not currently encrypt application data itself. Use only synthetic data until retention, deletion, and storage protections have been reviewed.
