#!/bin/bash
# Toast Status v3 installer. Works on the Mac mini (local mode) and on remote Macs (e.g. Mac Studio).
# The status token is stored only in the login Keychain. It is never written to a plist or a file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Toast Status.app"
SUPPORT="$HOME/Library/Application Support/ToastStatus"
PLIST="$HOME/Library/LaunchAgents/com.croo.toast-status.plist"
KC_SERVICE="com.croo.toast-status"; KC_ACCOUNT="status-token"
echo "== Toast Status v3 installer =="
[ -f "$HERE/src/main.swift" ] || { echo "Missing src/main.swift next to this installer. Unzip the whole folder first."; exit 1; }
if ! xcrun --find swiftc >/dev/null 2>&1 && ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Starting the Xcode Command Line Tools install..."
  xcode-select --install || true
  echo "When that finishes, double-click this installer again."; exit 1
fi
echo
echo "Which Mac is this?"
echo "  1) This is the mini (runs the Toast runner)"
echo "  2) This is a remote Mac (e.g. Mac Studio)"
MODE=""
while [ -z "$MODE" ]; do
  read -r -p "Choose 1 or 2: " c
  case "$c" in 1) MODE=mini;; 2) MODE=remote;; *) echo "Please type 1 or 2.";; esac
done
if [ "$MODE" = mini ] && [ ! -d "$HOME/Toast-runner" ]; then
  echo "Warning: ~/Toast-runner not found on this Mac. Local mode reads that folder."
fi
echo
if security find-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" >/dev/null 2>&1; then
  read -r -p "A status token is already in the Keychain. Replace it? (y/N): " r
  case "$r" in y|Y) REPLACE=1;; *) REPLACE=0;; esac
else REPLACE=1; fi
if [ "$REPLACE" = 1 ]; then
  read -r -s -p "Paste the ${MODE/remote/studio} status token (hidden), then Return: " TOKEN; echo
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
  [ ${#TOKEN} -ge 32 ] || { echo "That doesn't look like a token (too short)."; exit 1; }
  security delete-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" >/dev/null 2>&1 || true
  # Pipe the token to `security -i` so it never shows up in the process list.
  printf 'add-generic-password -U -s %s -a %s -l "Toast Status token" -w %s\n' \
    "$KC_SERVICE" "$KC_ACCOUNT" "$TOKEN" | security -i >/dev/null
  unset TOKEN
  echo "Token saved to the login Keychain."
fi
echo "Building the app (takes ~30s)..."
pkill -f "Toast Status.app/Contents/MacOS/ToastStatus" 2>/dev/null || true
launchctl bootout "gui/$UID/com.croo.toast-status" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$SUPPORT" "$HOME/Library/LaunchAgents"
bash "$HERE/src/build.sh" "$SUPPORT/staging.app"
rm -rf "$APP"; mv "$SUPPORT/staging.app" "$APP"
# Non-secret settings only.
cat > "$SUPPORT/config.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>mode</key><string>$MODE</string></dict></plist>
PL
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.croo.toast-status</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ToastStatus</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null || open "$APP"
sleep 2
pgrep -f "Toast Status.app/Contents/MacOS/ToastStatus" >/dev/null || open "$APP"
cat <<MSG

Done ($MODE mode). Look for "● Toast" in the menu bar and click it.
If macOS asks whether "Toast Status" may use the Keychain item, click Always Allow.
Allow notifications when asked, so you get a stale-sync alert.
It starts at login and updates itself. To remove it, double-click "Uninstall Toast Status.command".
MSG
