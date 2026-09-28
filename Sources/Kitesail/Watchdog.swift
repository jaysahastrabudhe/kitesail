import SwiftUI
import AppKit
import UserNotifications
import Carbon.HIToolbox
import IOKit.pwr_mgt

/// User preferences shared by the Apps pane, Settings and the watchdog.
enum Prefs {
    static let alerts = "memoryAlerts"            // Bool, default true
    static let guardOn = "memoryGuard"            // Bool, default false (it quits apps, so opt-in)
    static let guardIdleMinutes = "guardIdleMinutes"
    static let keepList = "keepList"              // comma-separated bundle IDs never quit by Quit All / Guard

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [alerts: false, guardOn: false, guardIdleMinutes: 30,
                                                  keepList: "com.apple.finder,com.apple.Terminal,com.1password.1password"])
    }
    static var keep: Set<String> {
        Set((UserDefaults.standard.string(forKey: keepList) ?? "").split(separator: ",").map(String.init))
    }
    static func setKeep(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted().joined(separator: ","), forKey: keepList)
    }
}

struct Growth: Equatable {
    let from: UInt64
    let to: UInt64
    let minutes: Int
}

/// Leak watch: flags memory that climbs steadily, not a one-off spike.
enum LeakWatch {
    static let minSamples = 30                  // ≥ 30 minutes at one sample per minute
    static let minGain: UInt64 = 500 * 1_048_576

    static func growth(_ values: [UInt64]) -> Growth? {
        guard values.count >= minSamples, let first = values.first, let last = values.last,
              last > first + minGain, Double(last) >= Double(first) * 1.5 else { return nil }
        let rises = zip(values, values.dropFirst()).filter { $1 >= $0 }.count
        guard Double(rises) / Double(values.count - 1) >= 0.7 else { return nil }
        return Growth(from: first, to: last, minutes: values.count - 1)
    }
}

struct GuardEvent: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

struct IdleApp: Identifiable {
    let app: NSRunningApplication
    let idleMinutes: Int
    let bytes: UInt64
    var id: pid_t { app.processIdentifier }
    var name: String { app.localizedName ?? "App" }
}

/// Always-on background service (cheap: one kernel read every 5 s, a process sweep once a minute).
@MainActor @Observable
final class Watchdog {
    var snapshot: MemorySnapshot?
    var groups: [ProcGroup] = []
    var growing: [String: Growth] = [:]
    var guardLog: [GuardEvent] = []
    let clipboard = ClipboardHistory()
    let awake = KeepAwake()

    @ObservationIgnored private var history: [String: [UInt64]] = [:]
    @ObservationIgnored private var lastActive: [pid_t: Date] = [:]
    @ObservationIgnored private var pressureSince: Date?
    @ObservationIgnored private var lastAlert = Date.distantPast
    @ObservationIgnored private var lastGuardAction = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private let started = Date()

