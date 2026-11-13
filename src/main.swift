// Toast Status v3.2 — menu bar monitor for the Coop's Hayward Toast sync runner.
// One app, two modes (set by the installer): "mini" (local, on the Mac mini) or "remote" (e.g. Mac Studio).
// The status token lives only in the login Keychain (service com.croo.toast-status).
import Cocoa
import SwiftUI
import Security
import CryptoKit
import UserNotifications

let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.2.3"
let RELEASES_API = "https://api.github.com/repos/jandriancroo/toast-status/releases/latest"
let API = "https://lmodeiyrpwvgyqcvjkjr.supabase.co/functions/v1/toast-status"
let CROOHQ_URL = "https://croohq.com"
let KC_SERVICE = "com.croo.toast-status"
let KC_ACCOUNT = "status-token"
let home = NSHomeDirectory()
let supportDir = home + "/Library/Application Support/ToastStatus"
let configPath = supportDir + "/config.plist"
let appPath = home + "/Applications/Toast Status.app"
let runnerDir = home + "/Toast-runner"
let logPath = runnerDir + "/logs/runner.out.log"
let sessionStampPath = runnerDir + "/.toast-session-saved-at"  // read-only; never write, never read the session cookies
let runNowPath = runnerDir + "/Run Now.command"
let runnerLabel = "com.croo.toast-runner"
let PT = TimeZone(identifier: "America/Los_Angeles")!
let CT = TimeZone(identifier: "America/Chicago")!  // runner poll window is defined in Wisconsin time

// MARK: helpers
@discardableResult
func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func keychainToken() -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KC_SERVICE,
        kSecAttrAccount as String: KC_ACCOUNT,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
          let s = String(data: d, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func appMode() -> String {
    let d = NSDictionary(contentsOfFile: configPath)
    return (d?["mode"] as? String) == "mini" ? "mini" : "remote"
}

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let isoPlain = ISO8601DateFormatter()
func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}
func ptTime(_ d: Date) -> String {
    let f = DateFormatter(); f.timeZone = PT; f.dateFormat = "h:mm a"; return f.string(from: d)
}
func money(_ v: Double) -> String {
    let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
}
func ago(_ secs: Int) -> String {
    let s = max(0, secs)
    if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
    return "\(s / 60)m \(String(format: "%02d", s % 60))s"
}
// Runner poll window: 9:00 AM – 11:00 PM America/Chicago (= 7 AM – 9 PM PT).
// Matches the Hayward runner's POLL_START_LOCAL / POLL_END_LOCAL. The widget only displays this; it never starts or stops the runner.
let POLL_START_MIN = 9 * 60, POLL_END_MIN = 23 * 60, GRACE_MIN = 15
func ctMinutes(_ d: Date) -> Int {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    let c = cal.dateComponents([.hour, .minute], from: d)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}
func inStoreWindow(_ d: Date = Date()) -> Bool { let m = ctMinutes(d); return m >= POLL_START_MIN && m < POLL_END_MIN }
// Today's window start (9:00 AM Chicago) as an absolute Date.
func windowStart(_ d: Date = Date()) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    return cal.date(bySettingHour: POLL_START_MIN / 60, minute: 0, second: 0, of: d) ?? d
}
// Today's window end (11:00 PM Chicago) as an absolute Date.
func windowEnd(_ d: Date = Date()) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    return cal.date(bySettingHour: POLL_END_MIN / 60, minute: 0, second: 0, of: d) ?? d
}
// First 15 min of the window (9:00–9:15 AM Chicago): no red yet while the runner starts.
func inStartGrace(_ d: Date = Date()) -> Bool { let m = ctMinutes(d); return m >= POLL_START_MIN && m < POLL_START_MIN + GRACE_MIN }
func shortTZ(_ tz: TimeZone, _ d: Date) -> String {
    let abbr = tz.abbreviation(for: d) ?? ""
    return abbr.hasPrefix("P") && abbr.hasSuffix("T") ? "PT" : (abbr.hasPrefix("C") && abbr.hasSuffix("T") ? "CT" : abbr)
}
// Next 9:00 AM Chicago, shown in this Mac's local time zone (legacy wording).
func resumesText(_ d: Date = Date()) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    var next = windowStart(d)
    if next <= d { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
    let f = DateFormatter(); f.timeZone = TimeZone.current; f.dateFormat = "h:mm a"
    return "Resumes \(f.string(from: next)) \(shortTZ(TimeZone.current, next))"
}

