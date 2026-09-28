import SwiftUI
import AppKit
import CoreGraphics
import VirtualDisplayPrivate

struct DisplayMode: Identifiable, Hashable {
    let mode: CGDisplayMode
    var id: Int32 { mode.ioDisplayModeID }
    var width: Int { mode.width }
    var height: Int { mode.height }
    var pixelWidth: Int { mode.pixelWidth }
    var refresh: Double { mode.refreshRate }
    var hiDPI: Bool { mode.pixelWidth > mode.width }
    var resolutionKey: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }

    static func == (a: DisplayMode, b: DisplayMode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let sizeMM: CGSize
    let modes: [DisplayMode]
    let current: DisplayMode?

    var nativePixels: CGSize {
        let best = modes.max { $0.pixelWidth < $1.pixelWidth }
        return CGSize(width: best?.pixelWidth ?? 0, height: best?.mode.pixelHeight ?? 0)
    }
    var diagonalInches: Double { hypot(sizeMM.width, sizeMM.height) / 25.4 }
    var ppi: Double { sizeMM.width > 0 ? nativePixels.width / (sizeMM.width / 25.4) : 0 }

    /// One representative per resolution (HiDPI first), largest first.
    var resolutions: [DisplayMode] {
        var seen = Set<String>()
        return modes
            .filter { $0.hiDPI || $0.width >= 1280 }
            .sorted { ($0.width, $0.hiDPI ? 1 : 0) > ($1.width, $1.hiDPI ? 1 : 0) }
            .filter { seen.insert($0.resolutionKey).inserted }
    }

    func refreshRates(for key: String) -> [Double] {
        Array(Set(modes.filter { $0.resolutionKey == key }.map { $0.refresh.rounded() })).sorted(by: >)
    }

    /// 2x rendering needs 2x the native pixels; beyond ~4K wide that's past what the GPU will scan out.
    var canBoost: Bool { !isBuiltin && nativePixels.width > 0 && nativePixels.width < 3840 }

    /// "Looks like" sizes for the booster: native, then progressively larger text. Even numbers, native aspect.
    var boostPresets: [CGSize] {
        let w = nativePixels.width, h = nativePixels.height
        guard w > 0, h > 0 else { return [] }
        var seen = Set<Int>()
        return [1.0, 0.9, 0.8, 0.75, 2.0 / 3.0].compactMap { f in
            let pw = Int((w * f / 8).rounded()) * 8
            let ph = Int((Double(pw) * h / w / 2).rounded()) * 2
            guard pw >= 1280, seen.insert(pw).inserted else { return nil }
            return CGSize(width: pw, height: ph)
        }
    }
}

struct DDCLevel {
    var current: UInt16
    var max: UInt16
}

struct DDCValues {
    var brightness: DDCLevel?
    var contrast: DDCLevel?
    var volume: DDCLevel?
    var input: UInt16?
    var responds: Bool { brightness != nil || contrast != nil || volume != nil }
}

struct PendingChange {
    let label: String
    let deadline: Date
    let revert: @MainActor () -> Void
    var commit: (@MainActor () -> Void)? = nil
}

struct BoostState {
    let physical: CGDirectDisplayID
    let looksLike: CGSize
}

@MainActor @Observable
final class DisplayModel {
    static let virtualVendor: UInt32 = 0xFACE
    static let revertSeconds = 15.0

    var displays: [DisplayInfo] = []
    var boost: BoostState?
    var pending: PendingChange?
    var message: String?
    var busy = false
    var bolderText: Bool = FontSmoothing.isBolder {
        didSet { FontSmoothing.isBolder = bolderText }
    }

    @ObservationIgnored private var names: [CGDirectDisplayID: String] = [:]
    @ObservationIgnored private var virtualDisplay: CGVirtualDisplay?
    @ObservationIgnored private var revertTask: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    @ObservationIgnored private var pendingWrites: [String: Task<Void, Never>] = [:]
    var ddc: [CGDirectDisplayID: DDCValues] = [:]
    var ddcProbed = false

