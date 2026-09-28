import SwiftUI
import AppKit
import QuickLook

struct JunkGroup: Identifiable {
    enum Kind {
        case contents      // folder contents that apps regenerate: safe to clear
        case oldInstallers // .dmg/.pkg/.xip/.iso files older than two weeks in Downloads/Desktop
        case reviewOnly    // worth knowing about, but only you can decide (backups, the Trash): opens in Finder
    }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let folders: [URL]
    var kind: Kind = .contents
    var size: Int64 = 0
    var files: [URL] = []

    static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso", "mpkg"]

    static func oldInstallers(in folders: [URL], olderThan days: Double = 14) -> [URL] {
        let cutoff = Date.now.addingTimeInterval(-days * 86_400)
        return folders.flatMap { DiskScanner.children(of: $0) }.filter { url in
            guard installerExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (modified ?? .now) < cutoff
        }
    }
}

struct LargeFile: Identifiable {
    let url: URL
    let size: Int64
    let lastUsed: Date?
    var id: URL { url }
}

@MainActor @Observable
final class CleanupModel {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let largeFileThreshold: Int64 = 500_000_000

    var groups: [JunkGroup] = CleanupModel.defaultGroups()
    var largeFiles: [LargeFile] = []
    var measured = false
    var measuring = false
    var busyGroup: String?
    var searchingLarge = false
    var message: String?
    var preview: URL?
    var pendingGroup: JunkGroup?
    var pendingFile: LargeFile?

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var queryObserver: NSObjectProtocol?

    /// Only what Kitesail would clear itself: review-only groups (backups, Trash) are excluded.
    var reclaimable: Int64 { groups.filter { $0.kind != .reviewOnly }.reduce(0) { $0 + $1.size } }

    static func defaultGroups() -> [JunkGroup] {
        func h(_ p: String) -> URL { home.appending(path: p) }
        return [
            JunkGroup(id: "caches", title: "App caches", detail: "Temporary files apps rebuild. Apps may open a little slower once.",
                      symbol: "archivebox", folders: [h("Library/Caches")]),
            JunkGroup(id: "logs", title: "Logs", detail: "Diagnostic logs from apps and the system.",
                      symbol: "doc.text", folders: [h("Library/Logs")]),
            JunkGroup(id: "dev", title: "Developer caches", detail: "Xcode DerivedData, simulator caches, npm, pip and Yarn caches.",
                      symbol: "hammer", folders: [h("Library/Developer/Xcode/DerivedData"), h("Library/Developer/CoreSimulator/Caches"),
                                                  h(".npm/_cacache"), h(".cache/pip"), h(".cache/yarn")]),
            JunkGroup(id: "mail", title: "Mail downloads", detail: "Attachments Mail saved when you opened them. The originals stay in Mail.",
                      symbol: "paperclip", folders: [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]),
            JunkGroup(id: "installers", title: "Old installers", detail: "Disk images and packages in Downloads and Desktop, older than two weeks.",
                      symbol: "shippingbox", folders: [h("Downloads"), h("Desktop")], kind: .oldInstallers),
            JunkGroup(id: "devicesupport", title: "Xcode device support", detail: "Debug symbols for iOS versions. Xcode re-downloads what it needs.",
                      symbol: "iphone", folders: [h("Library/Developer/Xcode/iOS DeviceSupport"), h("Library/Developer/Xcode/watchOS DeviceSupport")]),
            JunkGroup(id: "backups", title: "iPhone and iPad backups", detail: "Local device backups. Keep the newest if you rely on it.",
                      symbol: "externaldrive.badge.timemachine", folders: [h("Library/Application Support/MobileSync/Backup")], kind: .reviewOnly),
            JunkGroup(id: "trash", title: "Trash", detail: "Already deleted, still using space until you empty it.",
                      symbol: "trash", folders: [h(".Trash")], kind: .reviewOnly),
        ]
    }

    /// Folders macOS refuses to list without Full Disk Access (they exist but can't be read).
    var needsFullDiskAccess: [String] = []

