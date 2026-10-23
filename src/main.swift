// Toast Status v3 — menu bar monitor for the Coop's Hayward Toast sync runner.
// One app, two modes (set by the installer): "mini" (local, on the Mac mini) or "remote" (e.g. Mac Studio).
// The status token lives only in the login Keychain (service com.croo.toast-status).
import Cocoa
import SwiftUI
import Security
import CryptoKit
import UserNotifications

let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.0.0"
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
let runNowPath = runnerDir + "/Run Now.command"
let runnerLabel = "com.croo.toast-runner"
let PT = TimeZone(identifier: "America/Los_Angeles")!

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
// Store window 7 AM – 9 PM PT
func inStoreWindow(_ d: Date = Date()) -> Bool {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = PT
    let c = cal.dateComponents([.hour, .minute], from: d)
    let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return m >= 7 * 60 && m < 21 * 60
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
let HIST_KEY = "syncHistory"
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
    @Published var runnerRunning: Bool?
    @Published var sessionHours: Double?
    @Published var restartPending = false
    @Published var selfUpdating = false
    @Published var flash: String?
    @Published var error: String?
    @Published var updateText: String?
    @Published var history: [Date] = (UserDefaults.standard.array(forKey: HIST_KEY) as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }

    func record(_ d: Date) {
        if let last = history.last, abs(last.timeIntervalSince(d)) < 1 { return }
        if let last = history.last, d < last { return }
        history.append(d)
        if history.count > 6 { history.removeFirst(history.count - 6) }
        UserDefaults.standard.set(history.map { $0.timeIntervalSince1970 }, forKey: HIST_KEY)
    }

    var staleSecs: Int? { lastSync.map { Int(now.timeIntervalSince($0)) } }
    var level: Int { // menu bar dot: 0 green, 1 yellow, 2 red, 3 gray (outside store hours)
        guard let s = staleSecs else { return inStoreWindow(now) ? 2 : 3 }
        if !inStoreWindow(now) { return 3 }
        return s >= 900 ? 2 : (s >= 600 ? 1 : 0)
    }
    var color: Color { [Color.green, Color.yellow, Color.red, Color.gray][level] }
    var nsColor: NSColor { [NSColor.systemGreen, .systemYellow, .systemRed, .systemGray][level] }
    var staleColor: Color { guard let s = staleSecs else { return .red }; return s >= 900 ? .red : (s >= 600 ? .yellow : .primary) }

    var runnerDown: Bool {
        if runnerRunning == false { return true }
        return ["stopped", "offline", "down", "error", "crashed", "dead"].contains(runnerState.lowercased())
    }
    // Mac mini card: word + glow
    var statusWord: String {
        if restartPending || selfUpdating { return "Updating" }
        if runnerDown || (staleSecs ?? Int.max) >= 900 { return "Offline" }
        return "Online"
    }
    var glow: Color {
        if statusWord == "Offline" { return .red }
        if statusWord == "Updating" || (staleSecs ?? 0) >= 600 { return .yellow }
        return .green
    }
}

func gapText(_ secs: Int) -> String {
    let s = max(0, secs)
    if s >= 3600 { return "+\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
    return "+\(s / 60)m\(String(format: "%02d", s % 60))s"
}

// MARK: view
struct SyncRow { let at: Date; let gap: Int? }
struct SyncLog: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let l = m.lastSync {
                let due = l.addingTimeInterval(300)
                let left = Int(due.timeIntervalSince(m.now))
                Text("Last check \(ptTime(l)) · next due \(ptTime(due))")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(m.staleColor)
                Text(left >= 0 ? "due in \(ago(left)) · last sync \(ago(m.staleSecs ?? 0)) ago" : "overdue by \(ago(-left)) · last sync \(ago(m.staleSecs ?? 0)) ago")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text("Last check — never").font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
            }
            let h = m.history
            let rows: [SyncRow] = h.indices.reversed().prefix(5).map { i in SyncRow(at: h[i], gap: i > 0 ? Int(h[i].timeIntervalSince(h[i - 1])) : nil) }
            ForEach(rows, id: \.at) { r in
                HStack(spacing: 10) {
                    Text(ptTime(r.at)).frame(width: 64, alignment: .leading)
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
            Text(m.statusWord).font(.system(size: 26, weight: .bold)).foregroundColor(m.glow)
        }.frame(maxWidth: .infinity)
    }
}

struct PopView: View {
    @ObservedObject var m: Model
    var restart: () -> Void
    var openHQ: () -> Void
    var runUpdate: () -> Void
    var quit: () -> Void

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
                        quit: { NSApp.terminate(nil) })
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
        if m.level == 2, inStoreWindow(m.now), let s = m.staleSecs, s > 900 {
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
        m.sessionHours = num(r["session_age_hours"])
        if let p = pull { m.record(p) }
        let state = (r["state"] as? String) ?? ""
        m.runnerState = state
        m.runnerRunning = nil
        m.stateText = m.level == 2 ? "No sync" : (state.isEmpty ? "Syncing" : (state == "polling" ? "Syncing" : state.capitalized))
        let s = j["sales"] as? [String: Any] ?? [:]
        m.sales = num(s["net_sales"])
        m.checks = num(s["check_count"]).map { Int($0) }
        m.deltaPct = num(s["delta_pct"])
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
        m.lastSync = mtime
        m.updatedAt = Date()
        m.miniOnline = running
        m.runnerRunning = running
        if let t = mtime { m.record(t) }
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
        }
        m.stateText = !running ? "Runner not running" : (m.level == 2 ? "No sync" : "Syncing")
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
    func checkForUpdate() {
        if updating || Date().timeIntervalSince(lastUpdateCheck) < 60 { return }
        lastUpdateCheck = Date()
        var r = URLRequest(url: URL(string: RELEASES_API)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("ToastStatus/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { [weak self] data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let tag = j["tag_name"] as? String, tag.hasPrefix("v"),
                  let assets = j["assets"] as? [[String: Any]] else { return }
            let v = String(tag.dropFirst())
            func url(_ name: String) -> URL? {
                guard let a = assets.first(where: { ($0["name"] as? String) == name }),
                      let s = a["browser_download_url"] as? String, let u = URL(string: s), u.scheme == "https" else { return nil }
                return u
            }
            guard versionIsNewer(v, than: APP_VERSION) else { DispatchQueue.main.async { self?.m.updateText = nil }; return }
            guard let zipURL = url("toast-status-src.zip"), let shaURL = url("toast-status-src.zip.sha256") else { return }
            URLSession.shared.dataTask(with: shaURL) { sdata, sresp, _ in
                guard (sresp as? HTTPURLResponse)?.statusCode == 200, let sd = sdata,
                      let txt = String(data: sd, encoding: .utf8),
                      let sha = firstMatch("^([0-9a-fA-F]{64})", txt.trimmingCharacters(in: .whitespacesAndNewlines))?[1] else { return }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pendingRelease = (v, zipURL, sha.lowercased())
                    self.m.updateText = "Update available (\(v))"
                    self.applyUpdate()
                }
            }.resume()
        }.resume()
    }

    func applyUpdate() {
        guard let rel = pendingRelease, !updating else { return }
        updating = true
        m.selfUpdating = true
        m.updateText = "Updating to \(rel.version)…"
        URLSession.shared.downloadTask(with: rel.url) { [weak self] tmp, resp, _ in
            guard let self = self else { return }
            func fail(_ msg: String) { DispatchQueue.main.async { self.updating = false; self.m.selfUpdating = false; self.m.updateText = "Update available (\(rel.version))"; self.m.flash = msg } }
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
