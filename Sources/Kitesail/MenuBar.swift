import SwiftUI
import AppKit

struct MenuBarPanel: View {
    let model: Watchdog
    @Local private var confirmQuitAll = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = model.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    PressureBadge(pressure: s.pressure)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(formatGB(s.used)) of \(formatGB(s.total))").font(.figure(12, weight: .medium))
                        Spacer()
                        Text("Swap \(formatGB(s.swapUsed))").font(.figure(12, weight: .regular)).foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: Double(s.used) / Double(max(s.total, 1)), tint: s.pressure.color)
                }
                Divider()
                ForEach(model.groups.prefix(4)) { g in
                    HStack(spacing: 8) {
                        Text(g.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(formatGB(g.bytes)).font(.figure(12, weight: .regular)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Label(model.awake.isOn ? "Awake · \(model.awake.label.replacingOccurrences(of: "On ", with: ""))" : "Keep Awake",
                      systemImage: model.awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12))
                Spacer()
                Menu(model.awake.isOn ? "Change" : "Start") {
                    Button("30 minutes") { model.awake.start(minutes: 30) }
                    Button("1 hour") { model.awake.start(minutes: 60) }
                    Button("2 hours") { model.awake.start(minutes: 120) }
                    Button("Until I turn it off") { model.awake.start(minutes: nil) }
                    if model.awake.isOn { Divider(); Button("Turn Off") { model.awake.stop() } }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
            }
            Button {
                ClipboardPanel.shared.toggle(history: model.clipboard)
            } label: {
                Label("Clipboard History  \(model.clipboard.shortcutLabel)", systemImage: "list.clipboard").font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Divider()
            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Text("Open Kitesail").frame(maxWidth: .infinity)
                }
                Button {
                    confirmQuitAll = true
                } label: {
                    Text("Quit All Apps").frame(maxWidth: .infinity)
                }
                .help("Quits every app except those on your keep list")
            }
            .buttonStyle(.bordered)
            .confirmationDialog("Quit \(plural(model.quitCandidates().count, "app"))?", isPresented: $confirmQuitAll) {
                Button("Quit All", role: .destructive) { model.quitAll() }
            } message: {
                Text("Apps with unsaved work will ask before closing. Your keep list is left running.")
            }
        }
        .padding(14)
        .frame(width: 270)
        .task { await model.refreshGroups(recordHistory: false) }
    }
}

struct PressureBadge: View {
    let pressure: Pressure
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(pressure.color).frame(width: 7, height: 7)
            Text(pressure.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}