// Coop's Hayward public hours in America/Chicago (Sun=0 … Sat=6).
// Source: CrooHQ location_hours for 0d1477e5-791d-42f4-9245-ad8b2e75c41c
// (all 7 days open 11:00–20:00, is_closed=false, updated 2026-09-28).
// Google Maps-family listings (Facebook, Apple Maps, Yelp, popular times) agree: 11 AM–8 PM every day.
// "Closed · opens …" uses these, not the runner poll window (9 AM–11 PM CT).
struct DayHours { let openMin: Int; let closeMin: Int; let closed: Bool }
let HAYWARD_HOURS: [DayHours] = Array(repeating: DayHours(openMin: 11 * 60, closeMin: 20 * 60, closed: false), count: 7)

func sundayFirstWeekday(_ d: Date) -> Int {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    return max(0, min(6, (cal.component(.weekday, from: d) - 1)))
}
func hoursOn(_ d: Date) -> DayHours { HAYWARD_HOURS[sundayFirstWeekday(d)] }

func inBusinessHours(_ d: Date = Date()) -> Bool {
    let h = hoursOn(d)
    if h.closed { return false }
    let m = ctMinutes(d)
    if h.openMin <= h.closeMin { return m >= h.openMin && m < h.closeMin }
    return m >= h.openMin || m < h.closeMin
}

func storeOpenDate(_ day: Date, minutes: Int) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    let start = cal.startOfDay(for: day)
    return cal.date(byAdding: .minute, value: minutes, to: start) ?? start
}

func nextOpen(_ d: Date = Date()) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    for i in 0..<8 {
        let day = cal.date(byAdding: .day, value: i, to: d) ?? d
        let h = hoursOn(day)
        if h.closed { continue }
        let open = storeOpenDate(day, minutes: h.openMin)
        if open > d { return open }
    }
    return storeOpenDate(d, minutes: 11 * 60)
}
func closedOpensText(_ d: Date = Date()) -> String {
    let open = nextOpen(d)
    let timeF = DateFormatter(); timeF.timeZone = CT; timeF.dateFormat = "h:mm a"
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    var day = ""
    if !cal.isDate(open, inSameDayAs: d) {
        let dayF = DateFormatter(); dayF.timeZone = CT; dayF.dateFormat = "EEE"
        day = " \(dayF.string(from: open))"
    }
    return "Closed · opens \(timeF.string(from: open))\(day) CT"
}

// Elapsed time that falls inside 9:00 AM–11:00 PM CT, so overnight closed hours don't count as overdue.
func inWindowStaleSecs(from last: Date, to now: Date) -> Int {
    if now <= last { return 0 }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = CT
    var total: TimeInterval = 0
    var day = cal.startOfDay(for: last)
    let lastDay = cal.startOfDay(for: now)
    while day <= lastDay {
        let open = cal.date(bySettingHour: POLL_START_MIN / 60, minute: 0, second: 0, of: day) ?? day
        let close = cal.date(bySettingHour: POLL_END_MIN / 60, minute: 0, second: 0, of: day) ?? day
        let lo = max(last, open)
        let hi = min(now, close)
        if hi > lo { total += hi.timeIntervalSince(lo) }
        guard let nxt = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = nxt
    }
    return Int(total)
}

func lastLoc(_ pattern: String, in text: String) -> Int {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return -1 }
    let ns = text as NSString
    guard let mm = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return -1 }
    return mm.range.location
}

let EXPIRY_PAT = "SESSION_EXPIRED|Sign in by hand"
let GOOD_PAT = "\\$[0-9][0-9,]*\\.?[0-9]* \\([0-9]+ checks\\)|reused saved Toast sign-in|session-only — no password login"
let CLOSED_PAT = "store closed for the day|all stores closed"

func parseRunnerStartDate(_ raw: String) -> Date? {
    let iso = parseDate(raw)
    if let iso = iso { return iso }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE MMM d HH:mm:ss z yyyy"
    return f.date(from: raw)
}

// Timestamp of the "==== … start ====" or launchd line immediately before `before`.
func lastStartTime(in text: String, before: Int) -> Date? {
    let ns = text as NSString
    let prefix = ns.substring(to: max(0, min(before, ns.length)))
    var best: (Int, Date)? = nil
    let pats: [(String, Int)] = [
        ("==== ([A-Za-z]{3} [A-Za-z]{3} [0-9]{1,2} [0-9:]{8} [A-Z]{3,4} [0-9]{4}) start ====", 1),
        ("([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z) launchd opened", 1),
    ]
    for (p, g) in pats {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        for m in re.matches(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
            let r = m.range(at: g)
            if r.location == NSNotFound { continue }
            let raw = (prefix as NSString).substring(with: r)
            if let d = parseRunnerStartDate(raw) {
                if best == nil || m.range.location > best!.0 { best = (m.range.location, d) }
            }
        }
    }
    return best?.1
}

