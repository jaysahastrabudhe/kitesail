import SwiftUI
import Charts

struct MemoryView: View {
    @Bindable var model: MemoryModel
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if let s = model.snapshot {
                HStack(alignment: .top, spacing: Metrics.gap) {
                    donut(s).panel()
                    VStack(spacing: Metrics.gap) {
                        breakdown(s).panel()
                        historyChart(s).panel()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: Metrics.gap) {
                    insightsPanel.frame(maxWidth: .infinity).panel()
                    processPanel(s).frame(maxWidth: .infinity).panel()
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Metrics.page)
        .navigationTitle("Memory")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    model.purge()
                } label: {
                    Label(model.purging ? "Flushing…" : "Flush File Cache", systemImage: "wind")
                }
                .disabled(model.purging)
                .help("Runs purge. macOS asks for your password on behalf of “osascript”. Rarely needed: macOS frees cache on demand.")
            }
        }
        .task { await model.monitor() }
        .toast($model.message)
    }

    private var subtitle: String {
        guard let s = model.snapshot else { return "Reading memory…" }
        return "\(formatGB(s.used)) of \(formatGB(s.total)) in use · swap \(formatGB(s.swapUsed))"
    }

    private func segments(_ s: MemorySnapshot) -> [(String, UInt64, Color)] {
        [("App", s.app, Color(hex: 0x8B8FE8)),
         ("Wired", s.wired, Color(hex: 0xC486C9)),
         ("Compressed", s.compressed, Tone.warn),
         ("Cached", s.cached, Color(hex: 0x6FB5AC).opacity(0.7)),
         ("Free", s.free, .white.opacity(0.08))]
    }

    private func donut(_ s: MemorySnapshot) -> some View {
        Chart(segments(s), id: \.0) { seg in
            SectorMark(angle: .value("Bytes", Double(seg.1)), innerRadius: .ratio(0.74), angularInset: 1.5)
                .cornerRadius(5)
                .foregroundStyle(seg.2)
        }
        .chartLegend(.hidden)
        .frame(width: 230, height: 230)
        .overlay {
            VStack(spacing: 4) {
                Text(String(format: "%.1f", Double(s.used) / Double(Diagnosis.gib)))
                    .font(.figure(40))
                    .contentTransition(.numericText())
                Text("GB of \(Int((Double(s.total) / Double(Diagnosis.gib)).rounded())) GB").font(.system(size: 12)).foregroundStyle(.secondary)
                PressureBadge(pressure: s.pressure).padding(.top, 4)
            }
        }
        .padding(6)
    }

    private func breakdown(_ s: MemorySnapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(segments(s).dropLast(), id: \.0) { name, bytes, color in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(formatGB(bytes)).font(.figure(20)).contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold))
                    Text("Swap").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                Text(formatGB(s.swapUsed)).font(.figure(20))
                    .foregroundStyle(s.swapUsed > 2 * Diagnosis.gib ? Tone.warn : .primary)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyChart(_ s: MemorySnapshot) -> some View {
        let totalGB = Double(s.total) / Double(Diagnosis.gib)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 3 minutes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    Label("Used", systemImage: "circle.fill").foregroundStyle(accent)
                    Label("Swap", systemImage: "circle.fill").foregroundStyle(Pressure.warning.color)
                }
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
            }
            Chart(model.history) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Used", point.usedGB), series: .value("s", "used"))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Used", point.usedGB), series: .value("s", "used"))
                    .foregroundStyle(accent)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Swap", point.swapGB), series: .value("s", "swap"))
                    .foregroundStyle(Pressure.warning.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...max(totalGB, model.history.map(\.swapGB).max() ?? 0))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) GB") } }
                }
            }
            .frame(height: 110)
        }
    }

    private var insightsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "What this means")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.insights) { insight in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: insight.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(color(for: insight.tone))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(insight.title).font(.system(size: 13, weight: .semibold))
                                Text(insight.body).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func color(for tone: Insight.Tone) -> Color {
        switch tone { case .good: Pressure.normal.color; case .warn: Pressure.warning.color; case .bad: Pressure.critical.color }
    }

    private func processPanel(_ s: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Heaviest apps", detail: "Helpers counted with their app")
            ScrollView {
                VStack(spacing: 10) {
                    Group {
                        ForEach(model.groups) { group in
                            row(group, total: s.total)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func row(_ group: ProcGroup, total: UInt64) -> some View {
        let share = Double(group.bytes) / Double(max(total, 1))
        return HStack(spacing: 10) {
            Group {
                if let icon = model.icon(for: group) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.2.fill").resizable().scaledToFit().padding(5).foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if group.pids.count > 1 {
                        Text(plural(group.pids.count, "process", "processes")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(formatGB(group.bytes)).font(.figure(12))
                }
                UsageBar(fraction: min(share * 2.5, 1), tint: Color.primary.opacity(0.6))
            }

            ZStack(alignment: .trailing) {
                Color.clear
                if group.isQuittable {
                    Button("Quit") { model.quit(group) }.controlSize(.small)
                }
            }
            .frame(width: 52, height: 22)   // fixed slot keeps sizes and bars aligned across rows
        }
    }
}
