#!/bin/sh
set -eu

APP_PATH="${1:-build-output/AcademicTimeManager.app}"
EXPECTED_IDENTIFIER="${2:-org.example.AcademicTimeManager}"
EXPECTED_MODE="${3:-stable}"
INFO_PATH="$APP_PATH/Contents/Info.plist"
ICON_FILE_NAME="AcademicTimeManager.icns"
ICON_PATH="$APP_PATH/Contents/Resources/$ICON_FILE_NAME"

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

ACTUAL_ICON_FILE=$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$INFO_PATH")
if [ "$ACTUAL_ICON_FILE" != "$ICON_FILE_NAME" ]; then
    printf 'Bundle icon mismatch: expected %s, found %s\n' "$ICON_FILE_NAME" "$ACTUAL_ICON_FILE" >&2
    exit 1
fi
if [ ! -f "$ICON_PATH" ]; then
    printf 'Bundled application icon is missing: %s\n' "$ICON_PATH" >&2
    exit 1
fi

ICON_TEMPORARY_PATH=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/AcademicTimeManager-verify-icon.XXXXXX")
ICONSET_PATH="$ICON_TEMPORARY_PATH/AcademicTimeManager.iconset"
trap 'rm -rf "$ICON_TEMPORARY_PATH"' EXIT HUP INT TERM
/usr/bin/iconutil -c iconset "$ICON_PATH" -o "$ICONSET_PATH"
for ICON_SIZE in 16 32 128 256 512; do
    ICON_DIMENSIONS=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}.png")
    if ! printf '%s\n' "$ICON_DIMENSIONS" | /usr/bin/grep -q "pixelWidth: $ICON_SIZE$" || ! printf '%s\n' "$ICON_DIMENSIONS" | /usr/bin/grep -q "pixelHeight: $ICON_SIZE$"; then
        printf 'Invalid %sx%s application icon representation.\n' "$ICON_SIZE" "$ICON_SIZE" >&2
        exit 1
    fi
    DOUBLE_SIZE=$((ICON_SIZE * 2))
    DOUBLE_DIMENSIONS=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png")
    if ! printf '%s\n' "$DOUBLE_DIMENSIONS" | /usr/bin/grep -q "pixelWidth: $DOUBLE_SIZE$" || ! printf '%s\n' "$DOUBLE_DIMENSIONS" | /usr/bin/grep -q "pixelHeight: $DOUBLE_SIZE$"; then
        printf 'Invalid %sx%s@2x application icon representation.\n' "$ICON_SIZE" "$ICON_SIZE" >&2
        exit 1
    fi
done

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