    func measure() async {
        guard !measuring else { return }
        measuring = true
        needsFullDiskAccess = groups.filter { g in
            g.folders.contains { f in
                FileManager.default.fileExists(atPath: f.path) && (try? FileManager.default.contentsOfDirectory(atPath: f.path)) == nil
            }
        }.map(\.id)
        for i in groups.indices {
            let group = groups[i]
            let (size, files) = await Task.detached(priority: .background) { () -> (Int64, [URL]) in
                if group.kind == .oldInstallers {
                    let files = JunkGroup.oldInstallers(in: group.folders)
                    return (files.reduce(0) { $0 + (DiskScanner.item(for: $1)?.size ?? 0) }, files)
                }
                return (group.folders.reduce(0) { $0 + DiskScanner.directorySize($1) }, [])
            }.value
            withAnimation(.smooth) { groups[i].size = size; groups[i].files = files }
        }
        measured = true
        measuring = false
    }

    /// Moves each folder's contents (never the folder itself) to the Trash. Items in use are skipped.
    func clean(_ group: JunkGroup) async {
        busyGroup = group.id
        guard group.kind != .reviewOnly else { busyGroup = nil; return }
        let folders = group.folders
        let targets = group.kind == .oldInstallers ? group.files : []
        let kind = group.kind
        let (moved, skipped) = await Task.detached(priority: .userInitiated) { () -> (Int, Int) in
            var moved = 0, skipped = 0
            // Old installers only ever trash the listed files, never whole Downloads/Desktop.
            let items = kind == .oldInstallers ? targets : folders.flatMap { DiskScanner.children(of: $0) }
            for item in items {
                if (try? FileManager.default.trashItem(at: item, resultingItemURL: nil)) != nil { moved += 1 } else { skipped += 1 }
            }
            return (moved, skipped)
        }.value
        let before = group.size
        if let i = groups.firstIndex(where: { $0.id == group.id }) {
            let size = group.kind == .oldInstallers ? 0
                : await Task.detached(priority: .background) { folders.reduce(Int64(0)) { $0 + DiskScanner.directorySize($1) } }.value
            withAnimation(.smooth) { groups[i].size = size; groups[i].files = [] }
            ActivityLog.record(.freed, bytes: max(0, before - size))
            message = "Moved \(moved) item\(moved == 1 ? "" : "s") (\(formatBytes(max(0, before - size)))) to the Trash"
                + (skipped > 0 ? ", skipped \(skipped) in use." : ".") + " Empty the Trash to get the space back."
        }
        busyGroup = nil
    }

    /// Spotlight already knows every file's size, so large-file search is instant and costs no disk scan.
    func findLargeFiles() {
        query?.stop()
        if let queryObserver { NotificationCenter.default.removeObserver(queryObserver) }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemFSSize > %lld", Self.largeFileThreshold)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSSize", ascending: false)]
        searchingLarge = true
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.collect(q) }
        }
        query = q
        q.start()
    }

    private func collect(_ q: NSMetadataQuery) {
        q.stop()
        var files: [LargeFile] = []
        for case let item as NSMetadataItem in q.results.prefix(60) {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !Self.isInsidePackage(path) else { continue }
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            files.append(LargeFile(url: URL(fileURLWithPath: path), size: size,
                                   lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
        }
        if SnapshotMode.requested { files = SnapshotMode.sampleLargeFiles }   // never publish real file names
        withAnimation(.smooth) { largeFiles = Array(files.prefix(30)) }
        searchingLarge = false
        query = nil
    }

    /// Files inside Photos/Final Cut/Logic libraries or app bundles must never be trashed on their own.
    nonisolated static let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "fcpbundle",
                                                  "logicx", "band", "imovielibrary", "tvlibrary", "lrlibrary", "aplibrary",
                                                  "pvm", "vmwarevm", "utm", "sparsebundle"]

    nonisolated static func isInsidePackage(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { component in
            guard let dot = component.lastIndex(of: ".") else { return false }
            return packageExtensions.contains(component[component.index(after: dot)...].lowercased())
        }
    }

    func trash(_ file: LargeFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            withAnimation(.smooth) { largeFiles.removeAll { $0.id == file.id } }
            ActivityLog.record(.freed, bytes: file.size)
            message = "Moved “\(file.url.lastPathComponent)” (\(formatBytes(file.size))) to the Trash."
        } catch {
            message = "Couldn’t move “\(file.url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    static func showTrash() {
        NSWorkspace.shared.open(home.appending(path: ".Trash"))
    }
}

