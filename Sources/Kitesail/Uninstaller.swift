import SwiftUI
import AppKit
import CoreServices

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    let lastUsed: Date?
    var size: Int64 = 0
    var id: URL { url }

    var unusedDays: Int? { lastUsed.map { Int(Date.now.timeIntervalSince($0) / 86_400) } }
}

struct Leftover: Identifiable {
    let url: URL
    var size: Int64
    var selected = true
    var id: URL { url }
}

enum Uninstaller {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func installedApps() -> [InstalledApp] {
        let roots = ["/Applications", "/Applications/Utilities", home.appending(path: "Applications").path]
        var apps: [InstalledApp] = []
        for root in roots {
            for url in DiskScanner.children(of: URL(fileURLWithPath: root)) where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(url: url, name: name, bundleID: id,
                                         version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                         lastUsed: lastUsed(url)))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Spotlight's "last opened" date for the bundle.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Where apps leave files behind, matched on bundle ID (and on app name where apps commonly use it).
    /// `exact` is false for prefix matches like "com.x.app.helper", which could also belong to a sibling app
    /// (Chrome vs Chrome Canary), so those start unchecked.
    static func leftovers(for app: InstalledApp) -> [(url: URL, exact: Bool)] {
        let lib = home.appending(path: "Library")
        let byID = ["Caches", "Preferences", "Containers", "Saved Application State", "HTTPStorages", "WebKit",
                    "LaunchAgents", "Cookies", "Application Scripts", "Logs", "Application Support"]
        let byName: Set<String> = ["Application Support", "Caches", "Logs"]
        let id = app.bundleID.lowercased()
        let name = app.name.lowercased()
        var found: [(url: URL, exact: Bool)] = []
        for dir in byID {
            for child in DiskScanner.children(of: lib.appending(path: dir)) {
                let n = child.lastPathComponent.lowercased()
                let exact = n == id || n == id + ".plist" || n == id + ".savedstate" || n == id + ".binarycookies"
                // Name-only matches can belong to a sibling app (Firefox vs Firefox Developer Edition): listed, unchecked.
                let nameOnly = byName.contains(dir) && name.count >= 4 && n == name
                if exact { found.append((child, true)) }
                else if nameOnly || n.hasPrefix(id + ".") { found.append((child, false)) }
            }
        }
        // Group containers are named "<TEAMID>.<bundle id or group>".
        for child in DiskScanner.children(of: lib.appending(path: "Group Containers")) {
            let n = child.lastPathComponent.lowercased()
            if n.hasSuffix("." + id) { found.append((child, true)) }
        }
        return found
    }
}

@MainActor @Observable
final class UninstallerModel {
    enum Sort: String, CaseIterable { case size = "Size", unused = "Least used", name = "Name" }

    var apps: [InstalledApp] = []
    var loading = false
    var selection: InstalledApp.ID?
    var leftovers: [Leftover] = []
    var findingLeftovers = false
    var query = ""
    var sort: Sort = .size
    var working = false
    var message: String?

    var selected: InstalledApp? { apps.first { $0.id == selection } }

    var visible: [InstalledApp] {
        let filtered = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .size: return filtered.sorted { $0.size > $1.size }
        case .unused: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return filtered
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        apps = await Task.detached(priority: .utility) { Uninstaller.installedApps() }.value
        for i in apps.indices {
            let url = apps[i].url
            let size = await Task.detached(priority: .background) { DiskScanner.directorySize(url) }.value
            if i < apps.count, apps[i].url == url { apps[i].size = size }
        }
        loading = false
    }

    func select(_ id: InstalledApp.ID?) async {
        selection = id
        leftovers = []
        guard let app = selected else { return }
        findingLeftovers = true
        let found = await Task.detached(priority: .userInitiated) {
            Uninstaller.leftovers(for: app).map { Leftover(url: $0.url, size: DiskScanner.item(for: $0.url)?.size ?? 0, selected: $0.exact) }
        }.value
        guard selection == app.id else { return }
        leftovers = found.sorted { $0.size > $1.size }
        findingLeftovers = false
    }

