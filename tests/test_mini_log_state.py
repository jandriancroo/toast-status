#!/usr/bin/env python3
"""Mirrors Toast Status 3.2.1 mini-log verdicts and closed-hours display.
Keep these patterns and rules in lockstep with src/main.swift (miniLogSignedOut,
miniLogCleanClosed, inWindowStaleSecs, closedOpensText).
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

CT = ZoneInfo("America/Chicago")
PT = ZoneInfo("America/Los_Angeles")
POLL_START_MIN = 9 * 60
POLL_END_MIN = 23 * 60

EXPIRY_PAT = r"SESSION_EXPIRED|Sign in by hand"
GOOD_PAT = r"\$[0-9][0-9,]*\.?[0-9]* \([0-9]+ checks\)|reused saved Toast sign-in|session-only — no password login"
CLOSED_PAT = r"store closed for the day|all stores closed"


def last_loc(pattern: str, text: str) -> int:
    ms = list(re.finditer(pattern, text))
    return ms[-1].start() if ms else -1


def parse_runner_start_date(raw: str) -> datetime | None:
    raw = raw.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    for fmt in ("%a %b %d %H:%M:%S %Z %Y",):
        try:
            # Python %Z often fails for PST; try dateutil-less manual
            return datetime.strptime(raw, fmt).replace(tzinfo=PT if "PST" in raw or "PDT" in raw else CT)
        except ValueError:
            pass
    # Manual: "Fri Nov 13 07:00:05 PST 2026"
    m = re.match(r"^[A-Za-z]{3} ([A-Za-z]{3}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) ([A-Z]{3,4}) (\d{4})$", raw)
    if not m:
        return None
    mon, day, hh, mm, ss, z, year = m.groups()
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    tz = PT if z in ("PST", "PDT") else CT
    return datetime(int(year), months.index(mon) + 1, int(day), int(hh), int(mm), int(ss), tzinfo=tz)


def last_start_time(text: str, before: int) -> datetime | None:
    prefix = text[: max(0, before)]
    best: tuple[int, datetime] | None = None
    pats = [
        r"==== ([A-Za-z]{3} [A-Za-z]{3} +\d{1,2} \d{2}:\d{2}:\d{2} [A-Z]{3,4} \d{4}) start ====",
        r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) launchd opened",
    ]
    for p in pats:
        for m in re.finditer(p, prefix):
            d = parse_runner_start_date(m.group(1))
            if d and (best is None or m.start() > best[0]):
                best = (m.start(), d)
    return best[1] if best else None


def mini_log_signed_out(text: str, session_saved_at: datetime | None) -> bool:
    err_at = last_loc(EXPIRY_PAT, text)
    if err_at < 0:
        return False
    good_at = last_loc(GOOD_PAT, text)
    if good_at > err_at:
        return False
    if session_saved_at is not None:
        err_start = last_start_time(text, err_at)
        if err_start is not None and session_saved_at > err_start:
            return False
    return True


def mini_log_clean_closed(text: str) -> bool:
    closed_at = last_loc(CLOSED_PAT, text)
    if closed_at < 0:
        return False
    err_at = last_loc(EXPIRY_PAT, text)
    good_at = last_loc(GOOD_PAT, text)
    return closed_at > err_at and closed_at > good_at


def in_store_window(dt: datetime) -> bool:
    local = dt.astimezone(CT)
    mins = local.hour * 60 + local.minute
    return POLL_START_MIN <= mins < POLL_END_MIN


STORE_OPEN_MIN = 11 * 60
STORE_CLOSE_MIN = 20 * 60


def in_business_hours(dt: datetime) -> bool:
    local = dt.astimezone(CT)
    mins = local.hour * 60 + local.minute
    return STORE_OPEN_MIN <= mins < STORE_CLOSE_MIN


def window_start(dt: datetime) -> datetime:
    local = dt.astimezone(CT)
    return local.replace(hour=9, minute=0, second=0, microsecond=0)


def next_open(dt: datetime) -> datetime:
    local = dt.astimezone(CT)
    today_open = local.replace(hour=11, minute=0, second=0, microsecond=0)
    if local < today_open:
        return today_open
    return (today_open + timedelta(days=1))


def closed_opens_text(dt: datetime) -> str:
    open_ = next_open(dt)
    time_s = open_.strftime("%-I:%M %p").replace("AM", "AM").replace("PM", "PM")
    # Portable hour
    hour = open_.hour % 12 or 12
    time_s = f"{hour}:{open_.strftime('%M')} {open_.strftime('%p')}"
    # Python %p may be am/pm
    time_s = time_s.replace("am", "AM").replace("pm", "PM").replace("AM", "AM")
    same = open_.astimezone(CT).date() == dt.astimezone(CT).date()
    day = "" if same else f" {open_.strftime('%a')}"
    return f"Closed · opens {time_s}{day} CT"


def in_window_stale_secs(last: datetime, now: datetime) -> int:
    if now <= last:
        return 0
    total = 0.0
    day = last.astimezone(CT).replace(hour=0, minute=0, second=0, microsecond=0)
    last_day = now.astimezone(CT).replace(hour=0, minute=0, second=0, microsecond=0)
    while day <= last_day:
        open_ = day.replace(hour=9, minute=0, second=0, microsecond=0)
        close = day.replace(hour=23, minute=0, second=0, microsecond=0)
        lo = max(last.astimezone(CT), open_)
        hi = min(now.astimezone(CT), close)
        if hi > lo:
            total += (hi - lo).total_seconds()
        day += timedelta(days=1)
    return int(total)


def status_word(signed_out: bool, now: datetime) -> str:
    if signed_out:
        return "Signed out"
    if not in_business_hours(now):
        return closed_opens_text(now)
    return "Online"


# --- samples from 2026-11-13 ---

EXPIRED_NOV12 = """
2026-11-12T15:00:05Z launchd opened Start Toast.command in Terminal
==== Thu Nov 12 07:00:08 PST 2026 start ====
Poll window (store-local): 09:00–23:00
Active Toast stores in polling window: 0d1477e5-791d-42f4-9245-ad8b2e75c41c
❌ Error: SESSION_EXPIRED saved Toast sign-in was rejected or missing · session age 34h. Sign in by hand (Sign In Once.command). Robot password login disabled (reCAPTCHA).
    at getSession (file:///Users/jordanandrian/Toast-runner/toast-live-runner.mjs:1427:17)
  code: 'SESSION_EXPIRED'
"""

AFTER_REUSE_0653 = EXPIRED_NOV12 + """
2026-11-13T14:53:21Z launchd opened Start Toast.command in Terminal
==== Fri Nov 13 06:53:21 PST 2026 start ====
Poll window (store-local): 09:00–23:00
Active Toast stores in polling window: none
🔑 reused saved Toast sign-in
🌅 re-post 0d1477e5-791d-42f4-9245-ad8b2e75c41c: 2026-11-06
🌅 2026-11-06 sales $5431.29 → 200
"""

AFTER_POLL_0700 = AFTER_REUSE_0653 + """
2026-11-13T15:00:05Z launchd opened Start Toast.command in Terminal
==== Fri Nov 13 07:00:05 PST 2026 start ====
Poll window (store-local): 09:00–23:00
Active Toast stores in polling window: 0d1477e5-791d-42f4-9245-ad8b2e75c41c
🔑 reused saved Toast sign-in
📊 2026-11-13 0d1477e5-791d-42f4-9245-ad8b2e75c41c: net $0 (0 checks) → ingested
"""

CLOSED_NOV10 = """
📊 2026-11-10 0d1477e5-791d-42f4-9245-ad8b2e75c41c: net $3535.16 (81 checks) → ingested
🧾 2026-11-10: 15 shifts → ingested
🌙 all stores closed
"""

STAMP_652 = datetime(2026, 11, 13, 14, 52, 17, 600000, tzinfo=timezone.utc)
OLD_STAMP = datetime(2026, 10, 4, 23, 1, tzinfo=PT)


def main() -> None:
    failed = 0

    def check(name, got, expected):
        nonlocal failed
        if got != expected:
            print(f"FAIL {name}: got {got!r} expected {expected!r}")
            failed += 1
        else:
            print(f"ok   {name}")

    # 1) After the Nov 12 SESSION_EXPIRED, still signed out (old stamp does not clear it)
    check("expired only", mini_log_signed_out(EXPIRED_NOV12, None), True)
    check("expired + old stamp", mini_log_signed_out(EXPIRED_NOV12, OLD_STAMP), True)

    # 2) Sign In Once stamp at 6:52 AM PT is newer than the Nov 12 7:00 AM failed start → clears immediately
    check("stamp 6:52 clears signed out", mini_log_signed_out(EXPIRED_NOV12, STAMP_652), False)

    # 3) Runner reused the session at 6:53, even without a stamp
    check("reuse 6:53 clears signed out", mini_log_signed_out(AFTER_REUSE_0653, None), False)
    check("reuse 6:53 not clean-closed", mini_log_clean_closed(AFTER_REUSE_0653), False)

    # 4) 7:00 AM poll $0 (0 checks) stays signed in
    check("poll 7:00 still in", mini_log_signed_out(AFTER_POLL_0700, STAMP_652), False)

    # 5) Closed-hours sample: clean close, no later expiry
    check("closed log signed out?", mini_log_signed_out(CLOSED_NOV10, None), False)
    check("closed log is clean closed", mini_log_clean_closed(CLOSED_NOV10), True)

    # 11:30 PM CT Nov 10 (9:30 PM PT), after the runner's 11 PM CT close → next open Wed 9:00 AM CT
    night = datetime(2026, 11, 10, 23, 30, tzinfo=CT)
    check("night status", status_word(False, night), "Closed · opens 11:00 AM Wed CT")
    check("night not signed out word", status_word(True, night), "Signed out")

    # 6:00 AM PT Nov 13 = 8:00 AM CT, before 9 AM CT open
    morning = datetime(2026, 11, 13, 6, 0, tzinfo=PT)
    check("pre-open status", status_word(False, morning), "Closed · opens 11:00 AM CT")

    # Healthy overnight overdue: last sync Tue 9:06 PM PT, now Wed 6:00 AM PT (if next day after a close)
    last = datetime(2026, 11, 10, 21, 6, tzinfo=PT)
    next_morning = datetime(2026, 11, 11, 6, 0, tzinfo=PT)
    stale = in_window_stale_secs(last, next_morning)
    check("healthy overnight in-window stale is 0", stale, 0)

    # After open + 20 min (7:20 AM PT = 9:20 AM CT) following a clean close
    after_open = datetime(2026, 11, 11, 7, 20, tzinfo=PT)
    stale2 = in_window_stale_secs(last, after_open)
    check("20 min after open, overdue is ~20 min not 10h", 19 * 60 <= stale2 <= 21 * 60, True)

    # Real expiry stays signed out overnight when it's still the newest event
    check("expiry still red at night", status_word(mini_log_signed_out(EXPIRED_NOV12, None), night), "Signed out")

    # Store hours: 11 AM–8 PM CT, not the 9 AM poll start
    ten_ct = datetime(2026, 11, 13, 10, 0, tzinfo=CT)
    check("10 AM CT still closed, opens 11", status_word(False, ten_ct), "Closed · opens 11:00 AM CT")
    check("10 AM CT not in business hours", in_business_hours(ten_ct), False)
    check("10 AM CT is in runner poll window", in_store_window(ten_ct), True)
    eleven_thirty = datetime(2026, 11, 13, 11, 30, tzinfo=CT)
    check("11:30 AM CT is open (not Closed)", status_word(False, eleven_thirty), "Online")
    after_close = datetime(2026, 11, 13, 20, 30, tzinfo=CT)  # 8:30 PM CT Friday
    check("after 8 PM CT", status_word(False, after_close), "Closed · opens 11:00 AM Sat CT")


    if failed:
        print(f"\n{failed} FAILED")
        raise SystemExit(1)
    print("\nAll tests passed")


if __name__ == "__main__":
    main()
