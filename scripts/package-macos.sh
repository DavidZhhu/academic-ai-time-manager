#!/bin/sh
set -eu

APP_PATH="${1:-build-output/AcademicTimeManager.app}"
CONTENTS_PATH="$APP_PATH/Contents"
EXECUTABLE_PATH="$CONTENTS_PATH/MacOS"
BUILD_ROOT="${ACADEMIC_SWIFT_SCRATCH_PATH:-.build}"

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
cat > "$CONTENTS_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AcademicTimeManager</string>
    <key>CFBundleIdentifier</key><string>org.example.AcademicTimeManager</string>
    <key>CFBundleName</key><string>Academic Time Manager</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Read calendar busy times to avoid conflicts and save only study sessions you approve in the dedicated Academic AI Time Manager calendar.</string>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - --identifier org.example.AcademicTimeManager "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
/usr/bin/plutil -lint "$CONTENTS_PATH/Info.plist"
printf 'Built ad-hoc-signed local app bundle: %s\n' "$APP_PATH"
