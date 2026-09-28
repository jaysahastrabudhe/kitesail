import SwiftUI
import AppKit
import CryptoKit
import QuickLook

struct DupFile: Identifiable, Sendable {
    let url: URL
    let modified: Date
    var id: URL { url }
}

struct DupGroup: Identifiable, Sendable {
    let id = UUID()
    let size: Int64
    var files: [DupFile]
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Size → first 64 KB → full SHA-256. Each stage only reads files that survived the previous one.
enum DuplicateFinder {
    static let minSize: Int64 = 1_048_576   // ignore files under 1 MB: small wins, lots of reads
    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                                    .fileResourceIdentifierKey, .fileContentIdentifierKey]

    static func scan(_ root: URL, progress: @Sendable (Int) -> Void) -> [DupGroup] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return [] }
        var bySize: [Int64: [DupFile]] = [:]
        var seenInodes = Set<String>()   // hard links point at the same file: count once
        var count = 0
        while true {
            let done: Bool = autoreleasepool {
                guard let url = e.nextObject() as? URL else { return true }
                if e.level == 1, url.lastPathComponent == "Library" { e.skipDescendants(); return false }
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                      let size = v.fileSize, Int64(size) >= minSize else { return false }
                if let rid = v.fileResourceIdentifier.map({ "\($0)" }), !seenInodes.insert(rid).inserted { return false }
                bySize[Int64(size), default: []].append(DupFile(url: url, modified: v.contentModificationDate ?? .distantPast))
                return false
            }
            if done || Task.isCancelled { break }
            count += 1
            if count % 500 == 0 { progress(count) }
        }
        var groups: [DupGroup] = []
        for (size, files) in bySize where files.count > 1 {
            if Task.isCancelled { break }
            for partial in grouped(files, size: size, limit: 65_536) {
                for full in grouped(partial, size: size, limit: nil) {
                    // APFS clones share their blocks: deleting one frees nothing, so skip all-clone groups.
                    if isAllClones(full) { continue }
                    groups.append(DupGroup(size: size, files: full.sorted { $0.modified > $1.modified }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// nil if the file can't be read in full (e.g. an iCloud placeholder offline): unreadable files never match.
    static func digest(_ url: URL, limit: Int?, expected: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let target = min(Int64(limit ?? Int.max), expected)
        var read: Int64 = 0
        while read < target {
            let result: Result<Data?, Error> = autoreleasepool {
                Result { try handle.read(upToCount: Int(min(1_048_576, target - read))) }
            }
            guard case .success(let chunk?) = result, !chunk.isEmpty else { return nil }
            hasher.update(data: chunk)
            read += Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func grouped(_ files: [DupFile], size: Int64, limit: Int?) -> [[DupFile]] {
        var buckets: [String: [DupFile]] = [:]
        for f in files { if let d = digest(f.url, limit: limit, expected: size) { buckets[d, default: []].append(f) } }
        return buckets.values.filter { $0.count > 1 }
    }

    static func isAllClones(_ files: [DupFile]) -> Bool {
        let ids = files.compactMap { (try? $0.url.resourceValues(forKeys: [.fileContentIdentifierKey]))?.fileContentIdentifier }
        return ids.count == files.count && Set(ids).count == 1
    }
}

@MainActor @Observable
final class DuplicatesModel {
    var root = FileManager.default.homeDirectoryForCurrentUser
    var groups: [DupGroup] = []
    var scanning = false
    var checked = 0
    var scanned = false
    var message: String?
    var preview: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() {
        task?.cancel()
        scanning = true
        checked = 0
        groups = []
        let root = root
        task = Task { [weak self] in
            let job = Task.detached(priority: .utility) {
                DuplicateFinder.scan(root) { n in Task { @MainActor in self?.checked = n } }
            }
            // Detached work doesn't inherit cancellation; forward Stop to it.
            let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth) { self.groups = found }
            self.scanning = false
            self.scanned = true
        }
    }

    func cancel() { task?.cancel(); scanning = false }

    var rootName: String {
        root.path == CleanupModel.home.path ? "Home Folder" : FileManager.default.displayName(atPath: root.path)
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { root = url; scan() }
    }

    func trash(_ file: DupFile, in group: DupGroup) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            remove([file.id], from: group)
            ActivityLog.record(.freed, bytes: group.size)
            message = "Moved “\(file.url.lastPathComponent)” to the Trash."
        } catch {
            message = "Couldn’t move it: \(error.localizedDescription)"
        }
    }

    /// Keeps the most recently modified copy, trashes the rest.
    func keepNewest(_ group: DupGroup) {
        let extras = group.files.dropFirst()
        var removed: Set<URL> = []
        for f in extras where (try? FileManager.default.trashItem(at: f.url, resultingItemURL: nil)) != nil { removed.insert(f.id) }
        remove(removed, from: group)
        ActivityLog.record(.freed, bytes: group.size * Int64(removed.count))
        message = "Kept the newest copy, moved \(removed.count) to the Trash (\(formatBytes(group.size * Int64(removed.count))))."
    }

    private func remove(_ ids: Set<URL>, from group: DupGroup) {
        withAnimation(.smooth) {
            guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups[i].files.removeAll { ids.contains($0.id) }
            if groups[i].files.count < 2 { groups.remove(at: i) }
        }
    }
}

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @Local private var pendingGroup: DupGroup?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                if model.scanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checked \(model.checked.formatted()) files…").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { model.cancel() }
                    }
                    .panel(padding: 12)
                } else if !model.scanned {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find exact copies of files over 1 MB").font(.system(size: 13, weight: .semibold))
                        Text("Compares size, then the first 64 KB, then the whole file, so it only reads what it must. Skips Library, hidden folders, app bundles and APFS clones (which don't use extra space).")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Scan \(model.rootName)") { model.scan() }.buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                } else if model.groups.isEmpty {
                    HStack(spacing: 12) {
                        IconWell(symbol: "checkmark", tint: Tone.good)
                        Text("No duplicates over 1 MB in \(model.rootName).").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                }
                ForEach(model.groups) { group in groupCard(group) }
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Duplicates")
        .navigationSubtitle(model.scanned ? "\(plural(model.groups.count, "set")) · \(formatBytes(model.wasted)) in extra copies" : "Folder: \(model.rootName)")
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseRoot() } label: { Label("Choose Folder", systemImage: "folder") }
                Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }.disabled(model.scanning)
            }
        }
        .quickLookPreview($model.preview)
        .confirmationDialog("Keep the newest copy?", isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }),
                            presenting: pendingGroup) { group in
            Button("Move \(group.files.count - 1) older cop\(group.files.count == 2 ? "y" : "ies") to Trash", role: .destructive) { model.keepNewest(group) }
        } message: { group in
            Text("Keeps “\(group.files.first?.url.lastPathComponent ?? "")” from \(group.files.first?.url.deletingLastPathComponent().lastPathComponent ?? "").")
        }
        .toast($model.message)
    }

    private func groupCard(_ group: DupGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files[0].url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) copies × \(formatBytes(group.size)) · \(formatBytes(group.wasted)) extra")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Keep Newest") { pendingGroup = group }
            }
            .padding(.bottom, 8)
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                Divider().padding(.leading, 40)
                HStack(spacing: 12) {
                    Text(index == 0 ? "Newest" : "")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tone.good)
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: CleanupModel.home.path, with: "~"))
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                        Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 2) {
                        smallButton("eye", "Quick Look") { model.preview = file.url }
                        smallButton("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        smallButton("trash", "Move this copy to Trash") { model.trash(file, in: group) }
                    }
                }
                .padding(.vertical, Metrics.row - 2)
            }
        }
        .panel()
    }

    private func smallButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(.rect) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }
}
