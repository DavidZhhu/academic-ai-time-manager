# ADR-000: Native Swift and SwiftUI

- Status: Decided for implementation; user authorized autonomous continuation on 2026-10-19.
- Context: A single-user, macOS-only local-first academic planner needs a native desktop shell, local persistence, calendar permissions, secure credential storage, OAuth, and testable domain logic.
- Decision: Use Swift 6, SwiftUI, Foundation networking, SQLite through the system library, XCTest, and native macOS frameworks. Keep integrations behind protocols and inactive until their consent and scope behavior is implemented.

## Weighted evaluation

Weights: macOS integration 25%, security/privacy 20%, maintainability 20%, AI/document processing 15%, testability/packaging 10%, complexity/Codex productivity 10%. Scores are 1–5; weighted result is out of 5.

| Criterion | Weight | Swift / SwiftUI | Python / PySide6 | Tauri / React / Rust |
|---|---:|---:|---:|---:|
| macOS integration | 25% | 5 | 3 | 3 |
| Security and privacy ergonomics | 20% | 5 | 3 | 4 |
| Maintainability and modularity | 20% | 4 | 4 | 4 |
| AI and document ecosystem | 15% | 3 | 5 | 4 |
| Testability and packaging | 10% | 4 | 3 | 4 |
| Complexity and productivity | 10% | 4 | 3 | 2 |
| **Weighted score** | **100%** | **4.30** | **3.55** | **3.55** |

## Evidence and reasoning

- SwiftUI, EventKit, Security/Keychain, and XCTest are part of Apple's supported native development surface. EventKit access is user-authorized, and sandboxed macOS apps need the calendar entitlement. Full calendar access is required to read availability; write-only access cannot read created events. This is a material permission decision for the future adapter.
- Microsoft supports authorization code with PKCE for desktop/mobile public clients. A supported MSAL implementation should be preferred over hand-built protocol code. Consent and tenant policy remain deployment dependencies.
- Canvas documents OAuth 2.0 API access and scoped developer keys, but the user's institution determines which auth method, scopes, and endpoints are enabled. No account was accessed to verify institutional settings.
- Python offers a strong AI and document-processing ecosystem, but distribution and direct macOS privacy/permission integration require more native bridging and packaging work. PySide6 also adds a separately packaged runtime.
- Tauri has a credible system webview and Rust backend, but introduces a JS/Rust build chain, packaging/toolchain dependencies, and native bridging for EventKit/Keychain. Node and Rust toolchains were not present at the start of this work.
- Native Swift maps the app's platform boundary directly to Apple's APIs and is the simplest packaging and permission model for this macOS-only product. AI provider calls can remain protocol-based HTTP clients; complex local model workflows are not yet an MVP requirement.

## Consequences

- Prefer native frameworks for calendar authorization, key storage, local notifications, UI, and packaging.
- Keep domain models independent of SwiftUI and persistence details. Use SQLite with versioned migrations and JSON payloads initially; migrate toward normalized tables as sync behavior requires it.
- Risks: fewer mature local AI/document libraries than Python; Swift concurrency and sandbox entitlements require careful testing; signing/notarization requires Apple Developer configuration that has not been requested or accessed.
- Fallback: isolate AI and provider adapters behind protocols; use a local Python sidecar only if a demonstrated document-processing requirement justifies the added runtime and security boundary.

## Feasibility checklist

- [x] EventKit API and sandbox permission model confirmed from Apple documentation; runtime permission request deferred to a user-facing action.
- [x] Keychain is available through Apple's Security framework; actual secret persistence not implemented in M0/M1.
- [x] Microsoft Graph desktop OAuth code flow supports PKCE; require MSAL, least-privilege delegated scopes, and explicit mailbox consent in M2.
- [x] Canvas REST API exposes courses and assignments and uses bearer OAuth tokens; institution-specific developer-key/scope availability remains unknown.
- [ ] No university account, mailbox, calendar, developer portal, or tenant configuration accessed.

## References

- Apple EventKit access and entitlement: https://developer.apple.com/documentation/EventKit/accessing-the-event-store
- Apple Keychain Services: https://developer.apple.com/documentation/security/keychain_services
- Microsoft authorization code with PKCE: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow
- Canvas API: https://www.instructure.com/canvas/resources/guides/canvas-lms-api-guide