func readSessionSavedAt() -> Date? {
    guard let raw = try? String(contentsOfFile: sessionStampPath, encoding: .utf8) else { return nil }
    return parseDate(raw.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Red Signed out only when a real SESSION_EXPIRED / "Sign in by hand" is newer than the last good sales, session reuse, or session-save stamp.
func miniLogSignedOut(_ text: String, sessionSavedAt: Date?) -> Bool {
    let errAt = lastLoc(EXPIRY_PAT, in: text)
    if errAt < 0 { return false }
    let goodAt = lastLoc(GOOD_PAT, in: text)
    if goodAt > errAt { return false }
    if let saved = sessionSavedAt, let errStart = lastStartTime(in: text, before: errAt), saved > errStart { return false }
    return true
}

func miniLogCleanClosed(_ text: String) -> Bool {
    let closedAt = lastLoc(CLOSED_PAT, in: text)
    if closedAt < 0 { return false }
    let errAt = lastLoc(EXPIRY_PAT, in: text)
    let goodAt = lastLoc(GOOD_PAT, in: text)
    return closedAt > errAt && closedAt > goodAt
}
func versionIsNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
func firstMatch(_ pattern: String, _ text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
    return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
}

// MARK: model
enum UpdState: Equatable {
    case idle, checking, upToDate, available(String), updating, failed(String)
    var label: String {
        switch self {
        case .idle: return "Check for updates"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let v): return "Update to \(v)"
        case .updating: return "Updating…"
        case .failed(let e): return e
        }
    }
    var busy: Bool { self == .checking || self == .updating }
    var isAvailable: Bool { if case .available = self { return true }; return false }
    var isError: Bool { if case .failed = self { return true }; return false }
}
let HIST_KEY_OLD = "syncHistory"      // v3.0–3.1: [Double] epoch seconds only
let HIST_KEY = "syncHistoryV2"        // v3.2+: [[String: Double]] with t / sales / checks
struct SyncEntry { let at: Date; let sales: Double?; let checks: Int? }
func loadHistory() -> [SyncEntry] {
    let ud = UserDefaults.standard
    if let arr = ud.array(forKey: HIST_KEY) as? [[String: Double]] {
        return arr.compactMap { d in
            guard let t = d["t"] else { return nil }
            return SyncEntry(at: Date(timeIntervalSince1970: t), sales: d["sales"], checks: d["checks"].map { Int($0) })
        }
    }
    let old = ud.array(forKey: HIST_KEY_OLD) as? [Double] ?? []
    return old.map { SyncEntry(at: Date(timeIntervalSince1970: $0), sales: nil, checks: nil) }
}
final class Model: ObservableObject {
    @Published var mode = appMode()
    @Published var now = Date()
    @Published var lastSync: Date?
    @Published var updatedAt: Date?
    @Published var locationName = "Coop's Pizza · Hayward"
    @Published var stateText = "Checking…"
    @Published var runnerState = ""
    @Published var sales: Double?
    @Published var checks: Int?
    @Published var deltaPct: Double?
    @Published var weekdayName = ""
    @Published var laborPct: Double?
    @Published var miniOnline: Bool?
    @Published var heartbeatAt: Date?
    @Published var updState: UpdState = .idle
    @Published var runnerRunning: Bool?
    @Published var sessionHours: Double?
    @Published var restartPending = false
    @Published var selfUpdating = false
    @Published var flash: String?
    @Published var error: String?
    @Published var updateText: String?
    @Published var signedOut = false
    @Published var history: [SyncEntry] = loadHistory()

    func record(_ d: Date, sales: Double?, checks: Int?) {
        if let last = history.last, abs(last.at.timeIntervalSince(d)) < 1 { return }
        if let last = history.last, d < last.at { return }
        history.append(SyncEntry(at: d, sales: sales, checks: checks))
        if history.count > 6 { history.removeFirst(history.count - 6) }
        let enc: [[String: Double]] = history.map { e in
            var o: [String: Double] = ["t": e.at.timeIntervalSince1970]
            if let v = e.sales { o["sales"] = v }
            if let c = e.checks { o["checks"] = Double(c) }
            return o
        }
        UserDefaults.standard.set(enc, forKey: HIST_KEY)
    }

    var wallStaleSecs: Int? { lastSync.map { Int(now.timeIntervalSince($0)) } }
    // Overdue uses only time inside 9 AM–11 PM CT, so a clean overnight close doesn't look 10–57h late.
    var staleSecs: Int? { lastSync.map { inWindowStaleSecs(from: $0, to: now) } }
    var offHours: Bool { !inStoreWindow(now) }  // runner poll window 9 AM–11 PM CT
    var storeClosed: Bool { !inBusinessHours(now) }  // public hours 11 AM–8 PM CT
    // Start-of-window grace: no sync yet today and still before 9:15 AM Chicago.
    var starting: Bool { inStartGrace(now) && (lastSync.map { $0 < windowStart(now) } ?? true) }
    // Mini heartbeat missing > 15 min during the poll window (after grace). Overnight this is just idle.
    var miniAsleep: Bool {
        if offHours || starting || mode == "mini" { return false }
        guard let hb = heartbeatAt else { return true }
        return now.timeIntervalSince(hb) > 900
    }
    // Menu-bar and popover-header dots reflect runner connection/health only, never store open/closed.
    // 0 green: session valid and runner working as expected (including closed hours: idle on purpose or still polling).
    // 1 yellow/amber: overdue or stalled in the 9 AM–11 PM CT poll window, or an error.
    // 2 red: signed out / SESSION_EXPIRED only.
    var level: Int {
        if signedOut { return 2 }
        if let err = error, !err.isEmpty { return 1 }
        if offHours || starting { return 0 }
        if miniAsleep || runnerDown { return 1 }
        guard let s = staleSecs else { return 1 }
        return s >= 600 ? 1 : 0
    }
    var color: Color { [Color.green, Color.yellow, Color.red][level] }
    var nsColor: NSColor { [NSColor.systemGreen, .systemYellow, .systemRed][level] }
    var staleColor: Color {
        if offHours || starting { return .secondary }
        guard let s = staleSecs else { return .yellow }
        return s >= 600 ? .yellow : .primary
    }

    var runnerDown: Bool {
        if runnerRunning == false { return true }
        return ["stopped", "offline", "down", "error", "crashed", "dead"].contains(runnerState.lowercased())
    }
    // Mac mini card: word + glow
    var statusWord: String {
        if restartPending || selfUpdating { return "Updating" }
        if signedOut { return "Signed out" }
        if storeClosed { return closedOpensText(now) }
        if starting { return "Starting up" }
        if miniAsleep { return "Mini asleep?" }
        if runnerDown || (staleSecs ?? Int.max) >= 900 { return "Offline" }
        return "Online"
    }
    var statusSub: String? {
        if restartPending || selfUpdating { return nil }
        if signedOut { return "Run Sign In Once.command" }
        if storeClosed { return nil }
        if starting { return "Waiting for first sync" }
        if miniAsleep { return heartbeatAt.map { "No heartbeat for \(ago(Int(now.timeIntervalSince($0))))" } ?? "No heartbeat yet" }
        return nil
    }
    var glow: Color {
        if statusWord == "Updating" { return .yellow }
        return [Color.green, Color.yellow, Color.red][level]
    }
}

func gapText(_ secs: Int) -> String {
    let s = max(0, secs)
    if s >= 3600 { return "+\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
    return "+\(s / 60)m\(String(format: "%02d", s % 60))s"
}

// MARK: view
struct SyncRow { let at: Date; let sales: Double?; let delta: Double?; let gap: Int? }
func deltaText(_ d: Double) -> String {
    if abs(d) < 0.005 { return "±$0.00" }
    return (d > 0 ? "+" : "-") + money(abs(d))
}
struct SyncLog: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if m.signedOut {
                Text("Last check \(m.lastSync.map { ptTime($0) } ?? "—") · signed out")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
                Text("Run Sign In Once.command").font(.system(size: 11)).foregroundColor(.secondary)
            } else if m.offHours {
                let lastCheck = m.lastSync.map { min($0, windowEnd($0)) }
                Text("Last check \(lastCheck.map { ptTime($0) } ?? "—") · alerts paused overnight")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                if m.storeClosed { Text(closedOpensText(m.now)).font(.system(size: 11)).foregroundColor(.secondary) }
            } else if m.starting {
                Text("Starting up · last check \(m.lastSync.map { ptTime($0) } ?? "—")")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                Text("Grace until 9:15 AM CT").font(.system(size: 11)).foregroundColor(.secondary)
                if m.storeClosed { Text(closedOpensText(m.now)).font(.system(size: 11)).foregroundColor(.secondary) }
            } else if let l = m.lastSync {
                let base = l < windowStart(m.now) ? windowStart(m.now) : l
                let due = base.addingTimeInterval(300)
                let left = Int(due.timeIntervalSince(m.now))
                Text("Last check \(ptTime(l)) · next due \(ptTime(due))")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(m.staleColor)
                Text(left >= 0 ? "due in \(ago(left)) · last sync \(ago(m.wallStaleSecs ?? 0)) ago" : "overdue by \(ago(-left)) · last sync \(ago(m.wallStaleSecs ?? 0)) ago")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if m.storeClosed { Text(closedOpensText(m.now)).font(.system(size: 11)).foregroundColor(.secondary) }
            } else {
                Text("Last check — never").font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
                if m.storeClosed { Text(closedOpensText(m.now)).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            let h = m.history
            let rows: [SyncRow] = h.indices.reversed().prefix(5).map { i in
                let prev: SyncEntry? = i > 0 ? h[i - 1] : nil
                var delta: Double? = nil
                if let a = h[i].sales, let b = prev?.sales { delta = a - b }
                return SyncRow(at: h[i].at, sales: h[i].sales, delta: delta, gap: prev.map { Int(h[i].at.timeIntervalSince($0.at)) })
            }
            ForEach(rows, id: \.at) { r in
                let flat = r.delta.map { abs($0) < 0.005 } ?? false
                HStack(spacing: 10) {
                    Text(ptTime(r.at)).frame(width: 64, alignment: .leading)
                    Text(r.sales.map { money($0) } ?? "—").frame(width: 78, alignment: .trailing)
                    Text(r.delta.map { deltaText($0) } ?? "—").frame(width: 70, alignment: .trailing)
                        .foregroundColor(flat && inStoreWindow(r.at) ? .yellow : .secondary)
                    Text(r.gap.map { gapText($0) } ?? "—")
                }.font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06)).cornerRadius(8)
    }
}

struct MiniCard: View {
    @ObservedObject var m: Model
    var symbol: String { NSImage(systemSymbolName: "macmini.fill", accessibilityDescription: nil) != nil ? "macmini.fill" : "desktopcomputer" }
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.07))
                    .shadow(color: m.glow.opacity(0.75), radius: 18)
                RoundedRectangle(cornerRadius: 22).stroke(m.glow.opacity(0.6), lineWidth: 1.5)
                Image(systemName: symbol).font(.system(size: 84, weight: .regular))
                    .foregroundColor(.primary).shadow(color: m.glow.opacity(0.9), radius: 12)
            }.frame(width: 190, height: 170)
            VStack(spacing: 2) {
                Text(m.statusWord).font(.system(size: 26, weight: .bold)).foregroundColor(m.glow)
                if let sub = m.statusSub { Text(sub).font(.system(size: 12)).foregroundColor(.secondary) }
            }
        }.frame(maxWidth: .infinity)
    }
}

