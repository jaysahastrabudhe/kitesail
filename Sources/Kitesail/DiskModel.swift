import SwiftUI
import AppKit

struct DiskItem: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    var size: Int64
    let isDirectory: Bool
    var isOther = false
    var id: URL { url }
    var kind: FileKind { isOther ? .other : FileKind(url: url, isDirectory: isDirectory) }
}

enum FileKind: CaseIterable {
    case folder, app, video, image, audio, archive, document, other

    init(url: URL, isDirectory: Bool) {
        let ext = url.pathExtension.lowercased()
        if ext == "app" { self = .app; return }
        if isDirectory { self = .folder; return }
        self = switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "prproj", "braw", "mxf": .video
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "tif", "psd", "raw", "dng", "arw", "cr2", "webp", "svg": .image
        case "mp3", "wav", "aiff", "aif", "m4a", "flac", "aac", "ogg": .audio
        case "zip", "dmg", "pkg", "tar", "gz", "rar", "7z", "xip", "iso", "jar": .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md", "csv": .document
        default: .other
        }
    }

    var label: String {
        switch self {
        case .folder: "Folders"; case .app: "Apps"; case .video: "Video"; case .image: "Images"
        case .audio: "Audio"; case .archive: "Archives"; case .document: "Docs"; case .other: "Other"
        }
    }

    /// Muted data palette: distinct enough to read the map, quiet enough for a monochrome UI.
    var color: Color {
        switch self {
        case .folder: Color(hex: 0x4E8F8A)
        case .app: Color(hex: 0x5A6FB5)
        case .video: Color(hex: 0x7F62A8)
        case .image: Color(hex: 0xA3627F)
        case .audio: Color(hex: 0xAD8250)
        case .archive: Color(hex: 0x9E9150)
        case .document: Color(hex: 0x5F9063)
        case .other: Color(hex: 0x5D6470)
        }
    }
}

enum DiskScanner {
    /// Firmlinked/virtual mounts that would double-count when scanning "/".
    static let skipped: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]
    private static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
    }

    static func item(for url: URL) -> DiskItem? {
        guard !skipped.contains(url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isSymbolicLink == true { return nil }
        let isDir = values?.isDirectory ?? false
        let size = isDir ? directorySize(url) : Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        guard !Task.isCancelled, size > 0 else { return nil }
        return DiskItem(url: url, name: FileManager.default.displayName(atPath: url.path), size: size, isDirectory: isDir)
    }

    /// Streams the tree and keeps only a running total, so RAM stays flat no matter how many files there are.
    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        while true {
            let done: Bool = autoreleasepool {
                guard let file = e.nextObject() as? URL else { return true }
                count += 1
                if e.level == 1, skipped.contains(file.path) { e.skipDescendants(); return false }
                if let v = try? file.resourceValues(forKeys: sizeKeys) {
                    total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                }
                return false
            }
            if done { break }
            if count & 1023 == 0, Task.isCancelled { return 0 }
        }
        return total
    }

    /// Full Disk Access check: these folders exist on every Mac but refuse to list without it.
    /// (The old probe, ~/Library/Application Support/com.apple.TCC/TCC.db, no longer exists on macOS 27.)
    static let protectedProbes = ["Library/Safari", "Library/Mail", "Library/Messages", "Library/Cookies", "Library/Suggestions"]

    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let existing = protectedProbes.map { home.appending(path: $0).path }.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return true }   // nothing protected on this Mac, so nothing to unlock
        return existing.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }

    static func volume(for url: URL) -> (total: Int64, available: Int64)? {
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total), available)
    }

    /// Full Disk Access only lists apps you add yourself, so reveal the app for dragging into the list.
    static func revealAppForFullDiskAccess() {
        openFullDiskAccessSettings()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk). `values` must be sorted descending and > 0.
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], side) <= worst(row, side) {
                row.append(areas[j])
                j += 1
            }
            let thickness = row.reduce(0, +) / side
            var offset = 0.0
            if remaining.width >= remaining.height {
                for a in row {
                    let h = a / thickness
                    result.append(CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: h))
                    offset += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                for a in row {
                    let w = a / thickness
                    result.append(CGRect(x: remaining.minX + offset, y: remaining.minY, width: w, height: thickness))
                    offset += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            i = j
        }
        return result
    }

    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let mx = row.max(), let mn = row.min(), sum > 0, mn > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }
}

