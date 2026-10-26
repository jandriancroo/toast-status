# Toast Status v3 (Coop's Pizza · Hayward)
1. Unzip, then double-click `Install Toast Status.command` (right-click > Open the first time).
2. Pick 1 on the Mac mini, 2 on a remote Mac (Mac Studio). Paste that Mac's token when asked (mini token on the mini, studio token on the Studio). It is stored only in the login Keychain.
3. Click "● Toast" in the menu bar. Dot / timer: yellow at 10 min, red at 15 min, gray outside 7 AM–9 PM PT. A notification fires when the sync is > 15 min stale in store hours.
- Mini mode: reads ~/Toast-runner/logs/runner.out.log; Restart = launchctl kickstart of com.croo.toast-runner; polls CrooHQ every 30s for remote restart requests and acknowledges them. (The mini token can only see restart requests, so labor % appears on remote Macs only.)
- Remote mode: reads CrooHQ toast-status; Restart sends a request the mini executes within ~30s (max 1 per 5 min).
- Self-update: checks GitHub releases (jandriancroo/toast-status, latest) every 6h and when opened, verifies sha256, rebuilds, swaps ~/Applications/Toast Status.app, relaunches.
Remove: `Uninstall Toast Status.command` (also deletes the Keychain token). The runner is never modified.

## v3.2.0
- Sync log rows now show net sales and the change since the previous sync: `10:11 AM  $784.69  +$42.10  +5m16s`. A flat `±$0.00` during store hours is yellow (data stopped moving). History moved to a new key (`syncHistoryV2`); older time-only rows show `—` for sales.
- Mini mode shows **Signed out** (red, "Run Sign In Once.command") when the newest runner log line is SESSION_EXPIRED / "Sign in by hand" / ❌ with no sales line after it; those writes no longer count as a sync. Remote mode shows Signed out when runner.message contains SESSION_EXPIRED.