struct PopView: View {
    @ObservedObject var m: Model
    var restart: () -> Void
    var openHQ: () -> Void
    var runUpdate: () -> Void
    var quit: () -> Void
    var updateButton: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(m.color).frame(width: 12, height: 12)
                Text(m.locationName).font(.system(size: 18, weight: .semibold))
                Spacer()
                if let u = m.updateText {
                    Button(u, action: runUpdate).buttonStyle(PlainButtonStyle()).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.orange.opacity(0.85)).cornerRadius(6)
                }
            }.padding(.bottom, 12)
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    SyncLog(m: m)
                    Spacer(minLength: 16)
                    Text("SALES TODAY").font(.system(size: 14)).foregroundColor(.secondary)
                    Text(m.sales.map { money($0) } ?? "—").font(.system(size: 52, weight: .bold))
                        .foregroundColor(m.level == 2 ? .secondary : .primary).minimumScaleFactor(0.6).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(m.checks.map { "\($0) checks" } ?? "— checks").font(.system(size: 16))
                        if let d = m.deltaPct {
                            Text("·").foregroundColor(.secondary)
                            Text(String(format: "%@%.0f%% vs last %@", d >= 0 ? "+" : "", d, m.weekdayName))
                                .font(.system(size: 16)).foregroundColor(d >= 0 ? .green : .red)
                        }
                    }
                    if let l = m.laborPct {
                        Text(String(format: "Labor %.1f%%", l)).font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.78, blue: 1.0)).padding(.top, 6)
                    }
                    Spacer(minLength: 8)
                }.frame(width: 300)
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1)
                VStack { Spacer(minLength: 0); MiniCard(m: m); Spacer(minLength: 0) }.frame(width: 220)
            }.frame(height: 330)
            if let e = m.error { Text(e).font(.system(size: 12)).foregroundColor(.orange).padding(.top, 8) }
            if let f = m.flash { Text(f).font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 8) }
            HStack(spacing: 12) {
                Button(action: restart) {
                    VStack(spacing: 1) {
                        Text("Restart Runner").font(.system(size: 15, weight: .semibold))
                        Text(m.mode == "mini" ? "on this mini" : "sends request to mini").font(.system(size: 11)).opacity(0.8)
                    }.frame(maxWidth: .infinity, minHeight: 46)
                }.buttonStyle(PlainButtonStyle()).background(Color.white.opacity(0.14)).cornerRadius(8)
                Button(action: openHQ) {
                    Text("Open CrooHQ").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }.buttonStyle(PlainButtonStyle()).background(Color.blue).cornerRadius(8)
            }.padding(.top, 14)
            HStack {
                Text("Toast Status \(APP_VERSION) · \(m.mode == "mini" ? "mini (local)" : "remote")").font(.system(size: 11)).foregroundColor(.secondary)
                Button(m.updState.label, action: updateButton).buttonStyle(PlainButtonStyle()).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(m.updState.isError ? .orange : (m.updState.isAvailable ? .blue : .secondary))
                    .disabled(m.updState.busy)
                Spacer()
                Button("Quit", action: quit).buttonStyle(PlainButtonStyle()).font(.system(size: 11)).foregroundColor(.secondary)
            }.padding(.top, 10)
        }
        .padding(20).frame(width: 600)
    }
}

