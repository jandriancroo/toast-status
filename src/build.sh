#!/bin/bash
# Builds "Toast Status.app" from main.swift in this folder. Usage: build.sh "<output .app path>"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build.sh <output.app>}"
VERSION="$(cat "$HERE/VERSION")"
SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc)"
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
"$SWIFTC" -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macos13.0" -O -o "$OUT/Contents/MacOS/ToastStatus" "$HERE/main.swift" \
  -framework Cocoa -framework SwiftUI -framework Security -framework UserNotifications
cat > "$OUT/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Toast Status</string>
  <key>CFBundleIdentifier</key><string>com.croo.toast-status</string>
  <key>CFBundleExecutable</key><string>ToastStatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
PL
codesign --force -s - "$OUT" >/dev/null 2>&1 || true
