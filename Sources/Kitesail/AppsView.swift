import SwiftUI
import AppKit

struct AppsView: View {
    let watchdog: Watchdog
    @AppStorage(Prefs.guardOn) private var guardOn = false
    @AppStorage(Prefs.guardIdleMinutes) private var idleMinutes = 30
    @AppStorage(Prefs.alerts) private var alerts = true
    @AppStorage(Prefs.keepList) private var keepRaw = ""
    @Local private var running: [NSRunningApplication] = []
    @Local private var confirmQuitAll = false
    @Local private var message: String?

    private var keep: Set<String> { Set(keepRaw.split(separator: ",").map(String.init)) }
    private var quitCount: Int { running.filter { !isKept($0) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                guardCard
                runningCard
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Apps")
        .navigationSubtitle("\(running.count) open · \(quitCount) would quit with Quit All")
        .toolbar {
            ToolbarItem {
                Button { confirmQuitAll = true } label: { Label("Quit All", systemImage: "xmark.circle") }
                    .help("Quit every app not on your keep list")
                    .disabled(quitCount == 0)
            }
        }
        .confirmationDialog("Quit \(plural(quitCount, "app"))?", isPresented: $confirmQuitAll) {
            Button("Quit All", role: .destructive) {
                let n = watchdog.quitAll()
                message = "Asked \(plural(n, "app")) to quit."
                Task { try? await Task.sleep(for: .seconds(1.5)); reload() }
            }
        } message: {
            Text("Apps with unsaved work will ask before closing. Kept apps stay open.")
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .toast($message)
    }

    private func reload() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { bytes(of: $0) > bytes(of: $1) }
    }

    private func bytes(of app: NSRunningApplication) -> UInt64 {
        guard let path = app.bundleURL?.path else { return 0 }
        return watchdog.groups.first { $0.appPath == path }?.bytes ?? 0
    }

    private func isKept(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return true }
        return keep.contains(id) || Watchdog.protectedIDs.contains(id)
    }

    private func setKept(_ app: NSRunningApplication, _ kept: Bool) {
        guard let id = app.bundleIdentifier else { return }
        var ids = keep
        if kept { ids.insert(id) } else { ids.remove(id) }
        keepRaw = ids.sorted().joined(separator: ",")
    }

    // MARK: Memory Guard

    private var guardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconWell(symbol: "shield.lefthalf.filled", tint: guardOn ? Tone.good : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Guard").font(.system(size: 13, weight: .semibold))
                    Text("When memory pressure stays Elevated or Critical for 30 seconds, Kitesail quits the heaviest app you haven't touched in a while. One app per minute, never the one you're using, never your keep list. Apps with unsaved work still ask first. Apps playing audio or exporting are skipped, and it pauses while Keep Awake is on.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Memory Guard", isOn: $guardOn).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            HStack(spacing: 12) {
                Text("Counts as idle after").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("Counts as idle after", selection: $idleMinutes) {
                    Text("15 min").tag(15); Text("30 min").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
                Toggle("Notify me when memory is tight", isOn: $alerts)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .onChange(of: alerts) { _, on in if on { Watchdog.requestNotifications() } }
            }
            let idle = watchdog.idleApps(minutes: idleMinutes)
            Text(idle.isEmpty ? "Nothing is idle long enough to be quit right now."
                              : "Would quit first: " + idle.prefix(3).map { "\($0.name) (\(formatGB($0.bytes)), idle \($0.idleMinutes) min)" }.joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            if !watchdog.guardLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(watchdog.guardLog.prefix(4)) { e in
                        Text("\(e.date.formatted(date: .omitted, time: .shortened))  \(e.text)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .panel()
    }

    // MARK: Running apps + keep list

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Open apps", detail: "Kept apps are never quit by Quit All or Memory Guard")
                .padding(.bottom, 8)
            ForEach(Array(running.enumerated()), id: \.element.processIdentifier) { index, app in
                if index > 0 { Divider().padding(.leading, 40) }
                appRow(app)
            }
        }
        .panel()
    }

    private func appRow(_ app: NSRunningApplication) -> some View {
        let protected = app.bundleIdentifier.map(Watchdog.protectedIDs.contains) ?? true
        let growth = app.bundleURL.flatMap { url in watchdog.growing[url.path] }
        return HStack(spacing: 12) {
            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.localizedName ?? "App").font(.system(size: 13, weight: .medium))
                    if app.isHidden { Text("hidden").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    if let growth {
                        Label("grew \(formatGB(growth.to - growth.from)) in \(growth.minutes) min", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Tone.warn)
                    }
                }
                if let id = app.bundleIdentifier {
                    Text(id).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(bytes(of: app) > 0 ? formatGB(bytes(of: app)) : "–")
                .font(.figure(12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Toggle("Keep", isOn: Binding(get: { isKept(app) }, set: { setKept(app, $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(protected)
                .frame(width: 60, alignment: .leading)
            Button("Quit") { app.terminate(); Task { try? await Task.sleep(for: .seconds(1)); reload() } }
                .controlSize(.small)
                .disabled(protected)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