// MARK: app
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let m = Model()
    var timers: [Timer] = []
    var notifiedStale = false
    var lastUpdateCheck = Date.distantPast
    var pendingRelease: (version: String, url: URL, sha: String)?
    var updating = false
    var handlingRemoteRestart = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let v = PopView(m: m, restart: { [weak self] in self?.restartTapped() },
                        openHQ: { NSWorkspace.shared.open(URL(string: CROOHQ_URL)!) },
                        runUpdate: { [weak self] in self?.applyUpdate() },
                        quit: { NSApp.terminate(nil) },
                        updateButton: { [weak self] in self?.updateButtonTapped() })
        popover.contentViewController = NSHostingController(rootView: v)
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh(); checkForUpdate()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() })
        if m.mode == "mini" {
            timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pollRestartPending() })
            pollRestartPending()
        }
    }

    @objc func togglePopover() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        refresh(); checkForUpdate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func tick() {
        m.now = Date()
        let t = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: m.nsColor])
        t.append(NSAttributedString(string: "Toast"))
        item.button?.attributedTitle = t
        // stale notification: > 15 min during store window, once per stale episode
        if !m.signedOut, inStoreWindow(m.now), !m.starting, let s = m.staleSecs, s > 900 {
            if !notifiedStale { notifiedStale = true; notify("Toast sync is stale", "Last sync \(ago(s)) ago at \(m.locationName).") }
        } else if m.level == 0 { notifiedStale = false }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            if err != nil {
                let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
                DispatchQueue.main.async { _ = sh("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]) }
            }
        }
    }

    // MARK: networking
    func request(_ path: String, method: String = "GET", body: Data? = nil, auth: Bool = true,
                 done: @escaping (Int, Data?) -> Void) {
        guard let url = URL(string: API + path) else { done(0, nil); return }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        if auth {
            guard let tok = keychainToken() else { DispatchQueue.main.async { done(-1, nil) }; return }
            r.setValue(tok, forHTTPHeaderField: "X-Status-Token")
        }
        if let b = body { r.httpBody = b; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(code, data) }
        }.resume()
    }

    func refresh() { if m.mode == "mini" { refreshLocal() } else { refreshRemote() } }

    func refreshRemote() {
        request("") { [weak self] code, data in
            guard let self = self else { return }
            if code == -1 { self.m.error = "No status token in Keychain. Re-run the installer."; return }
            if code == 401 { self.m.error = "Token rejected (401). Ask for a new token and re-run the installer."; return }
            guard code == 200, let d = data, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                self.m.error = code == 0 ? "Can't reach CrooHQ (offline?)" : "CrooHQ error \(code)"; return
            }
            self.m.error = nil
            self.apply(j)
        }
    }

    func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func apply(_ j: [String: Any]) {
        let loc = j["location"] as? [String: Any]
        if let n = loc?["name"] as? String { m.locationName = n == "Hayward" ? "Coop's Pizza · Hayward" : n }
        let r = j["runner"] as? [String: Any] ?? [:]
        let hb = parseDate(r["heartbeat_at"] as? String)
        let pull = parseDate(r["last_sales_pull_at"] as? String)
        m.lastSync = pull ?? hb
        m.updatedAt = parseDate(j["server_time"] as? String) ?? Date()
        m.miniOnline = hb.map { Date().timeIntervalSince($0) < 600 }
        m.heartbeatAt = hb
        m.sessionHours = num(r["session_age_hours"])
        let state = (r["state"] as? String) ?? ""
        let msg = (r["message"] as? String) ?? ""
        m.signedOut = msg.contains("SESSION_EXPIRED") || msg.contains("Sign in by hand")
        m.runnerState = state
        m.runnerRunning = nil
        m.stateText = m.signedOut ? "Signed out" : (m.storeClosed || m.offHours ? closedOpensText(m.now) : ((m.staleSecs ?? Int.max) >= 900 ? "No sync" : (state.isEmpty ? "Syncing" : (state == "polling" ? "Syncing" : state.capitalized))))
        let s = j["sales"] as? [String: Any] ?? [:]
        m.sales = num(s["net_sales"])
        m.checks = num(s["check_count"]).map { Int($0) }
        m.deltaPct = num(s["delta_pct"])
        if let p = pull { m.record(p, sales: m.sales, checks: m.checks) }
        if let bd = s["business_date"] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = PT
            if let d = f.date(from: bd) { let g = DateFormatter(); g.timeZone = PT; g.dateFormat = "EEE"; m.weekdayName = g.string(from: d) }
        }
        m.laborPct = num(j["labor_pct"])
        m.restartPending = (j["restart_pending"] as? Bool) ?? false
        tick()
    }

    // Mini mode: everything comes from the local runner log (the mini token can only see restart requests).
    func refreshLocal() {
        let running = sh("/usr/bin/pgrep", ["-f", "toast-live-runner.mjs"]).0 == 0
        let mtime = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date
        m.updatedAt = Date()
        m.miniOnline = running
        m.runnerRunning = running
        var signedOut = false
        m.error = FileManager.default.fileExists(atPath: logPath) ? nil : "No runner log at ~/Toast-runner/logs"
        if let fh = FileHandle(forReadingAtPath: logPath) {
            let size = fh.seekToEndOfFile()
            fh.seek(toFileOffset: size > 32768 ? size - 32768 : 0)
            let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
            fh.closeFile()
            if let g = firstMatch("\\$([0-9][0-9,]*\\.?[0-9]*) \\(([0-9]+) checks\\)", text) {
                m.sales = Double(g[1].replacingOccurrences(of: ",", with: "")); m.checks = Int(g[2])
            }
            if let g = firstMatch("session age ([0-9.]+)h", text) { m.sessionHours = Double(g[1]) }
            // Signed out only if a real SESSION_EXPIRED / "Sign in by hand" is newer than a sales line, a reused session, or a session-save stamp.
            let savedAt = readSessionSavedAt()
            signedOut = miniLogSignedOut(text, sessionSavedAt: savedAt)
        }
        m.signedOut = signedOut
        if signedOut {
            m.lastSync = m.history.last?.at  // error writes touch the log but are not a sync
        } else {
            let candidates = [mtime, readSessionSavedAt()].compactMap { $0 }
            let t = candidates.max()
            m.lastSync = t
            if let t = t { m.record(t, sales: m.sales, checks: m.checks) }
        }
        m.stateText = signedOut ? "Signed out" : (!running && (m.storeClosed || m.offHours) ? closedOpensText(m.now) : (!running ? "Runner not running" : (m.storeClosed || m.offHours ? closedOpensText(m.now) : ((m.staleSecs ?? Int.max) >= 900 ? "No sync" : "Syncing"))))
        tick()
    }

    // MARK: restart
    func kickstartLocal() -> Bool {
        let r = sh("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(runnerLabel)"])
        if r.0 != 0 { NSWorkspace.shared.open(URL(fileURLWithPath: runNowPath)) }
        return r.0 == 0
    }

    func restartTapped() {
        if m.mode == "mini" {
            let ok = kickstartLocal()
            m.flash = ok ? "Runner restarted (launchctl kickstart)." : "kickstart failed; opened Run Now.command."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
            return
        }
        m.flash = "Sending restart request…"
        request("/restart", method: "POST", body: Data("{}".utf8)) { [weak self] code, data in
            guard let self = self else { return }
            let j = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let st = j?["status"] as? String
            switch (code, st) {
            case (200, "requested"?): self.m.flash = "Restart requested. The mini picks it up within ~30s."; self.m.restartPending = true
            case (200, "already_pending"?): self.m.flash = "A restart is already pending."; self.m.restartPending = true
            case (429, _): self.m.flash = "Restart was requested in the last 5 min; try again shortly."
            case (401, _): self.m.flash = "Token rejected (401)."
            default: self.m.flash = "Restart request failed (\(code))."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }
    }

    func pollRestartPending() {
        if handlingRemoteRestart { return }
        request("/restart-pending") { [weak self] code, data in
            guard let self = self, code == 200, let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  (j["pending"] as? Bool) == true else { return }
            self.handlingRemoteRestart = true
            self.m.restartPending = true
            let ok = self.kickstartLocal()
            var body: [String: Any] = ["note": ok ? "kickstarted" : "kickstart failed, opened Run Now"]
            if let id = j["id"] as? String { body["id"] = id }
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            self.request("/restart-ack", method: "POST", body: data) { _, _ in
                self.handlingRemoteRestart = false
                self.m.restartPending = false
                self.m.flash = "Remote restart executed at \(ptTime(Date())) PT."
                self.notify("Toast runner restarted", "A remote restart request was executed on this mini.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
            }
        }
    }

    // MARK: self-update
    // Footer button: manual check (bypasses the 60s throttle) or install a found release now.
    func updateButtonTapped() {
        switch m.updState {
        case .available: applyUpdate()
        case .checking, .updating: return
        default: checkForUpdate(manual: true)
        }
    }

    func manualResult(_ s: UpdState) {
        DispatchQueue.main.async {
            self.m.updState = s
            if s == .upToDate || s.isError {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.m.updState == s { self.m.updState = .idle } }
            }
        }
    }

    func checkForUpdate(manual: Bool = false) {
        if updating { return }
        if !manual && Date().timeIntervalSince(lastUpdateCheck) < 60 { return }
        lastUpdateCheck = Date()
        if manual { m.updState = .checking }
        let report: (UpdState) -> Void = { [weak self] s in if manual { self?.manualResult(s) } }
        var r = URLRequest(url: URL(string: RELEASES_API)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("ToastStatus/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { [weak self] data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String, tag.hasPrefix("v"),
                  let assets = j["assets"] as? [[String: Any]] else { report(.failed("Update check failed")); return }
            let v = String(tag.dropFirst())
            func url(_ name: String) -> URL? {
                guard let a = assets.first(where: { ($0["name"] as? String) == name }),
                      let s = a["browser_download_url"] as? String, let u = URL(string: s), u.scheme == "https" else { return nil }
                return u
            }
            guard versionIsNewer(v, than: APP_VERSION) else { DispatchQueue.main.async { self?.m.updateText = nil }; report(.upToDate); return }
            guard let zipURL = url("toast-status-src.zip"), let shaURL = url("toast-status-src.zip.sha256") else { report(.failed("Release \(v) missing assets")); return }
            URLSession.shared.dataTask(with: shaURL) { sdata, sresp, _ in
                guard (sresp as? HTTPURLResponse)?.statusCode == 200, let sd = sdata,
                      let txt = String(data: sd, encoding: .utf8),
                      let sha = firstMatch("^([0-9a-fA-F]{64})", txt.trimmingCharacters(in: .whitespacesAndNewlines))?[1] else { report(.failed("Bad release checksum")); return }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pendingRelease = (v, zipURL, sha.lowercased())
                    self.m.updateText = "Update available (\(v))"
                    if manual { self.m.updState = .available(v) } else { self.applyUpdate() }  // auto path unchanged
                }
            }.resume()
        }.resume()
    }

    func applyUpdate() {
        guard let rel = pendingRelease, !updating else { return }
        updating = true
        m.selfUpdating = true
        m.updateText = "Updating to \(rel.version)…"
        m.updState = .updating
        URLSession.shared.downloadTask(with: rel.url) { [weak self] tmp, resp, _ in
            guard let self = self else { return }
            func fail(_ msg: String) { DispatchQueue.main.async { self.updating = false; self.m.selfUpdating = false; self.m.updateText = "Update available (\(rel.version))"; self.m.flash = msg; self.m.updState = .failed(msg) } }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200, let data = try? Data(contentsOf: tmp) else { return fail("Update download failed.") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == rel.sha else { return fail("Update rejected: sha256 mismatch.") }
            let work = NSTemporaryDirectory() + "toast-status-update-\(UUID().uuidString)"
            let zip = work + "/release.zip"
            do {
                try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: zip))
            } catch { return fail("Update: can't write temp files.") }
            guard sh("/usr/bin/ditto", ["-x", "-k", zip, work + "/src"]).0 == 0 else { return fail("Update: unzip failed.") }
            // The release ships source + build.sh; it compiles into a staging app, then swaps it into ~/Applications.
            let build = work + "/src/build.sh"
            let staged = work + "/Toast Status.app"
            let r = sh("/bin/bash", [build, staged])
            guard r.0 == 0, FileManager.default.fileExists(atPath: staged + "/Contents/MacOS/ToastStatus") else {
                return fail("Update build failed. Run the installer again.")
            }
            let swap = """
            sleep 1
            rm -rf "\(appPath).old"
            mv "\(appPath)" "\(appPath).old" 2>/dev/null
            if mv "\(staged)" "\(appPath)"; then rm -rf "\(appPath).old"; else mv "\(appPath).old" "\(appPath)"; fi
            codesign --force -s - "\(appPath)" >/dev/null 2>&1
            open "\(appPath)"
            rm -rf "\(work)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", swap]
            do { try p.run() } catch { return fail("Update: couldn't start installer step.") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
