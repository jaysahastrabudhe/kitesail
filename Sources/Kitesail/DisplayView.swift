import SwiftUI

/// Native grouped form: macOS handles label/control alignment, just like System Settings.
struct DisplayView: View {
    @Bindable var model: DisplayModel

    var body: some View {
        Form {
            if let pending = model.pending {
                Section { revertRow(pending) }
            }
            ForEach(model.displays) { DisplaySection(display: $0, model: model) }
            Section {
                Toggle(isOn: $model.bolderText) {
                    Text("Bolder text rendering")
                    Text("Heavier letter strokes read crisper on 1× monitors. Apps pick it up after you reopen them.")
                }
            } header: {
                Text("Text")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Display")
        .navigationSubtitle("\(model.displays.count) connected")
        .toolbar {
            ToolbarItem {
                Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .animation(.smooth, value: model.pending?.deadline)
        .task { if !model.ddcProbed { await model.probeDDC() } }
        .alert("Display", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private func revertRow(_ pending: PendingChange) -> some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(left)")
                    .font(.figure(15))
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: 28, height: 28)
                    .background(Tone.warn.opacity(0.18), in: .circle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep \(pending.label)?").font(.system(size: 13, weight: .medium))
                Text("If the screen looks wrong, do nothing and it reverts.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { model.revertNow() }
            Button("Keep") { model.keep() }.buttonStyle(.borderedProminent)
        }
    }
}

struct DisplaySection: View {
    let display: DisplayInfo
    @Bindable var model: DisplayModel

    private var isBoosted: Bool { model.boost?.physical == display.id }
    private var isSharp: Bool { isBoosted || display.current?.hiDPI == true }

    var body: some View {
        Section {
            LabeledContent("Panel", value: panelLine)
            LabeledContent("Rendering") {
                HStack(spacing: 6) {
                    Circle().fill(isSharp ? Tone.good : Tone.warn).frame(width: 7, height: 7)
                    Text(isSharp ? "2× (Retina-sharp)" : "1× (soft text)")
                }
            }
            if !isSharp {
                Text("macOS only draws crisp text at 2×. This panel is being drawn at 1×, so letter edges look fuzzy. HiDPI Booster renders at 2× and scales down, the way a Retina screen does.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if isBoosted, let boost = model.boost {
                LabeledContent("Looks like") {
                    Text("\(Int(boost.looksLike.width)) × \(Int(boost.looksLike.height)), drawn at \(Int(boost.looksLike.width * 2)) × \(Int(boost.looksLike.height * 2))")
                }
            } else {
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(display.resolutions) { mode in
                        Text("\(mode.width) × \(mode.height)\(mode.hiDPI ? "  HiDPI" : "")").tag(mode.resolutionKey)
                    }
                }
                if let current = display.current {
                    let rates = display.refreshRates(for: current.resolutionKey)
                    if rates.count > 1 {
                        Picker("Refresh rate", selection: refreshBinding(current)) {
                            ForEach(rates, id: \.self) { rate in Text("\(Int(rate)) Hz").tag(rate) }
                        }
                        .pickerStyle(.menu)
                    } else if let rate = rates.first, rate > 0 {
                        LabeledContent("Refresh rate", value: "\(Int(rate)) Hz")
                    }
                }
            }

            if !display.isBuiltin { hardwareControls }

            if display.canBoost {
                Picker(selection: boosterBinding) {
                    Text("Off").tag(0)
                    ForEach(display.boostPresets, id: \.width) { size in
                        Text("Looks like \(Int(size.width)) × \(Int(size.height))").tag(Int(size.width))
                    }
                } label: {
                    Text("HiDPI Booster")
                    Text("Smaller sizes mean bigger text. Every option renders at 2×.")
                }
                .disabled(model.busy)
            }
        } header: {
            Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display")
        }
    }

    @ViewBuilder private var hardwareControls: some View {
        if let v = model.ddc[display.id], v.responds {
            if let b = v.brightness { slider("Brightness", "sun.max", b, .brightness) }
            if let c = v.contrast { slider("Contrast", "circle.lefthalf.filled", c, .contrast) }
            if let vol = v.volume { slider("Volume", "speaker.wave.2", vol, .volume) }
            Picker("Input", selection: Binding(get: { v.input ?? 0 }, set: { model.setDDC(.input, $0, on: display.id) })) {
                if v.input.map({ code in !MonitorInput.allCases.contains { $0.rawValue == code } }) ?? true { Text("Unknown").tag(v.input ?? 0) }
                ForEach(MonitorInput.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } else if model.ddcProbed {
            LabeledContent("Hardware controls") {
                Text("This monitor didn't answer DDC commands").foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Hardware controls") { ProgressView().controlSize(.small) }
        }
    }

    private func slider(_ title: String, _ symbol: String, _ level: DDCLevel, _ code: VCP) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(level.current) },
                                      set: { model.setDDC(code, UInt16($0.rounded()), on: display.id) }),
                       in: 0...Double(max(level.max, 1)))
                    .frame(width: 220)
                Text("\(Int(Double(level.current) / Double(max(level.max, 1)) * 100))%")
                    .font(.figure(12, weight: .regular)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var panelLine: String {
        var parts: [String] = []
        if display.diagonalInches > 5 { parts.append(String(format: "%.0f″", display.diagonalInches)) }
        parts.append("\(Int(display.nativePixels.width)) × \(Int(display.nativePixels.height))")
        if display.ppi > 0 { parts.append("\(Int(display.ppi)) ppi") }
        return parts.joined(separator: " · ")
    }

    private var resolutionBinding: Binding<String> {
        Binding(get: { display.current?.resolutionKey ?? "" },
                set: { model.apply(resolution: $0, refresh: nil, on: display) })
    }

    private func refreshBinding(_ current: DisplayMode) -> Binding<Double> {
        Binding(get: { current.refresh.rounded() },
                set: { model.apply(resolution: current.resolutionKey, refresh: $0, on: display) })
    }

    private var boosterBinding: Binding<Int> {
        Binding(get: { isBoosted ? Int(model.boost?.looksLike.width ?? 0) : 0 },
                set: { width in
                    if width == 0 {
                        model.keep()
                        model.disableBoost()
                    } else if let size = display.boostPresets.first(where: { Int($0.width) == width }) {
                        Task { await model.enableBoost(on: display, looksLike: size) }
                    }
                })
    }
}
