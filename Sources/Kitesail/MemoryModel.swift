import SwiftUI
import AppKit
import Darwin

enum Pressure: Int32, Sendable {
    case normal = 1, warning = 2, critical = 4
    var label: String { switch self { case .normal: "Normal"; case .warning: "Elevated"; case .critical: "Critical" } }
    var color: Color { switch self { case .normal: Tone.good; case .warning: Tone.warn; case .critical: Tone.bad } }
}

/// Same buckets Activity Monitor shows.
struct MemorySnapshot: Sendable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: Pressure
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
}

struct ProcGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let appPath: String?
    var bytes: UInt64
    var pids: [pid_t]
    var cpuNanos: UInt64 = 0   // cumulative CPU time across the group's processes

    /// Apps outside /System can be quit; Finder, Dock and daemons are left alone.
    var isQuittable: Bool {
        guard let appPath else { return false }
        return !appPath.hasPrefix("/System/") && appPath != Bundle.main.bundlePath
    }
}

enum MemoryReader {
    static func snapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            app: (internalPages - min(purgeable, internalPages)) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: Pressure(rawValue: level) ?? .normal)
    }

    struct ProcInfo: Sendable {
        let pid: pid_t
        let path: String
        let bytes: UInt64
        let cpuNanos: UInt64
    }

    /// Every readable process (other users' processes aren't readable without root, so they're skipped).
    static func processes() -> [ProcInfo] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)   // rusage CPU times are in mach ticks on Apple Silicon
        var out: [ProcInfo] = []
        out.reserveCapacity(found)
        for pid in pids.prefix(max(0, found)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            guard ok, info.ri_phys_footprint > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let ticks = info.ri_user_time + info.ri_system_time
            out.append(ProcInfo(pid: pid, path: len > 0 ? String(cString: pathBuffer) : "",
                                bytes: info.ri_phys_footprint,
                                cpuNanos: ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))))
        }
        return out
    }

    /// Physical footprint rolled up to the owning .app (so 30 Chrome helpers count as "Google Chrome").
    static func groups(_ procs: [ProcInfo]) -> [ProcGroup] {
        var groups: [String: ProcGroup] = [:]
        for p in procs {
            let (key, name, app) = identity(path: p.path, pid: p.pid)
            groups[key, default: ProcGroup(id: key, name: name, appPath: app, bytes: 0, pids: [])].bytes += p.bytes
            groups[key]?.pids.append(p.pid)
            groups[key]?.cpuNanos += p.cpuNanos
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    static func topGroups(limit: Int) -> [ProcGroup] {
        Array(groups(processes()).prefix(limit))
    }

    static func identity(path: String, pid: pid_t) -> (key: String, name: String, app: String?) {
        if let range = path.range(of: ".app/") {
            let app = String(path[..<range.lowerBound]) + ".app"
            return (app, (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), app)
        }
        if !path.isEmpty { return (path, (path as NSString).lastPathComponent, nil) }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return ("pid-\(name)", name.isEmpty ? "pid \(pid)" : name, nil)
    }
}

struct Insight: Identifiable {
    enum Tone { case good, warn, bad }
    let id = UUID()
    let symbol: String
    let title: String
    let body: String
    let tone: Tone
}

/// Turns raw numbers into "should I quit something, and what?"
enum Diagnosis {
    static let gib: UInt64 = 1_073_741_824

    static func insights(_ s: MemorySnapshot, top: [ProcGroup]) -> [Insight] {
        var out: [Insight] = []
        switch s.pressure {
        case .normal where s.swapUsed > 256 * 1_048_576:
            out.append(Insight(symbol: "checkmark.seal", title: "Pressure is normal right now",
                body: "But \(formatGB(s.swapUsed)) was pushed to disk earlier and is still there. Quitting the app that grew largest lets it drain.",
                tone: .warn))
        case .normal:
            out.append(Insight(symbol: "checkmark.seal.fill", title: "Memory pressure is normal",
                body: "Every app is being served from RAM. Quitting apps right now won’t make your Mac faster. Unused RAM is wasted RAM, and the \(formatGB(s.cached)) of file cache is handed back the instant an app needs it.",
                tone: .good))
        case .warning:
            out.append(Insight(symbol: "exclamationmark.triangle.fill", title: "Memory is getting tight",
                body: "macOS is compressing \(formatGB(s.compressed)) to make room and is close to swapping. Quitting one heavy app below brings pressure back to normal.",
                tone: .warn))
        case .critical:
            out.append(Insight(symbol: "flame.fill", title: "Your Mac is out of memory",
                body: "Apps are being pushed out to the SSD, which is why switching windows and typing feel laggy. Quit the heaviest app below, starting with ones you aren’t using.",
                tone: .bad))
        }

        if s.swapUsed > 256 * 1_048_576 {
            out.append(Insight(symbol: "arrow.left.arrow.right.circle.fill", title: "\(formatGB(s.swapUsed)) swapped to disk",
                body: "That much app memory lives on the SSD instead of RAM. Reading it back takes microseconds instead of nanoseconds, so apps stall when you return to them. Swap only shrinks after pressure drops: quit what grew large, or restart to clear it fully.",
                tone: .warn))
        }

        if s.total > 0, Double(s.compressed) / Double(s.total) > 0.15 {
            out.append(Insight(symbol: "rectangle.compress.vertical", title: "Heavy compression",
                body: "\(formatGB(s.compressed)) of RAM is being squeezed on the fly. That costs CPU time and battery, and on a fanless Mac it adds heat.",
                tone: .warn))
        }

        if let heaviest = top.first(where: \.isQuittable), s.total > 0 {
            let share = Double(heaviest.bytes) / Double(s.total)
            let stressed = s.pressure != .normal || s.swapUsed > gib
            if stressed || share > 0.25 {
                out.append(Insight(symbol: "scope", title: "\(heaviest.name) is your biggest lever",
                    body: "It holds \(formatGB(heaviest.bytes)), \(Int(share * 100))% of your RAM, across \(heaviest.pids.count) process\(heaviest.pids.count == 1 ? "" : "es"). Quitting it frees about that much at once.",
                    tone: stressed ? .warn : .good))
            }
        }

        let browsers = ["Google Chrome", "Safari", "Arc", "Microsoft Edge", "Brave Browser", "Firefox", "Dia", "Comet"]
        if let browser = top.first(where: { browsers.contains($0.name) }), browser.pids.count > 6 {
            out.append(Insight(symbol: "square.stack.3d.up.fill", title: "Tabs are processes",
                body: "\(browser.name) runs \(browser.pids.count) processes. Each open tab and extension is its own. Closing tabs you aren’t using frees memory without quitting the browser.",
                tone: .good))
        }
        return out
    }
}

struct MemorySample: Identifiable {
    let id = UUID()
    let date: Date
    let usedGB: Double
    let swapGB: Double
}

@MainActor @Observable
final class MemoryModel {
    var snapshot: MemorySnapshot?
    var history: [MemorySample] = []
    var groups: [ProcGroup] = []
    var purging = false
    var message: String?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    var insights: [Insight] { snapshot.map { Diagnosis.insights($0, top: groups) } ?? [] }

    /// Runs only while the Memory tab is on screen (the view's .task cancels it).
    func monitor() async {
        var tick = 0
        while !Task.isCancelled {
            sample()
            if tick % 2 == 0 { await refreshProcesses() }
            tick += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func sample() {
        guard let s = MemoryReader.snapshot() else { return }
        withAnimation(.smooth(duration: 0.6)) {
            snapshot = s
            history.append(MemorySample(date: .now, usedGB: Double(s.used) / Double(Diagnosis.gib),
                                        swapGB: Double(s.swapUsed) / Double(Diagnosis.gib)))
            if history.count > 90 { history.removeFirst(history.count - 90) }
        }
    }

    func refreshProcesses() async {
        let result = await Task.detached(priority: .utility) { MemoryReader.topGroups(limit: 10) }.value
        withAnimation(.smooth) { groups = result }
    }

    func icon(for group: ProcGroup) -> NSImage? {
        guard let path = group.appPath else { return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    func quit(_ group: ProcGroup) {
        if let path = group.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            app.terminate()  // graceful: the app can ask to save documents
        } else {
            group.pids.forEach { kill($0, SIGTERM) }
        }
        message = "Asked \(group.name) to quit."
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.sample()
            await self?.refreshProcesses()
        }
    }

    /// `purge` flushes the file cache. It needs admin rights, so macOS shows its own password prompt.
    func purge() {
        purging = true
        let before = snapshot?.free ?? 0
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        process.terminationHandler = { [weak self] p in
            let ok = p.terminationStatus == 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.purging = false
                self.sample()
                let after = self.snapshot?.free ?? 0
                self.message = ok ? "Cache flushed: \(formatGB(after > before ? after - before : 0)) more free right now. macOS will refill it as you work, which is normal."
                                  : "Purge cancelled."
            }
        }
        do { try process.run() } catch { purging = false; message = "Couldn’t run purge: \(error.localizedDescription)" }
    }
}