struct Shard {
    let rect: CGRect
    let velocity: CGVector
    let spin: Double
}

struct ShatterEvent: Identifiable {
    let id = UUID()
    let color: Color
    let start = Date()
    let shards: [Shard]

    /// Splits the block into a brick grid; each brick bursts outward from the block's center.
    init(rect: CGRect, color: Color) {
        self.color = color
        let cols = min(10, max(3, Int(rect.width / 46)))
        let rows = min(8, max(2, Int(rect.height / 34)))
        let w = rect.width / CGFloat(cols), h = rect.height / CGFloat(rows)
        var shards: [Shard] = []
        for r in 0..<rows {
            // Running bond: odd rows shift half a brick, so they need one extra (clipped) brick.
            let staggered = !r.isMultiple(of: 2)
            for c in 0..<(cols + (staggered ? 1 : 0)) {
                let x = rect.minX + CGFloat(c) * w - (staggered ? w * 0.5 : 0)
                let minX = max(rect.minX, x), maxX = min(rect.maxX, x + w)
                let brick = CGRect(x: minX, y: rect.minY + CGFloat(r) * h, width: maxX - minX, height: h)
                guard brick.width > 1 else { continue }
                let dx = (brick.midX - rect.midX) / max(rect.width, 1)
                let dy = (brick.midY - rect.midY) / max(rect.height, 1)
                shards.append(Shard(
                    rect: brick,
                    velocity: CGVector(dx: dx * 520 + .random(in: -60...60), dy: dy * 260 - .random(in: 160...420)),
                    spin: .random(in: -7...7)))
            }
        }
        self.shards = shards
    }
}

struct PendingTrash {
    let item: DiskItem
    let rect: CGRect
}

@MainActor @Observable
final class DiskModel {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let maxBlocks = 36

    var path: [URL] = [DiskModel.home]
    var items: [DiskItem] = []
    var scanning = false
    var hasFullDiskAccess = DiskScanner.hasFullDiskAccess()
    var error: String?
    var pendingTrash: PendingTrash?
    var preview: URL?
    var shatters: [ShatterEvent] = []
    var freedThisSession: Int64 = 0
    var volume = DiskScanner.volume(for: URL(fileURLWithPath: "/"))

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cache: [URL: [DiskItem]] = [:]

    var current: URL { path.last ?? Self.home }
    var scannedTotal: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Largest items as blocks; the long tail is folded into one "smaller items" block.
    var blocks: [DiskItem] {
        guard items.count > Self.maxBlocks else { return items }
        let head = items.prefix(Self.maxBlocks - 1)
        let tail = items.dropFirst(Self.maxBlocks - 1)
        let other = DiskItem(url: current.appending(path: ".kitesail-other"), name: "\(tail.count) smaller items",
                             size: tail.reduce(0) { $0 + $1.size }, isDirectory: false, isOther: true)
        return (Array(head) + [other]).sorted { $0.size > $1.size }
    }

    func setRoot(_ url: URL) { path = [url]; scan() }

    func cancelScan() {
        scanTask?.cancel()
        scanning = false
    }
    func open(_ item: DiskItem) {
        guard item.isDirectory, !item.isOther else { return }
        path.append(item.url)
        scan()
    }
    func pop(to index: Int) {
        guard index < path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        scan()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Visualize"
        if panel.runModal() == .OK, let url = panel.url { setRoot(url) }
    }