    init() {
        reload()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    private static let modeOptions = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary

    func reload() {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[id] = screen.localizedName
            }
        }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count))
            .filter { CGDisplayVendorNumber($0) != Self.virtualVendor && $0 != virtualDisplay?.displayID }
            .map { id in
                let modes = ((CGDisplayCopyAllDisplayModes(id, Self.modeOptions) as? [CGDisplayMode]) ?? [])
                    .filter { $0.isUsableForDesktopGUI() }
                    .map(DisplayMode.init)
                return DisplayInfo(
                    id: id,
                    name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display"),
                    isBuiltin: CGDisplayIsBuiltin(id) != 0,
                    sizeMM: CGDisplayScreenSize(id),
                    modes: modes,
                    current: CGDisplayCopyDisplayMode(id).map(DisplayMode.init))
            }
            .sorted { !$0.isBuiltin && $1.isBuiltin }
    }

    // MARK: Resolution & refresh

    func apply(resolution key: String, refresh: Double?, on display: DisplayInfo) {
        let candidates = display.modes.filter { $0.resolutionKey == key }
        let wanted = refresh ?? display.current?.refresh.rounded() ?? 0
        guard let mode = candidates.first(where: { $0.refresh.rounded() == wanted })
                ?? candidates.max(by: { $0.refresh < $1.refresh }) else { return }
        guard mode != display.current else { return }
        let previous = display.current
        // Trial first: `.forAppOnly` is undone by macOS itself if Kitesail quits or crashes before you press Keep,
        // so a mode the monitor can't show can never stick. Keep re-applies it permanently.
        guard configure(display.id, to: mode, .forAppOnly) else { return }
        if let previous {
            armRevert("\(mode.width) × \(mode.height) @ \(Int(mode.refresh.rounded())) Hz",
                      revert: { [weak self] in _ = self?.configure(display.id, to: previous, .forAppOnly) },
                      commit: { [weak self] in _ = self?.configure(display.id, to: mode, .permanently) })
        }
    }

    @discardableResult
    private func configure(_ id: CGDirectDisplayID, to mode: DisplayMode, _ option: CGConfigureOption) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode.mode, nil)
        let ok = CGCompleteDisplayConfiguration(config, option) == .success
        if !ok { message = "macOS rejected that mode." }
        reload()
        return ok
    }

    // MARK: Hardware control over DDC/CI (external monitors)

    /// Pairs external displays with Apple Silicon AV services in order, then reads current levels.
    func probeDDC() async {
        let externals = displays.filter { !$0.isBuiltin }.sorted { CGDisplayUnitNumber($0.id) < CGDisplayUnitNumber($1.id) }
        guard !externals.isEmpty else { ddcProbed = true; return }
        let found = await Task.detached(priority: .userInitiated) { DDCChannel.externalChannels() }.value
        var map: [CGDirectDisplayID: DDCChannel] = [:]
        for (display, channel) in zip(externals, found) { map[display.id] = channel }
        channels = map
        for (id, channel) in map {
            let values = await Task.detached(priority: .userInitiated) { () -> DDCValues in
                func level(_ c: VCP) -> DDCLevel? { channel.read(c).map { DDCLevel(current: $0.current, max: $0.max) } }
                return DDCValues(brightness: level(.brightness), contrast: level(.contrast), volume: level(.volume),
                                 input: channel.read(.input).map { $0.current & 0xFF })
            }.value
            ddc[id] = values
        }
        ddcProbed = true
    }

    /// Updates the UI immediately and sends only the latest value once the slider settles for 60 ms.
    func setDDC(_ code: VCP, _ value: UInt16, on display: CGDirectDisplayID) {
        guard let channel = channels[display] else { return }
        switch code {
        case .brightness: ddc[display]?.brightness?.current = value
        case .contrast: ddc[display]?.contrast?.current = value
        case .volume: ddc[display]?.volume?.current = value
        case .input: ddc[display]?.input = value
        }
        let key = "\(display)-\(code.rawValue)"
        pendingWrites[key]?.cancel()
        pendingWrites[key] = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            _ = channel.write(code, value)
        }
    }

    // MARK: HiDPI Booster

    /// Creates a private virtual display at 2x the chosen "looks like" size with HiDPI on, then mirrors the real
    /// monitor to it. macOS renders everything at 2x and downsamples onto the panel, the same trick BetterDisplay uses.
    func enableBoost(on display: DisplayInfo, looksLike size: CGSize) async {
        disableBoost()
        busy = true
        defer { busy = false }

        let w = UInt32(size.width) * 2, h = UInt32(size.height) * 2
        let refresh = max(display.current?.refresh ?? 60, 60)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Kitesail HiDPI"
        descriptor.vendorID = Self.virtualVendor
        descriptor.productID = 0x0001
        descriptor.serialNum = display.id
        descriptor.maxPixelsWide = w
        descriptor.maxPixelsHigh = h
        descriptor.sizeInMillimeters = display.sizeMM == .zero ? CGSize(width: 600, height: 340) : display.sizeMM
        descriptor.terminationHandler = { _ in }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: w, height: h, refreshRate: refresh),
                          CGVirtualDisplayMode(width: w / 2, height: h / 2, refreshRate: refresh)]

        guard let virtual = CGVirtualDisplay(descriptor: descriptor), virtual.apply(settings) else {
            message = "macOS didn’t allow a virtual display here."
            return
        }
        virtualDisplay = virtual
        let vid = virtual.displayID

        // The virtual display comes online asynchronously.
        var hidpiMode: CGDisplayMode?
        for _ in 0..<30 {
            let modes = (CGDisplayCopyAllDisplayModes(vid, Self.modeOptions) as? [CGDisplayMode]) ?? []
            hidpiMode = modes.first { $0.width == Int(size.width) && $0.pixelWidth == Int(w) }
            if hidpiMode != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let hidpiMode else {
            message = "The GPU didn’t offer a \(Int(w)) × \(Int(h)) HiDPI mode. Try a smaller size."
            disableBoost()
            return
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, vid, hidpiMode, nil)
        CGConfigureDisplayMirrorOfDisplay(config, display.id, vid)
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            message = "Mirroring to the HiDPI canvas failed."
            disableBoost()
            return
        }
        boost = BoostState(physical: display.id, looksLike: size)
        reload()
        armRevert("HiDPI \(Int(size.width)) × \(Int(size.height))") { [weak self] in self?.disableBoost() }
    }

    func disableBoost() {
        guard let boost else { virtualDisplay = nil; return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayMirrorOfDisplay(config, boost.physical, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .forSession)
        virtualDisplay = nil  // releasing it removes the virtual display
        self.boost = nil
        reload()
    }

    // MARK: Safety net: every change reverts unless confirmed, like System Settings.

    private func armRevert(_ label: String, revert: @escaping @MainActor () -> Void, commit: (@MainActor () -> Void)? = nil) {
        revertTask?.cancel()
        pending = PendingChange(label: label, deadline: .now + Self.revertSeconds, revert: revert, commit: commit)
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.revertSeconds))
            guard !Task.isCancelled else { return }
            self?.revertNow()
        }
    }

    func keep() {
        revertTask?.cancel()
        let change = pending
        pending = nil
        change?.commit?()
    }

    func revertNow() {
        revertTask?.cancel()
        let change = pending
        pending = nil
        change?.revert()
    }
}

/// `AppleFontSmoothing` = 2 draws heavier glyph stems, which reads crisper on 1x panels. Apps pick it up on relaunch.
enum FontSmoothing {
    private static let key = "AppleFontSmoothing" as CFString

    static var isBolder: Bool {
        get {
            (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int) == 2
        }
        set {
            CFPreferencesSetValue(key, newValue ? 2 as CFNumber : nil,
                                  kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }
}
