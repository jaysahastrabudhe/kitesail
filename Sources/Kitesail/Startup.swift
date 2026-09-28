import SwiftUI
import AppKit

struct StartupItem: Identifiable {
    enum Scope: String, CaseIterable {
        case user = "Your agents", global = "Agents for all users", daemon = "System daemons"
        var detail: String {
            switch self {
            case .user: "~/Library/LaunchAgents: start when you log in"
            case .global: "/Library/LaunchAgents: start when anyone logs in"
            case .daemon: "/Library/LaunchDaemons: start at boot, run as root (changes need your password)"
            }
        }
    }
    let plist: URL
    let label: String
    let program: String?
    let scope: Scope
    var disabled: Bool
    var runningBytes: UInt64
    var runningCount: Int
    var id: String { plist.path }
    var orphaned: Bool { program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false }
}

enum StartupScanner {
    static let uid = getuid()

    static func scan() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs: [(String, StartupItem.Scope)] = [("\(home)/Library/LaunchAgents", .user),
                                                     ("/Library/LaunchAgents", .global),
                                                     ("/Library/LaunchDaemons", .daemon)]
        let disabledGUI = disabledLabels(domain: "gui/\(uid)")
        let disabledSystem = disabledLabels(domain: "system")
        let procs = MemoryReader.processes()
        var items: [StartupItem] = []
        for (dir, scope) in dirs {
            for url in DiskScanner.children(of: URL(fileURLWithPath: dir)) where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = dict["Label"] as? String, !label.hasPrefix("com.apple.") else { continue }
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let running = procs.filter { program != nil && $0.path == program }
                let off = (scope == .daemon ? disabledSystem : disabledGUI).contains(label)
                    || (dict["Disabled"] as? Bool ?? false)
                items.append(StartupItem(plist: url, label: label, program: program, scope: scope, disabled: off,
                                         runningBytes: running.reduce(0) { $0 + $1.bytes }, runningCount: running.count))
            }
        }
        return items.sorted { ($0.runningBytes, $1.label) > ($1.runningBytes, $0.label) }
    }

    /// Parses `launchctl print-disabled`, which lists `"label" => disabled|true`.
    static func disabledLabels(domain: String) -> Set<String> {
        let out = run("/bin/launchctl", ["print-disabled", domain])
        var labels = Set<String>()
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            if state == "disabled" || state == "true" {
                labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return labels
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String { runStatus(tool, args).output }

    static func runStatus(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Labels come from third-party plists, so only allow launchd-label characters before building commands.
    static func isSafeLabel(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    /// Unloads a root-owned leftover and moves its plist into your Trash (never deletes it outright).
    static func trashWithAdmin(_ item: StartupItem) -> String? {
        guard isSafeLabel(item.label), !item.plist.path.contains("'"), !item.plist.path.contains("\"") else {
            return "Unusual name, remove it in Finder instead."
        }
        let domain = item.scope == .daemon ? "system" : "gui/\(uid)"
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash").path
        guard !trash.contains("'"), !trash.contains("\"") else { return "Unusual home folder name, remove it in Finder instead." }
        // Timestamp suffix so an older file of the same name already in the Trash is never overwritten.
        let dest = "\(trash)/\(item.plist.lastPathComponent).\(Int(Date().timeIntervalSince1970))"
        let cmd = "launchctl bootout \(domain)/\(item.label) 2>/dev/null; mv '\(item.plist.path)' '\(dest)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(cmd)\" with administrator privileges"]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "Cancelled."
    }

    /// Returns an error message, or nil on success.
    static func setEnabled(_ item: StartupItem, _ enabled: Bool) -> String? {
        guard isSafeLabel(item.label), !item.plist.path.contains("'"), !item.plist.path.contains("\"") else {
            return "Unusual name, change it in System Settings instead."
        }
        if item.scope == .daemon {
            let cmd = enabled
                ? "launchctl enable system/\(item.label); launchctl bootstrap system '\(item.plist.path)'"
                : "launchctl disable system/\(item.label); launchctl bootout system/\(item.label)"
            let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : "Cancelled."
        }
        let target = "gui/\(uid)/\(item.label)"
        // enable/disable is what persists across logins; bootstrap/bootout just applies it now (and fails harmlessly
        // if the agent was already loaded/unloaded), so only the first call decides success.
        let result = runStatus("/bin/launchctl", [enabled ? "enable" : "disable", target])
        guard result.status == 0 else { return "launchctl couldn’t \(enabled ? "enable" : "disable") \(item.label)." }
        if enabled { run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.plist.path]) } else { run("/bin/launchctl", ["bootout", target]) }
        return nil
    }
}

