import SwiftUI
import AppKit

/// Explains the "System Data" bar in System Settings → Storage: the parts nobody can see in Finder.
struct SystemDataReport {
    var snapshots: [Date] = []
    var purgeable: Int64 = 0       // space macOS will free on its own when it needs it
    var swap: Int64 = 0            // swap files in /System/Volumes/VM
    var free: Int64 = 0
}

enum SystemDataScanner {
    /// `tmutil listlocalsnapshots /` prints lines like "com.apple.TimeMachine.2026-09-28-101010.local".
    static func parseSnapshots(_ output: String) -> [Date] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return output.split(separator: "\n").compactMap { line in
            guard let r = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
            return f.date(from: String(line[r]))
        }.sorted(by: >)
    }

    static func scan() -> SystemDataReport {
        var r = SystemDataReport()
        r.snapshots = parseSnapshots(StartupScanner.runStatus("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output)
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let raw = v.volumeAvailableCapacity, let important = v.volumeAvailableCapacityForImportantUsage {
            r.free = Int64(raw)
            r.purgeable = max(0, important - Int64(raw))
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        r.swap = Int64(swap.xsu_total)
        return r
    }
}

@MainActor @Observable
final class SystemDataModel {
    var report = SystemDataReport()
    var scanned = false
    var message: String?
    var busy = false

    func scan() async {
        report = await Task.detached(priority: .utility) { SystemDataScanner.scan() }.value
        scanned = true
    }

    /// Local snapshots are root-owned; macOS asks for your password. Time Machine backups on your backup disk are untouched.
    func deleteSnapshots() async {
        busy = true
        let script = "do shell script \"/usr/bin/tmutil thinlocalsnapshots / 999999999999 4\" with administrator privileges"
        let status = await Task.detached { () -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        busy = false
        message = status == 0 ? "Local snapshots removed. Space frees up within a minute." : "Cancelled."
        await scan()
    }
}

struct SystemDataView: View {
    @Bindable var model: SystemDataModel
    @Local private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                Text("“System Data” in Settings is everything that isn't an app, a document or a photo. Most of it is temporary. Here's what's actually in yours.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    item("clock.arrow.circlepath", "Time Machine local snapshots",
                         value: model.report.snapshots.isEmpty ? "None" : plural(model.report.snapshots.count, "snapshot"),
                         detail: model.report.snapshots.isEmpty
                            ? "No hourly snapshots are stored on this disk."
                            : "Hourly safety copies kept on this disk, newest \(model.report.snapshots[0].formatted(.relative(presentation: .named))). macOS deletes them on its own when space runs low.") {
                        if !model.report.snapshots.isEmpty {
                            if model.busy { ProgressView().controlSize(.small) } else { Button("Remove…") { confirm = true } }
                        }
                    }
                    Divider().padding(.leading, 40)
                    item("arrow.3.trianglepath", "Purgeable space", value: formatBytes(model.report.purgeable),
                         detail: "iCloud copies and caches macOS can clear the moment an app needs room. Counted as used, but effectively free.") { EmptyView() }
                    Divider().padding(.leading, 40)
                    item("arrow.left.arrow.right", "Swap files", value: formatBytes(model.report.swap),
                         detail: "RAM that spilled onto the SSD. It shrinks after a restart or when you quit heavy apps (see Memory).") { EmptyView() }
                    Divider().padding(.leading, 40)
                    item("archivebox", "Caches and logs", value: "See Clean Up",
                         detail: "App caches, logs and developer junk also count as System Data. Clean Up clears the safe ones.") { EmptyView() }
                }
                .panel()
            }
            .padding(Metrics.page)
        }
        .navigationTitle("System Data")
        .navigationSubtitle(model.scanned ? "\(formatBytes(model.report.purgeable)) purgeable · \(plural(model.report.snapshots.count, "local snapshot"))" : "Checking…")
        .toolbar { ToolbarItem { Button { Task { await model.scan() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } } }
        .task { await model.scan() }
        .toast($model.message)
        .confirmationDialog("Remove local snapshots?", isPresented: $confirm) {
            Button("Remove Snapshots", role: .destructive) { Task { await model.deleteSnapshots() } }
        } message: {
            Text("Only the copies stored on this Mac are removed. Backups on your Time Machine disk stay. macOS asks for your password.")
        }
    }

    private func item<Trailing: View>(_ symbol: String, _ title: String, value: String, detail: String,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconWell(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(value).font(.figure(13, weight: .medium)).frame(minWidth: 90, alignment: .trailing)
            trailing()
        }
        .padding(.vertical, Metrics.row)
    }
}
