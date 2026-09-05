#!/bin/bash
# Builds Presence.app from the SwiftPM executable.
#
# SwiftPM only produces a bare binary, which macOS won't treat as an app: it
# can't be launched from Finder, has no identity of its own, and dies with the
# terminal that started it. This wraps it in the minimum viable bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-/Applications/Presence.app}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Presence "$APP/Contents/MacOS/Presence"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Presence</string>
    <key>CFBundleDisplayName</key>
    <string>Presence</string>
    <key>CFBundleIdentifier</key>
    <string>my.dann.presence</string>
    <key>CFBundleExecutable</key>
    <string>Presence</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menubar-only: no dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not notarised — it's a local build — but signing keeps
# macOS from re-prompting for network access on every rebuild.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