struct CleanupView: View {
    @Bindable var model: CleanupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                if !model.needsFullDiskAccess.isEmpty {
                    HStack(spacing: 12) {
                        IconWell(symbol: "lock.shield", tint: Tone.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Some folders are locked by macOS").font(.system(size: 13, weight: .medium))
                            Text("Rows marked Locked need Full Disk Access. Drag Kitesail into the list (or click +), switch it on, then reopen Kitesail.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Add Kitesail…") { DiskScanner.revealAppForFullDiskAccess() }
                    }
                    .panel(padding: 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle(title: "Safe to clear",
                              detail: model.measured ? "\(formatBytes(model.reclaimable)) total" : "Measuring…")
                        .padding(.bottom, 8)
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().padding(.leading, 40) }
                        groupRow(group)
                    }
                }
                .panel()

                VStack(alignment: .leading, spacing: 0) {
                    CardTitle(title: "Large files", detail: "Over 500 MB in your home folder")
                        .padding(.bottom, 8)
                    if model.searchingLarge && model.largeFiles.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking Spotlight…").foregroundStyle(.secondary) }
                            .font(.system(size: 12)).padding(.vertical, 8)
                    } else if model.largeFiles.isEmpty {
                        Text("No files over 500 MB found.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(model.largeFiles.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().padding(.leading, 40) }
                        fileRow(file)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .panel()
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Clean Up")
        .navigationSubtitle(model.measured ? "\(formatBytes(model.reclaimable)) can go safely · everything moves to the Trash first" : "Measuring…")
        .toolbar {
            ToolbarItemGroup {
                Button { CleanupModel.showTrash() } label: { Label("Show Trash", systemImage: "trash") }
                    .help("Open the Trash in Finder to empty it")
                Button {
                    Task { await model.measure() }
                    model.findLargeFiles()
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.measuring)
            }
        }
        .task {
            if !model.measured && !model.measuring { await model.measure() }
        }
        .onAppear { if model.largeFiles.isEmpty { model.findLargeFiles() } }
        .quickLookPreview($model.preview)
        .confirmationDialog("Clear \(model.pendingGroup?.title.lowercased() ?? "")?",
                            isPresented: Binding(get: { model.pendingGroup != nil }, set: { if !$0 { model.pendingGroup = nil } }),
                            presenting: model.pendingGroup) { group in
            Button("Move \(formatBytes(group.size)) to Trash", role: .destructive) { Task { await model.clean(group) } }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(group.detail)
        }
        .confirmationDialog("Move to Trash?",
                            isPresented: Binding(get: { model.pendingFile != nil }, set: { if !$0 { model.pendingFile = nil } }),
                            presenting: model.pendingFile) { file in
            Button("Move “\(file.url.lastPathComponent)” to Trash", role: .destructive) { model.trash(file) }
            Button("Cancel", role: .cancel) {}
        }
        .toast($model.message)
    }

    private func groupRow(_ group: JunkGroup) -> some View {
        HStack(spacing: 12) {
            IconWell(symbol: group.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.system(size: 13, weight: .medium))
                Text(group.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(model.needsFullDiskAccess.contains(group.id) ? "Locked" : model.measured && group.size > 0 ? formatBytes(group.size) : "–")
                .font(.figure(13, weight: .medium))
                .foregroundStyle(group.size > 0 ? .primary : .tertiary)
                .frame(width: 80, alignment: .trailing)
            Group {
                if model.busyGroup == group.id {
                    ProgressView().controlSize(.small)
                } else if group.kind == .reviewOnly {
                    Button("Show") { if let f = group.folders.first { NSWorkspace.shared.open(f) } }
                        .disabled(group.size == 0)
                } else {
                    Button("Clean") { model.pendingGroup = group }
                        .disabled(group.size == 0 || model.busyGroup != nil)
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, Metrics.row)
    }

    private func fileRow(_ file: LargeFile) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail(for: file)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 12)
            Text(formatBytes(file.size)).font(.figure(13, weight: .medium)).frame(width: 80, alignment: .trailing)
            HStack(spacing: 2) {
                iconButton("eye", help: "Quick Look") { model.preview = file.url }
                iconButton("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                iconButton("trash", help: "Move to Trash") { model.pendingFile = file }
            }
        }
        .padding(.vertical, Metrics.row - 2)
    }

    private func detail(for file: LargeFile) -> String {
        let folder = file.url.deletingLastPathComponent().path.replacingOccurrences(of: CleanupModel.home.path, with: "~")
        guard let used = file.lastUsed else { return folder }
        return "\(folder) · opened \(used.formatted(.relative(presentation: .named)))"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
