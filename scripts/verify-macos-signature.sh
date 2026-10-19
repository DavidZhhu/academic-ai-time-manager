#!/bin/sh
set -eu

APP_PATH="${1:-build-output/AcademicTimeManager.app}"
EXPECTED_IDENTIFIER="${2:-org.example.AcademicTimeManager}"
EXPECTED_MODE="${3:-stable}"
INFO_PATH="$APP_PATH/Contents/Info.plist"

if [ ! -d "$APP_PATH" ] || [ ! -f "$INFO_PATH" ]; then
    printf 'Application bundle is incomplete: %s\n' "$APP_PATH" >&2
    exit 1
fi

/usr/bin/plutil -lint "$INFO_PATH"
ACTUAL_BUNDLE_IDENTIFIER=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INFO_PATH")
if [ "$ACTUAL_BUNDLE_IDENTIFIER" != "$EXPECTED_IDENTIFIER" ]; then
    printf 'Bundle identifier mismatch: expected %s, found %s\n' "$EXPECTED_IDENTIFIER" "$ACTUAL_BUNDLE_IDENTIFIER" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"
SIGNATURE_INFO=$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)
SIGNING_IDENTIFIER=$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)
TEAM_IDENTIFIER=$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)
FLAGS=$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p' | /usr/bin/head -n 1)

if [ "$SIGNING_IDENTIFIER" != "$EXPECTED_IDENTIFIER" ]; then
    printf 'Code-signing identifier mismatch: expected %s, found %s\n' "$EXPECTED_IDENTIFIER" "$SIGNING_IDENTIFIER" >&2
    exit 1
fi

case "$EXPECTED_MODE" in
stable)
    if [ -z "$TEAM_IDENTIFIER" ] || [ "$TEAM_IDENTIFIER" = "not set" ]; then
        printf 'Stable signing verification failed: TeamIdentifier is missing.\n' >&2
        exit 1
    fi
    case "$FLAGS" in
        *adhoc*) printf 'Stable signing verification failed: signature is ad hoc.\n' >&2; exit 1 ;;
    esac
    /usr/bin/codesign --verify --strict --verbose=4 \
        -R="identifier \"$EXPECTED_IDENTIFIER\" and anchor apple generic" "$APP_PATH"
    DESIGNATED_REQUIREMENT=$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)
    case "$DESIGNATED_REQUIREMENT" in
        *"designated => cdhash"*)
            printf 'Stable signing verification failed: designated requirement is tied to this build hash.\n' >&2
            exit 1
            ;;
    esac
    printf 'Stable signature verified: identifier=%s team=%s\n' "$SIGNING_IDENTIFIER" "$TEAM_IDENTIFIER"
    ;;
adhoc)
    case "$FLAGS" in
        *adhoc*) ;;
        *) printf 'Expected an ad-hoc signature but found a certificate-backed signature.\n' >&2; exit 1 ;;
    esac
    printf 'Ad-hoc signature verified for disposable build: identifier=%s\n' "$SIGNING_IDENTIFIER"
    ;;
*)
    printf 'Unknown signature verification mode: %s\n' "$EXPECTED_MODE" >&2
    exit 1
    ;;
esac
