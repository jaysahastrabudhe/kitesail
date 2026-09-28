import SwiftUI

/// "Lift Score": one number for how comfortable the Mac is right now.
/// 40 pts storage headroom (full marks at 20 % free), 40 pts memory pressure, 20 pts swap (full under 1 GB, zero at 6 GB).
enum HealthScore {
    static func compute(freeFraction: Double, pressure: Pressure, swapGB: Double) -> Int {
        let storage = min(1, max(0, freeFraction) / 0.2) * 40
        let memory: Double = switch pressure { case .normal: 40; case .warning: 20; case .critical: 0 }
        let swap = max(0, 1 - max(0, swapGB - 1) / 5) * 20
        return Int((storage + memory + swap).rounded())
    }

    static func verdict(_ score: Int) -> (String, Color) {
        switch score {
        case 85...: ("In great shape", Tone.good)
        case 60..<85: ("Could be smoother", Tone.warn)
        default: ("Needs attention", Tone.bad)
        }
    }
}

struct NextAction: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let button: String
    let perform: () -> Void
}

struct OverviewView: View {
    let disk: DiskModel
    let cleanup: CleanupModel
    let memory: MemoryModel
    let display: DisplayModel
    let watchdog: Watchdog
    @Binding var pane: Pane?

    private var freeFraction: Double {
        guard let v = disk.volume else { return 1 }
        return Double(v.available) / Double(max(v.total, 1))
    }

