#!/bin/sh
set -eu

APP_PATH="${1:-build-output/AcademicTimeManager.app}"
CONTENTS_PATH="$APP_PATH/Contents"
EXECUTABLE_PATH="$CONTENTS_PATH/MacOS"
BUILD_ROOT="${ACADEMIC_SWIFT_SCRATCH_PATH:-.build}"
BUNDLE_IDENTIFIER="org.example.AcademicTimeManager"
ICON_SOURCE_PATH="Sources/AcademicTimeManager/Resources/AcademicTimeManagerIcon.png"
ICON_FILE_NAME="AcademicTimeManager.icns"

create_app_icon() {
    if [ ! -f "$ICON_SOURCE_PATH" ]; then
        printf 'Application icon source is missing: %s\n' "$ICON_SOURCE_PATH" >&2
        exit 1
    fi

    ICON_WIDTH=$(/usr/bin/sips -g pixelWidth "$ICON_SOURCE_PATH" | /usr/bin/awk '/pixelWidth:/{print $2}')
    ICON_HEIGHT=$(/usr/bin/sips -g pixelHeight "$ICON_SOURCE_PATH" | /usr/bin/awk '/pixelHeight:/{print $2}')
    if [ -z "$ICON_WIDTH" ] || [ -z "$ICON_HEIGHT" ] || [ "$ICON_WIDTH" -ne "$ICON_HEIGHT" ]; then
        printf 'Application icon source must be square; refusing to stretch or crop it.\n' >&2
        exit 1
    fi

    ICON_TEMPORARY_PATH=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/AcademicTimeManager-icon.XXXXXX")
    ICONSET_PATH="$ICON_TEMPORARY_PATH/AcademicTimeManager.iconset"
    mkdir "$ICONSET_PATH"
    trap 'rm -rf "$ICON_TEMPORARY_PATH"' EXIT HUP INT TERM
    for ICON_SIZE in 16 32 128 256 512; do
        /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE_PATH" --out "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
        DOUBLE_SIZE=$((ICON_SIZE * 2))
        /usr/bin/sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_SOURCE_PATH" --out "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
    done

    mkdir -p "$CONTENTS_PATH/Resources"
    /usr/bin/iconutil -c icns "$ICONSET_PATH" -o "$CONTENTS_PATH/Resources/$ICON_FILE_NAME"
}

select_signing_identity() {
    if [ "${ACADEMIC_ADHOC_SIGNING:-0}" = "1" ]; then
        if [ -n "${ACADEMIC_CODE_SIGN_IDENTITY:-}" ]; then
            printf 'Set either ACADEMIC_ADHOC_SIGNING or ACADEMIC_CODE_SIGN_IDENTITY, not both.\n' >&2
            exit 1
        fi
        printf '%s\n' "-"
        return
    fi
    if [ -n "${ACADEMIC_CODE_SIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$ACADEMIC_CODE_SIGN_IDENTITY"
        return
    fi

    IDENTITIES=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)
    APPLE_DEVELOPMENT_COUNT=$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk '/"Apple Development:/{count++} END {print count + 0}')
    if [ "$APPLE_DEVELOPMENT_COUNT" -eq 1 ]; then
        printf '%s\n' "$IDENTITIES" | /usr/bin/awk '/"Apple Development:/{print $2; exit}'
        return
    fi
    if [ "$APPLE_DEVELOPMENT_COUNT" -eq 0 ]; then
        printf 'No Apple Development signing identity is available. Configure one in Xcode, or set ACADEMIC_ADHOC_SIGNING=1 only for a disposable build that will not preserve macOS privacy grants.\n' >&2
    else
        printf 'Multiple Apple Development signing identities are available. Set ACADEMIC_CODE_SIGN_IDENTITY to the intended certificate name or SHA-1 hash.\n' >&2
    fi
    exit 1
}

if [ -n "${ACADEMIC_SWIFT_CACHE_PATH:-}" ] && [ -n "${ACADEMIC_SWIFT_SCRATCH_PATH:-}" ]; then
    CLANG_MODULE_CACHE_PATH="${ACADEMIC_CLANG_CACHE_PATH:-/private/tmp/academic-time-manager-clang-cache}" \
        swift build -c release --cache-path "$ACADEMIC_SWIFT_CACHE_PATH" --scratch-path "$ACADEMIC_SWIFT_SCRATCH_PATH" --manifest-cache local
else
    swift build -c release
fi
if [ -x "$BUILD_ROOT/out/Products/Release/AcademicTimeManager" ]; then
    PRODUCT_PATH="$BUILD_ROOT/out/Products/Release/AcademicTimeManager"
elif [ -x "$BUILD_ROOT/arm64-apple-macosx/release/AcademicTimeManager" ]; then
    PRODUCT_PATH="$BUILD_ROOT/arm64-apple-macosx/release/AcademicTimeManager"
elif [ -x "$BUILD_ROOT/release/AcademicTimeManager" ]; then
    PRODUCT_PATH="$BUILD_ROOT/release/AcademicTimeManager"
else
    printf 'Could not find the release executable under %s\n' "$BUILD_ROOT" >&2
    exit 1
fi
mkdir -p "$EXECUTABLE_PATH"
cp "$PRODUCT_PATH" "$EXECUTABLE_PATH/AcademicTimeManager"
create_app_icon
cat > "$CONTENTS_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AcademicTimeManager</string>
    <key>CFBundleIdentifier</key><string>org.example.AcademicTimeManager</string>
    <key>CFBundleIconFile</key><string>AcademicTimeManager.icns</string>
    <key>CFBundleName</key><string>Academic Time Manager</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleURLTypes</key>
    <array><dict><key>CFBundleURLName</key><string>Microsoft OAuth callback</string>
    <key>CFBundleURLSchemes</key><array><string>msauth.org.example.AcademicTimeManager</string></array></dict></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Read calendar busy times to avoid conflicts and save only study sessions you approve in the dedicated Academic AI Time Manager calendar.</string>
</dict>
</plist>
PLIST
SIGNING_IDENTITY=$(select_signing_identity)
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_IDENTIFIER" --timestamp=none "$APP_PATH"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    sh scripts/verify-macos-signature.sh "$APP_PATH" "$BUNDLE_IDENTIFIER" adhoc
    printf 'Built explicitly ad-hoc-signed disposable app bundle: %s\n' "$APP_PATH"
else
    sh scripts/verify-macos-signature.sh "$APP_PATH" "$BUNDLE_IDENTIFIER" stable
    printf 'Built Apple Development-signed local app bundle: %s\n' "$APP_PATH"
fi