    static let protectedIDs: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]

    var usedPercent: Int {
        guard let s = snapshot, s.total > 0 else { return 0 }
        return Int((Double(s.used) / Double(s.total) * 100).rounded())
    }

    init() {
        Prefs.registerDefaults()
        snapshot = MemoryReader.snapshot()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = .now } }
        }
        // Idle is measured from when you *left* an app, so record deactivation too.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = .now } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer?.tolerance = 1   // lets macOS batch wake-ups (energy)
        Task { await refreshGroups() }
        clipboard.registerHotkey()
        if UserDefaults.standard.bool(forKey: Prefs.alerts) { Self.requestNotifications() }
    }

    private func step() {
        tick += 1
        guard let s = MemoryReader.snapshot() else { return }
        snapshot = s
        if s.pressure == .normal { pressureSince = nil } else if pressureSince == nil { pressureSince = .now }
        if tick % 12 == 0 { Task { await refreshGroups(recordHistory: true) } }
        if tick % 720 == 1 { dailyBookkeeping(s) }   // on launch, then hourly
        let sustained = pressureSince.map { Date.now.timeIntervalSince($0) >= 30 } ?? false
        guard sustained else { return }
        if UserDefaults.standard.bool(forKey: Prefs.guardOn) { runGuard() }
        else if UserDefaults.standard.bool(forKey: Prefs.alerts) { alertIfNeeded(s) }
    }

    /// Leak watch assumes one sample per minute, so only the 60 s tick records history; on-demand refreshes don't.
    func refreshGroups(recordHistory: Bool = false) async {
        let all = await Task.detached(priority: .utility) { MemoryReader.groups(MemoryReader.processes()) }.value
        groups = Array(all.prefix(40))
        guard recordHistory else { return }
        var next: [String: [UInt64]] = [:]
        var found: [String: Growth] = [:]
        for g in groups {
            let series = (history[g.id] ?? []) + [g.bytes]
            next[g.id] = Array(series.suffix(90))          // 90 minutes max per app
            if let growth = LeakWatch.growth(next[g.id]!) { found[g.id] = growth }
        }
        history = next
        growing = found
    }

    // MARK: Weekly recap

    private func dailyBookkeeping(_ s: MemorySnapshot) {
        if let v = DiskScanner.volume(for: URL(fileURLWithPath: "/")) {
            ActivityLog.recordScore(HealthScore.compute(freeFraction: Double(v.available) / Double(max(v.total, 1)),
                                                        pressure: s.pressure, swapGB: Double(s.swapUsed) / Double(Diagnosis.gib)))
        }
        guard ActivityLog.recapDue() else { return }
        let r = ActivityLog.recap()
        var parts = ["You freed \(formatBytes(r.freed))"]
        if r.guardQuits > 0 { parts.append("Memory Guard stepped in \(r.guardQuits) time\(r.guardQuits == 1 ? "" : "s")") }
        if let a = r.scoreStart, let b = r.scoreEnd { parts.append("Lift Score \(a) → \(b)") }
        Self.notify(title: "Your week with Kitesail", body: parts.joined(separator: " · ") + ".")
    }

    // MARK: Memory alerts

    private func alertIfNeeded(_ s: MemorySnapshot) {
        guard Date.now.timeIntervalSince(lastAlert) > 15 * 60 else { return }
        lastAlert = .now
        let heavy = groups.first(where: \.isQuittable)
        Self.notify(title: s.pressure == .critical ? "Your Mac is out of memory" : "Memory is getting tight",
                    body: heavy.map { "\($0.name) is using \(formatGB($0.bytes)). Quitting it would free that much." }
                        ?? "Open Kitesail to see what's using memory.")
    }

    // MARK: Memory Guard: under sustained pressure, quit the heaviest *idle* app, one per minute

    /// Apps holding a power assertion (playing audio, exporting, downloading) are busy even when not frontmost.
    static func pidsKeepingMacAwake() -> Set<pid_t> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPID = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var pids = Set(byPID.keys.map { pid_t($0.int32Value) })
        for assertions in byPID.values {
            for a in assertions { if let p = a["AssertionOnBehalfOfPID"] as? Int { pids.insert(pid_t(p)) } }
        }
        return pids
    }

    func idleApps(minutes: Int) -> [IdleApp] {
        let keep = Prefs.keep.union(Self.protectedIDs)
        let busy = Self.pidsKeepingMacAwake()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isActive, !app.isTerminated,
                  let id = app.bundleIdentifier, !keep.contains(id), id != Bundle.main.bundleIdentifier,
                  let path = app.bundleURL?.path, !path.hasPrefix("/System/") else { return nil }
            let launched = max(started, app.launchDate ?? started)
            let since = max(lastActive[app.processIdentifier] ?? launched, launched)   // a reused PID can't inherit an old timestamp
            let idle = Int(Date.now.timeIntervalSince(since) / 60)
            guard idle >= minutes, !busy.contains(app.processIdentifier) else { return nil }
            return IdleApp(app: app, idleMinutes: idle, bytes: groups.first { $0.appPath == path }?.bytes ?? 0)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func runGuard() {
        // Keep Awake means "I'm in the middle of something": don't quit anything.
        guard !awake.isOn, Date.now.timeIntervalSince(lastGuardAction) > 60 else { return }
        let minutes = UserDefaults.standard.integer(forKey: Prefs.guardIdleMinutes)
        guard let victim = idleApps(minutes: max(minutes, 5)).first else { return }
        lastGuardAction = .now
        victim.app.terminate()   // graceful: apps with unsaved work still ask
        let text = "Quit \(victim.name) (\(formatGB(victim.bytes)), idle \(victim.idleMinutes) min) to relieve memory pressure."
        guardLog.insert(GuardEvent(date: .now, text: text), at: 0)
        guardLog = Array(guardLog.prefix(20))
        ActivityLog.record(.guardQuit, bytes: Int64(victim.bytes))
        Self.notify(title: "Memory Guard", body: text)
    }

    // MARK: Quit All

    func quitCandidates() -> [NSRunningApplication] {
        let keep = Prefs.keep.union(Self.protectedIDs)
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated &&
            app.bundleIdentifier.map { !keep.contains($0) && $0 != Bundle.main.bundleIdentifier } ?? false
        }
    }

    @discardableResult
    func quitAll() -> Int {
        let apps = quitCandidates()
        apps.forEach { $0.terminate() }
        Task { try? await Task.sleep(for: .seconds(2)); await refreshGroups() }
        return apps.count
    }

    // MARK: Notifications

    /// UNUserNotificationCenter throws when the binary runs outside its .app bundle (e.g. `--selftest`).
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