    private var score: Int? {
        guard let s = memory.snapshot else { return nil }
        return HealthScore.compute(freeFraction: freeFraction, pressure: s.pressure,
                                   swapGB: Double(s.swapUsed) / Double(Diagnosis.gib))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HStack(alignment: .top, spacing: Metrics.gap) {
                    scoreCard.frame(width: 260)
                    tiles
                }
                .fixedSize(horizontal: false, vertical: true)

                recapCard

                VStack(alignment: .leading, spacing: 4) {
                    CardTitle(title: "Do next", detail: actions.isEmpty ? nil : "\(actions.count) suggestion\(actions.count == 1 ? "" : "s")")
                        .padding(.bottom, 8)
                    if actions.isEmpty {
                        HStack(spacing: 12) {
                            IconWell(symbol: "checkmark", tint: Tone.good)
                            Text("Nothing needs doing. Your Mac has room to breathe.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider().padding(.leading, 40) }
                        actionRow(action)
                    }
                }
                .panel()
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(score.map { "Lift Score \($0) · \(HealthScore.verdict($0).0)" } ?? "Checking your Mac…")
        .task {
            memory.sample()
            await memory.refreshProcesses()
            if !cleanup.measured { await cleanup.measure() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                memory.sample()
            }
        }
    }

    private var recapCard: some View {
        let r = ActivityLog.recap()
        return HStack(spacing: 0) {
            recapItem("This week", value: r.freed > 0 ? formatBytes(r.freed) : "Nothing yet", caption: "freed by you and Kitesail")
            Divider().frame(height: 36).padding(.horizontal, 16)
            recapItem("Memory Guard", value: "\(r.guardQuits)", caption: r.guardQuits == 1 ? "save" : "saves")
            Divider().frame(height: 36).padding(.horizontal, 16)
            recapItem("Score trend", value: r.scoreStart.flatMap { a in r.scoreEnd.map { b in "\(a) → \(b)" } } ?? "–",
                      caption: "first vs latest day this week")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func recapItem(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.figure(17))
            Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Lift Score")
            HStack {
                Spacer()
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                    if let score {
                        Circle()
                            .trim(from: 0, to: CGFloat(score) / 100)
                            .stroke(HealthScore.verdict(score).1, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    VStack(spacing: 2) {
                        Text(score.map(String.init) ?? "–").font(.figure(44)).contentTransition(.numericText())
                        Text("of 100").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                .animation(.smooth, value: score)
                Spacer()
            }
            if let score {
                Text(HealthScore.verdict(score).0).font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            Text("Storage headroom, memory pressure and swap, in one number.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
    }

    private var tiles: some View {
        let s = memory.snapshot
        return Grid(horizontalSpacing: Metrics.gap, verticalSpacing: Metrics.gap) {
            GridRow {
                StatTile(symbol: "internaldrive", title: "Free storage",
                         value: disk.volume.map { formatBytes($0.available) } ?? "–",
                         caption: freeFraction < 0.15 ? "Below the 15 % macOS likes for swap and updates" : "Plenty of headroom",
                         tone: freeFraction < 0.1 ? Tone.bad : freeFraction < 0.15 ? Tone.warn : nil)
                StatTile(symbol: "memorychip", title: "Memory in use",
                         value: s.map { formatGB($0.used) } ?? "–",
                         caption: s.map { "Pressure \($0.pressure.label.lowercased())" } ?? "",
                         tone: s.flatMap { $0.pressure == .normal ? nil : $0.pressure.color })
            }
            GridRow {
                StatTile(symbol: "arrow.left.arrow.right", title: "Swap on SSD",
                         value: s.map { formatGB($0.swapUsed) } ?? "–",
                         caption: (s?.swapUsed ?? 0) > 2 * Diagnosis.gib ? "Apps are spilling out of RAM" : "Little or no spill-over",
                         tone: (s?.swapUsed ?? 0) > 2 * Diagnosis.gib ? Tone.warn : nil)
                StatTile(symbol: "sparkles", title: "Safe to clean",
                         value: cleanup.measured ? formatBytes(cleanup.reclaimable) : "Measuring…",
                         caption: "Caches, logs and developer junk", tone: nil)
            }
        }
    }

    private var actions: [NextAction] {
        var out: [NextAction] = []
        if let s = memory.snapshot, let heavy = memory.groups.first(where: \.isQuittable),
           s.pressure != .normal || s.swapUsed > 2 * Diagnosis.gib {
            out.append(NextAction(id: "quit", symbol: "xmark.app", tint: Tone.warn,
                                  title: "Quit \(heavy.name)",
                                  detail: "Frees about \(formatGB(heavy.bytes)) of memory and lets swap drain.",
                                  button: "Quit", perform: { memory.quit(heavy) }))
        }
        if let (id, growth) = watchdog.growing.first, let g = watchdog.groups.first(where: { $0.id == id }), g.isQuittable {
            out.append(NextAction(id: "leak", symbol: "chart.line.uptrend.xyaxis", tint: Tone.warn,
                                  title: "\(g.name) keeps growing",
                                  detail: "Up \(formatGB(growth.to - growth.from)) in \(growth.minutes) minutes without letting go. Quitting and reopening it usually fixes this.",
                                  button: "Quit", perform: { memory.quit(g) }))
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            out.append(NextAction(id: "heat", symbol: "thermometer.high", tint: Tone.bad,
                                  title: "Your Mac is slowing down to cool off",
                                  detail: "See which app is working the chip hardest.",
                                  button: "Open Energy", perform: { pane = .energy }))
        }
        if freeFraction < 0.15, let v = disk.volume {
            out.append(NextAction(id: "storage", symbol: "internaldrive", tint: freeFraction < 0.1 ? Tone.bad : Tone.warn,
                                  title: "Free up storage",
                                  detail: "Only \(formatBytes(v.available)) free. The disk map shows what's taking the space.",
                                  button: "Open Disk Map", perform: { pane = .disk }))
        }
        if cleanup.measured, cleanup.reclaimable > 500_000_000 {
            out.append(NextAction(id: "clean", symbol: "sparkles", tint: .secondary,
                                  title: "Clear caches and logs",
                                  detail: "\(formatBytes(cleanup.reclaimable)) that apps will rebuild on their own.",
                                  button: "Review", perform: { pane = .cleanup }))
        }
        if let soft = display.displays.first(where: { $0.canBoost && $0.current?.hiDPI != true && display.boost?.physical != $0.id }) {
            out.append(NextAction(id: "display", symbol: "display", tint: .secondary,
                                  title: "Sharpen \(soft.name)",
                                  detail: "It's drawing text at 1×. HiDPI Booster renders at 2× like a Retina screen.",
                                  button: "Open Display", perform: { pane = .display }))
        }
        return out
    }

    private func actionRow(_ a: NextAction) -> some View {
        HStack(spacing: 12) {
            IconWell(symbol: a.symbol, tint: a.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: 13, weight: .medium))
                Text(a.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(a.button, action: a.perform).buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }
}

struct StatTile: View {
    let symbol: String
    let title: String
    let value: String
    let caption: String
    let tone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value).font(.figure(24)).foregroundStyle(tone ?? .primary).contentTransition(.numericText())
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }
}