    func scan(force: Bool = false) {
        scanTask?.cancel()
        let url = current
        volume = DiskScanner.volume(for: url)
        if !force, let cached = cache[url] {
            withAnimation(.spring(duration: 0.5)) { items = cached }
            scanning = false
            return
        }
        items = []
        scanning = true
        error = nil
        scanTask = Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) { DiskScanner.children(of: url) }.value
            await withTaskGroup(of: DiskItem?.self) { group in
                for child in children {
                    group.addTask(priority: .userInitiated) { DiskScanner.item(for: child) }
                }
                // Batch results so blocks grow in visible waves instead of thousands of tiny animations.
                var pending: [DiskItem] = []
                var lastFlush = ContinuousClock.now
                for await item in group {
                    guard let self, !Task.isCancelled else { group.cancelAll(); return }
                    if let item { pending.append(item) }
                    if ContinuousClock.now - lastFlush > .milliseconds(160), !pending.isEmpty {
                        self.merge(pending)
                        pending.removeAll()
                        lastFlush = .now
                    }
                }
                self?.merge(pending)
            }
            guard let self, !Task.isCancelled else { return }
            self.scanning = false
            self.cache[url] = self.items
        }
    }

    private func merge(_ new: [DiskItem]) {
        guard !new.isEmpty else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.22)) {
            items = (items + new).sorted { $0.size > $1.size }
        }
    }

    func requestTrash(_ item: DiskItem, rect: CGRect) {
        guard !item.isOther else { return }
        pendingTrash = PendingTrash(item: item, rect: rect)
    }

    /// Moves to Trash (recoverable), then plays the brick-break and lets the treemap reflow into the gap.
    func confirmTrash(_ request: PendingTrash) {
        pendingTrash = nil
        let failed = trash([(request.item, request.rect)])
        if !failed.isEmpty {
            error = "Couldn’t move “\(request.item.name)” to the Trash. \(failed[0])"
        }
    }

    // MARK: Delete basket (collect several blocks, even across folders, then delete in one go)

    struct BasketEntry: Identifiable {
        let item: DiskItem
        let rect: CGRect
        var id: URL { item.id }
    }

    var basket: [BasketEntry] = []
    var basketTotal: Int64 { basket.reduce(0) { $0 + $1.item.size } }

    func inBasket(_ item: DiskItem) -> Bool {
        basket.contains { $0.id == item.id || item.url.path.hasPrefix($0.item.url.path + "/") }
    }

    func toggleBasket(_ item: DiskItem, rect: CGRect) {
        guard !item.isOther else { return }
        withAnimation(.snappy) {
            if let i = basket.firstIndex(where: { $0.id == item.id }) {
                basket.remove(at: i)
            } else if !inBasket(item) {
                // A folder in the basket already covers everything inside it.
                basket.removeAll { $0.item.url.path.hasPrefix(item.url.path + "/") }
                basket.append(BasketEntry(item: item, rect: rect))
            }
        }
    }

    func trashBasket() {
        let entries = basket
        withAnimation(.snappy) { basket = [] }
        let failed = trash(entries.map { ($0.item, $0.rect) })
        if !failed.isEmpty { error = "\(failed.count) item\(failed.count == 1 ? "" : "s") couldn’t be moved: \(failed[0])" }
    }

    /// Trashes items, shatters the ones visible in the current map, reflows. Returns failure messages.
    @discardableResult
    private func trash(_ targets: [(DiskItem, CGRect)]) -> [String] {
        var failures: [String] = []
        var removed: Set<URL> = []
        for (item, rect) in targets {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
                continue
            }
            removed.insert(item.id)
            freedThisSession += item.size
            ActivityLog.record(.freed, bytes: item.size)
            if items.contains(where: { $0.id == item.id }) {
                let event = ShatterEvent(rect: rect, color: item.kind.color)
                shatters.append(event)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.6))
                    self?.shatters.removeAll { $0.id == event.id }
                }
            }
        }
        guard !removed.isEmpty else { return failures }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.spring(duration: 0.7, bounce: 0.2).delay(0.18)) {
            items.removeAll { removed.contains($0.id) }
        }
        // Cached folder sizes elsewhere may include what was deleted.
        cache.removeAll()
        cache[current] = items
        volume = DiskScanner.volume(for: current)
        return failures
    }
}