    func uninstall(_ app: InstalledApp) async {
        // Snapshot before any await: the selection (and `leftovers`) can change while we wait for the app to quit.
        guard selection == app.id else { return }
        let targets = leftovers.filter(\.selected)
        working = true
        defer { working = false }
        // Quit it first so it can't recreate files on the way out.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        for _ in 0..<25 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(200)) }
        if running.contains(where: { !$0.isTerminated }) {
            message = "\(app.name) is still open. Quit it, then try again."
            return
        }
        do {
            // App first: if the admin prompt is cancelled, its settings and data stay untouched.
            _ = try await NSWorkspace.shared.recycle([app.url])
            var freed = app.size
            for l in targets where (try? FileManager.default.trashItem(at: l.url, resultingItemURL: nil)) != nil { freed += l.size }
            ActivityLog.record(.freed, bytes: freed)
            withAnimation(.smooth) { apps.removeAll { $0.id == app.id } }
            selection = nil
            leftovers = []
            message = "Moved \(app.name) and its leftovers (\(formatBytes(freed))) to the Trash."
        } catch {
            message = "Couldn’t remove \(app.name): \(error.localizedDescription)"
        }
    }
}

struct UninstallerView: View {
    @Bindable var model: UninstallerModel
    @Local private var confirm = false

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            listCard.frame(width: 340)
            detailCard.frame(maxWidth: .infinity)
        }
        .padding(Metrics.page)
        .navigationTitle("Uninstaller")
        .navigationSubtitle(model.loading ? "Measuring \(model.apps.count) apps…"
                            : "\(model.apps.count) apps · \(formatBytes(model.apps.reduce(0) { $0 + $1.size }))")
        .toolbar {
            ToolbarItem { Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
        .task { if model.apps.isEmpty { await model.load() } }
        .toast($model.message)
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search apps", text: $model.query).textFieldStyle(.roundedBorder)
            Picker("Sort by", selection: $model.sort) {
                ForEach(UninstallerModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            List(selection: Binding(get: { model.selection }, set: { id in
                guard !model.working else { return }   // don't swap leftovers mid-uninstall
                Task { await model.select(id) }
            })) {
                ForEach(model.visible) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 13)).lineLimit(1)
                            if let days = app.unusedDays, days >= 60 {
                                Text("Unused for \(plural(days / 30, "month"))").font(.system(size: 11)).foregroundStyle(Tone.warn)
                            }
                        }
                        Spacer()
                        Text(app.size > 0 ? formatBytes(app.size) : "–").font(.figure(11, weight: .regular)).foregroundStyle(.secondary)
                    }
                    .tag(app.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .panel(padding: 12)
    }

    @ViewBuilder private var detailCard: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 18, weight: .semibold))
                        Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(app.lastUsed.map { "Last opened \($0.formatted(.relative(presentation: .named)))" } ?? "Never opened, per Spotlight")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                HStack {
                    Text("App bundle").font(.system(size: 13))
                    Spacer()
                    Text(formatBytes(app.size)).font(.figure(13, weight: .medium))
                }
                CardTitle(title: "Leftovers", detail: model.findingLeftovers ? "Searching…" : "\(model.leftovers.count) found in your Library")
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($model.leftovers) { $l in
                            HStack(spacing: 8) {
                                Toggle("Include \(l.url.lastPathComponent)", isOn: $l.selected).toggleStyle(.checkbox).labelsHidden()
                                Text(l.url.path.replacingOccurrences(of: Uninstaller.home.path, with: "~"))
                                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(formatBytes(l.size)).font(.figure(11, weight: .regular)).foregroundStyle(.secondary)
                            }
                        }
                        if !model.findingLeftovers && model.leftovers.isEmpty {
                            Text("No leftovers found.").font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                let total = app.size + model.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
                HStack {
                    Text("Frees \(formatBytes(total)) once you empty the Trash").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                    Button("Uninstall \(app.name)") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(Tone.bad)
                        .disabled(model.working || model.findingLeftovers)
                }
                .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm) {
                    Button("Move to Trash", role: .destructive) { Task { await model.uninstall(app) } }
                } message: {
                    Text("The app and the checked leftovers go to the Trash. You can put them back until you empty it.")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .panel()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Pick an app to see what it leaves behind").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
        }
    }
}
