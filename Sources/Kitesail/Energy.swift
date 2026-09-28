import SwiftUI
import AppKit
import IOKit
import Charts

struct BatteryInfo {
    let percent: Int
    let charging: Bool
    let pluggedIn: Bool
    let cycles: Int?
    let health: Int?          // current max capacity as % of design capacity
    let temperatureC: Double?
}

enum SystemReader {
    /// Raw 32-bit per-state tick counters since boot (they wrap after ~2 months awake; diff with `&-`).
    struct Ticks { let user, system, idle, nice: UInt32 }

    /// Busy and total ticks elapsed between two readings, wrap-safe.
    static func delta(_ a: Ticks, _ b: Ticks) -> (busy: UInt64, total: UInt64) {
        let busy = UInt64(b.user &- a.user) + UInt64(b.system &- a.system) + UInt64(b.nice &- a.nice)
        return (busy, busy + UInt64(b.idle &- a.idle))
    }

    static func cpuTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = info.cpu_ticks
        return Ticks(user: user, system: system, idle: idle, nice: nice)
    }

    /// Reads the battery's own registry entry (no permission needed). nil on desktop Macs.
    static func battery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        // Newer macOS nests the capacity figures inside "BatteryData".
        let nested = d["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (d[key] as? Int) ?? (nested[key] as? Int) }
        let design = int("DesignCapacity")
        let maxRaw = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        let health = (design ?? 0) > 0 ? maxRaw.map { min(100, Int((Double($0) / Double(design!) * 100).rounded())) } : nil
        return BatteryInfo(
            percent: d["CurrentCapacity"] as? Int ?? 0,
            charging: d["IsCharging"] as? Bool ?? false,
            pluggedIn: d["ExternalConnected"] as? Bool ?? false,
            cycles: d["CycleCount"] as? Int,
            health: health,
            temperatureC: int("Temperature").map { Double($0) / 100 })
    }
}

struct CPUShare: Identifiable {
    let id: String
    let name: String
    let appPath: String?
    let percent: Double      // of one core, like Activity Monitor
    let pids: [pid_t]
}

@MainActor @Observable
final class EnergyModel {
    var cpuPercent: Double = 0
    var history: [MemorySample] = []    // reuses (date, value) shape: usedGB = CPU %
    var top: [CPUShare] = []
    var thermal = ProcessInfo.processInfo.thermalState
    var battery: BatteryInfo? = SystemReader.battery()
    var temperatures: [TemperatureGroup] = []
    var cpuTempHistory: [Double] = []

    @ObservationIgnored private var lastTicks = SystemReader.cpuTicks()
    @ObservationIgnored private var lastCPU: [String: UInt64] = [:]
    @ObservationIgnored private var lastTime = DispatchTime.now().uptimeNanoseconds