@MainActor @Observable
final class StartupModel {
    var items: [StartupItem] = []
    var loading = false
    var message: String?

    var orphans: Int { items.filter(\.orphaned).count }
    var runningBytes: UInt64 { items.reduce(0) { $0 + $1.runningBytes } }

    func load() async {
        loading = true
        let found = await Task.detached(priority: .utility) { StartupScanner.scan() }.value
        withAnimation(.smooth) { items = found }
        loading = false
    }

    func toggle(_ item: StartupItem, on: Bool) async {
        let error = await Task.detached(priority: .userInitiated) { StartupScanner.setEnabled(item, on) }.value
        message = error ?? "\(on ? "Enabled" : "Disabled") \(item.label)."
        await load()
    }

    /// Orphaned user agents point at an app that no longer exists; their plist can simply go to the Trash.
    var pendingRemoval: StartupItem?

    /// Orphans point at a program that no longer exists; their plist can go to the Trash.
    /// Ones outside your Library are root-owned, so those go through macOS's password prompt.
    func removeOrphan(_ item: StartupItem) async {
        guard item.orphaned else { return }
        if item.scope == .user {
            _ = await Task.detached { StartupScanner.setEnabled(item, false) }.value
            do {
                try FileManager.default.trashItem(at: item.plist, resultingItemURL: nil)
                message = "Moved \(item.plist.lastPathComponent) to the Trash."
            } catch {
                message = "Couldn’t remove it: \(error.localizedDescription)"
            }
        } else {
            let error = await Task.detached { StartupScanner.trashWithAdmin(item) }.value
            message = error ?? "Moved \(item.plist.lastPathComponent) to the Trash."
        }
        await load()
    }
}

struct StartupView: View {
    @Bindable var model: StartupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                if model.orphans > 0 {
                    HStack(spacing: 12) {
                        IconWell(symbol: "exclamationmark.triangle", tint: Tone.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.orphans) leftover\(model.orphans == 1 ? "" : "s") from deleted apps").font(.system(size: 13, weight: .medium))
                            Text("These still try to start at every login but their program is gone. Safe to remove; ones for all users ask for your password.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(padding: 12)
                }
                ForEach(StartupItem.Scope.allCases, id: \.self) { scope in
                    let rows = model.items.filter { $0.scope == scope }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle(title: scope.rawValue, detail: scope.detail + " · RAM in use shown per item").padding(.bottom, 8)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 40) }
                                row(item)
                            }
                        }
                        .panel()
                    }
                }
                if !model.loading && model.items.isEmpty {
                    Text("No third-party startup agents. Nice and lean.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Startup")
        .navigationSubtitle("\(model.items.count) background items · " + (model.runningBytes > 0 ? "\(formatGB(model.runningBytes)) in RAM right now" : "none running right now"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: { Label("Login Items", systemImage: "person.crop.circle.badge.checkmark") }
                    .help("Open Login Items in System Settings")
                Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { await model.load() }
        .toast($model.message)
        .confirmationDialog("Remove this leftover?", isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                            presenting: model.pendingRemoval) { item in
            Button("Move \(item.plist.lastPathComponent) to Trash", role: .destructive) { Task { await model.removeOrphan(item) } }
        } message: { item in
            Text(item.scope == .user ? "Its program is gone, so nothing will break." : "Its program is gone. macOS will ask for your password because this file belongs to the system.")
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            IconWell(symbol: item.orphaned ? "questionmark.folder" : item.runningCount > 0 ? "gearshape.2.fill" : "gearshape.2",
                     tint: item.orphaned ? Tone.warn : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(status(item)).font(.system(size: 11)).foregroundStyle(item.orphaned ? Tone.warn : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.runningBytes > 0 ? formatGB(item.runningBytes) : "–")
                .font(.figure(12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) } label: {
                Image(systemName: "folder").font(.system(size: 12)).frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Show the plist in Finder")
            ZStack(alignment: .trailing) {
                Color.clear
                if item.orphaned {
                    Button("Remove") { model.pendingRemoval = item }.controlSize(.small)
                } else {
                    Toggle("Start \(item.label) automatically", isOn: Binding(get: { !item.disabled }, set: { on in Task { await model.toggle(item, on: on) } }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            .frame(width: 64, height: 22)
        }
        .padding(.vertical, Metrics.row - 2)
    }

    private func status(_ item: StartupItem) -> String {
        if item.orphaned { return "Program missing: \(item.program ?? "")" }
        let state = item.disabled ? "Off" : item.runningCount > 0 ? "Running" : "Not running"
        return [state, item.program].compactMap { $0 }.joined(separator: " · ")
    }
}
