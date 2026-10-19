# Development signing and macOS privacy identity

## Why signing stability matters

macOS records a code requirement when an application receives access to privacy-protected resources such as Calendar. The previous packaging script used ad-hoc signing. Its designated requirement was only the executable's `cdhash`, which changes whenever the executable changes. A rebuilt app could therefore look like different code to TCC even though `CFBundleIdentifier` stayed `org.example.AcademicTimeManager`.

Local packaging now uses an Apple Development certificate by default. For repeated builds with the same certificate, the designated requirement retains the bundle identifier and certificate identity while the executable hash can change. This is the supported local-development workflow for preserving Calendar authorization across ordinary rebuilds.

## Current identity and configuration

- Bundle identifier: `org.example.AcademicTimeManager`.
- Microsoft callback scheme: `msauth.org.example.AcademicTimeManager`.
- The repository does not store a certificate, private key, certificate name, fingerprint, password, token, or Team ID.
- `scripts/package-macos.sh` asks the macOS Keychain for valid code-signing identities. It automatically uses the identity only when exactly one `Apple Development` identity exists.
- The package remains unsandboxed and has no embedded entitlements. Canvas and Microsoft credentials continue to use their existing login Keychain service/account records.

One valid Apple Development identity was available during the 2026-10-19 investigation. Only its public certificate metadata was inspected; no private key was exported or displayed. The certificate chain validated to Apple's root and the certificate expires in October 2027.

## Build and verify

```sh
./scripts/package-macos.sh
./scripts/verify-macos-signature.sh build-output/AcademicTimeManager.app org.example.AcademicTimeManager stable
```

The verifier checks:

1. The Info.plist parses and contains the expected bundle identifier.
2. `codesign --verify --deep --strict` succeeds.
3. The CodeDirectory identifier matches the bundle identifier.
4. A TeamIdentifier exists and the signature is not ad hoc.
5. The application satisfies an Apple-anchored code requirement.
6. The designated requirement is not tied only to a build `cdhash`.

If more than one Apple Development identity exists, select one explicitly for a build:

```sh
ACADEMIC_CODE_SIGN_IDENTITY="certificate SHA-1 or exact identity name" ./scripts/package-macos.sh
```

Keep using the same identity for this local installation. The value belongs in the shell environment or a local developer configuration outside Git; do not commit it. The build fails instead of silently falling back to ad-hoc signing when a stable identity is missing or ambiguous.

For an intentionally disposable bundle only:

```sh
ACADEMIC_ADHOC_SIGNING=1 ./scripts/package-macos.sh
```

An ad-hoc build can trigger a new Calendar permission request after every executable change. Do not use it for the installed development copy whose TCC and Keychain continuity matters.

## Permission and Keychain transition

Moving once from the old ad-hoc identity to the Apple Development identity changes the application's designated requirement. macOS may therefore request Calendar authorization once for the new identity. This workflow does not reset or edit the TCC database. Subsequent rebuilds with the same certificate should retain authorization.

The same identity transition may cause macOS login Keychain to ask once whether the newly signed app may access an existing Canvas or Microsoft item. The application keeps the existing bundle identifier, Keychain service/account names, storage API, and access controls; it neither deletes nor migrates credentials. Approve access only when launching the expected locally built application.

A renewed or replaced Apple Development certificate can also create a new designated requirement and prompt once again. Before renewal, create the new certificate through Xcode, select the intended identity explicitly, package and verify the app, then perform the user-led permission check. Do not reset privacy permissions or delete Keychain items.

## Getting or renewing an Apple Development identity

Use Xcode's **Settings → Accounts**, sign in with the intended Apple ID, select the team, and use **Manage Certificates** to create or renew an Apple Development certificate. This is an interactive user action because it associates a local private key with an Apple account. The packaging script never creates, exports, uploads, or prints private keys.

If no valid identity is listed by `security find-identity -v -p codesigning`, stop there and complete the Xcode account/certificate step. Do not weaken Keychain or TCC protections to bypass signing.

## Distribution boundary

Apple Development signing supports local development. Gatekeeper assessment for an independently distributed application still requires the appropriate Developer ID Application certificate and notarization. Those require Apple Developer program configuration and interactive account work. This repository does not request, purchase, or configure them.