    /// Runs only while the Energy tab is visible.
    func monitor() async {
        while !Task.isCancelled {
            await sample()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func sample() async {
        let groups = await Task.detached(priority: .utility) { MemoryReader.groups(MemoryReader.processes()) }.value
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(max(now - lastTime, 1))
        var shares: [CPUShare] = []
        var next: [String: UInt64] = [:]
        for g in groups {
            next[g.id] = g.cpuNanos
            if let prev = lastCPU[g.id], g.cpuNanos >= prev {
                let pct = Double(g.cpuNanos - prev) / elapsed * 100
                if pct >= 0.5 { shares.append(CPUShare(id: g.id, name: g.name, appPath: g.appPath, percent: pct, pids: g.pids)) }
            }
        }
        let temps = await Task.detached(priority: .utility) { Sensors.read() }.value
        temperatures = temps
        if let cpu = temps.first(where: { $0.id == "CPU" })?.celsius {
            cpuTempHistory = Array((cpuTempHistory + [cpu]).suffix(60))
        }
        let firstSample = lastCPU.isEmpty
        lastCPU = next
        lastTime = now

        if let t = SystemReader.cpuTicks() {
            if let p = lastTicks {
                let d = SystemReader.delta(p, t)
                if d.total > 0 { cpuPercent = Double(d.busy) / Double(d.total) * 100 }
            }
            lastTicks = t
        }
        withAnimation(.smooth) {
            if !firstSample { top = Array(shares.sorted { $0.percent > $1.percent }.prefix(10)) }
            history.append(MemorySample(date: .now, usedGB: cpuPercent, swapGB: 0))
            if history.count > 60 { history.removeFirst(history.count - 60) }
            thermal = ProcessInfo.processInfo.thermalState
            battery = SystemReader.battery()
        }
    }

    func quit(_ share: CPUShare) {
        if let path = share.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            app.terminate()
        } else {
            share.pids.forEach { kill($0, SIGTERM) }
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Cool"; case .fair: "Warm"; case .serious: "Hot, slowing down"; case .critical: "Very hot, heavily throttled"
        @unknown default: "Unknown"
        }
    }
    var tone: Color {
        switch self { case .nominal: Tone.good; case .fair: Tone.warn; default: Tone.bad }
    }
    var advice: String {
        switch self {
        case .nominal: "Running at full speed."
        case .fair: "Warming up. A fanless Mac starts trimming speed soon after this."
        case .serious, .critical: "macOS is slowing the chip to cool it. Quit the top CPU app below, or give it a hard surface and some air."
        @unknown default: ""
        }
    }
}

struct EnergyView: View {
    @Bindable var model: EnergyModel
    let awake: KeepAwake

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HStack(alignment: .top, spacing: Metrics.gap) {
                    cpuCard
                    VStack(spacing: Metrics.gap) {
                        thermalCard
                        if let b = model.battery { batteryCard(b) }
                    }
                    .frame(width: 300)
                }
                .fixedSize(horizontal: false, vertical: true)
                TemperatureCard(groups: model.temperatures, history: model.cpuTempHistory)
                KeepAwakeCard(awake: awake)
                topCard
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Energy")
        .navigationSubtitle("CPU \(Int(model.cpuPercent.rounded()))% · \(model.thermal.label)" + (model.battery.map { " · battery \($0.percent)%" } ?? ""))
        .task { await model.monitor() }
    }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "CPU", detail: "all cores, last 3 minutes")
            Text("\(Int(model.cpuPercent.rounded()))%").font(.figure(34)).contentTransition(.numericText())
            Chart(model.history) { p in
                AreaMark(x: .value("t", p.date), y: .value("CPU", p.usedGB))
                    .foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.date), y: .value("CPU", p.usedGB))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                }
            }
            .frame(minHeight: 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }

    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Temperature")
            HStack(spacing: 8) {
                Circle().fill(model.thermal.tone).frame(width: 8, height: 8)
                Text(model.thermal.label).font(.system(size: 15, weight: .semibold))
            }
            Text(model.thermal.advice).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func batteryCard(_ b: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Battery", detail: b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(b.percent)%").font(.figure(24))
                Spacer()
                if let h = b.health {
                    Text("Health \(h)%").font(.figure(12, weight: .medium)).foregroundStyle(h < 80 ? Tone.warn : .secondary)
                }
            }
            UsageBar(fraction: Double(b.percent) / 100, tint: b.percent < 20 ? Tone.bad : Color.primary.opacity(0.7))
            HStack {
                if let c = b.cycles { Text("\(c) cycles") }
                Spacer()
                if let t = b.temperatureC { Text(String(format: "%.0f °C", t)) }
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if let h = b.health, h < 80 {
                Text("Below 80% of its original capacity, the point where Apple recommends service.")
                    .font(.system(size: 11)).foregroundStyle(Tone.warn)
            }
        }
        .panel()
    }

    private var topCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Using the most CPU", detail: "100% = one full core").padding(.bottom, 8)
            if model.top.isEmpty {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(Array(model.top.enumerated()), id: \.element.id) { index, share in
                if index > 0 { Divider().padding(.leading, 40) }
                HStack(spacing: 12) {
                    Group {
                        if let path = share.appPath {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                        } else {
                            IconWell(symbol: "gearshape.2")
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(share.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(String(format: "%.0f%%", share.percent)).font(.figure(12, weight: .medium))
                        .foregroundStyle(share.percent > 80 ? Tone.warn : .secondary)
                        .frame(width: 56, alignment: .trailing)
                    ZStack(alignment: .trailing) {
                        Color.clear
                        if share.appPath.map({ !$0.hasPrefix("/System/") && $0 != Bundle.main.bundlePath }) ?? false {
                            Button("Quit") { model.quit(share) }.controlSize(.small)
                        }
                    }
                    .frame(width: 52, height: 22)
                }
                .padding(.vertical, 6)
            }
        }
        .panel()
    }
}
