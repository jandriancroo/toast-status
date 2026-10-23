#!/bin/bash
# Removes Toast Status (app, LaunchAgent, settings, Keychain token). Never touches the Toast runner.
PLIST="$HOME/Library/LaunchAgents/com.croo.toast-status.plist"
launchctl bootout "gui/$UID/com.croo.toast-status" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "Toast Status.app/Contents/MacOS/ToastStatus" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/Toast Status.app" "$HOME/Applications/Toast Status.app.old" "$HOME/Library/Application Support/ToastStatus"
security delete-generic-password -s com.croo.toast-status -a status-token >/dev/null 2>&1 || true
echo "Toast Status removed (token deleted from Keychain). The Toast runner was not changed."
