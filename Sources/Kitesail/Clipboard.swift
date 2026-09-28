import SwiftUI
import AppKit
import Carbon.HIToolbox
import ImageIO

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String?
    var image: Data?             // PNG; kept in memory only
    var thumb: Data?             // ~160 px PNG for the list, so rows never decode full-size images
    var date = Date()
    var source: String?
    var pinned = false

    enum CodingKeys: String, CodingKey { case id, text, date, source, pinned }   // images are never written to disk
}

/// Paste/Maccy-style history. Polls the pasteboard's change counter (cheap integer read) twice a second.
/// Privacy: skips password managers and anything marked concealed; history lives in memory, only pins are saved.
@MainActor @Observable
final class ClipboardHistory {
    var clips: [Clip] = []
    var enabled: Bool = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "clipboardEnabled")
            enabled ? startPolling() : stopPolling()     // off means no wake-ups at all
        }
    }

    /// ⇧⌘V is Paste's default but clashes with "paste as plain text" in some apps, so ⌥⌘V is offered too.
    var useOptionShortcut: Bool = UserDefaults.standard.bool(forKey: "clipboardOptionShortcut") {
        didSet {
            UserDefaults.standard.set(useOptionShortcut, forKey: "clipboardOptionShortcut")
            registerHotkey()
        }
    }
    var shortcutLabel: String { useOptionShortcut ? "⌥⌘V" : "⇧⌘V" }

    static let maxText = 200
    static let maxImages = 5            // worst case ~40 MB of images in memory
    static let maxImageBytes = 8_000_000
    static let ignoredApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                                           "com.apple.Passwords", "com.bitwarden.desktop", "com.lastpass.LastPass"]
    static let concealedTypes: [NSPasteboard.PasteboardType] = [.init("org.nspasteboard.ConcealedType"),
                                                                .init("org.nspasteboard.TransientType"),
                                                                .init("com.agilebits.onepassword")]

    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let pinsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Kitesail/pins.json")

    init() {
        if let data = try? Data(contentsOf: pinsURL), let pins = try? JSONDecoder().decode([Clip].self, from: data) {
            clips = pins
        }
        if enabled { startPolling() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.25
    }

    /// Stops recording for this run only (screenshot mode), without changing the saved preference.
    func pauseRecording() { stopPolling() }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func registerHotkey() {
        HotKey.unregister(id: 1)
        HotKey.register(keyCode: kVK_ANSI_V, modifiers: cmdKey | (useOptionShortcut ? optionKey : shiftKey), id: 1) { [weak self] in
            MainActor.assumeIsolated { if let self { ClipboardPanel.shared.toggle(history: self) } }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard enabled else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, Self.ignoredApps.contains(id) { return }
        if let types = pb.types, types.contains(where: Self.concealedTypes.contains) { return }

        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(Clip(text: String(text.prefix(20_000)), source: front?.localizedName))
        } else if let type = [NSPasteboard.PasteboardType.png, .tiff].first(where: { pb.types?.contains($0) ?? false }),
                  let data = pb.data(forType: type),
                  data.count <= (type == .png ? Self.maxImageBytes : Self.maxImageBytes * 6) {   // size check before any decode
            let source = front?.localizedName
            Task.detached(priority: .utility) { [weak self] in
                guard let png = type == .png ? data : Self.png(data), png.count <= Self.maxImageBytes,
                      let thumb = Self.thumbnail(png) else { return }
                await self?.add(Clip(image: png, thumb: thumb, source: source))
            }
        }
    }

    nonisolated private static func png(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Downsampled straight from the encoded data, never decoding the full image.
    nonisolated private static func thumbnail(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 160,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func add(_ clip: Clip) {
        if let text = clip.text, let i = clips.firstIndex(where: { $0.text == text }) {
            var existing = clips.remove(at: i)
            existing.date = .now
            clips.insert(existing, at: 0)
            return
        }
        clips.insert(clip, at: 0)
        trim()
    }

    private func trim() {
        var texts = 0, images = 0
        clips = clips.filter { c in
            if c.pinned { return true }
            if c.image != nil { images += 1; return images <= Self.maxImages }
            texts += 1
            return texts <= Self.maxText
        }
    }

    func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let text = clip.text { pb.setString(text, forType: .string) }
        else if let image = clip.image { pb.setData(image, forType: .png) }
        lastChange = pb.changeCount                        // don't re-record our own write
        if let i = clips.firstIndex(where: { $0.id == clip.id }), !clip.pinned {
            var moved = clips.remove(at: i)
            moved.date = .now
            clips.insert(moved, at: 0)
        }
    }

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].pinned.toggle()
        savePins()
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        savePins()
    }

    func clearHistory() {
        clips.removeAll { !$0.pinned }
    }

    private func savePins() {
        let pins = clips.filter { $0.pinned && $0.text != nil }
        try? FileManager.default.createDirectory(at: pinsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pins).write(to: pinsURL, options: .atomic)
    }

    func filtered(_ query: String) -> [Clip] {
        let base = query.isEmpty ? clips : clips.filter { $0.text?.localizedCaseInsensitiveContains(query) ?? false }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }
}

// MARK: - Global hotkey (Carbon: works without Accessibility permission)

enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    private static var refsByID: [UInt32: EventHotKeyRef] = [:]

    static func unregister(id: UInt32) {
        if let ref = refsByID.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    static func register(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { HotKey.actions[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x46435454), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref); refsByID[id] = ref }
    }
}

// MARK: - Floating picker (⇧⌘V)

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardPanel {
    static let shared = ClipboardPanel()
    private var panel: KeyablePanel?
    private var resignObserver: NSObjectProtocol?

    /// Auto-paste needs Accessibility; without it, Kitesail copies and you press ⌘V.
    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    static func requestAutoPaste() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func toggle(history: ClipboardHistory) {
        if panel?.isVisible == true { close(); return }
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: ClipboardPicker(history: history,
                                                                pick: { [weak self] clip in self?.pick(clip, history: history) },
                                                                dismiss: { [weak self] in self?.close() }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - 220, y: f.midY - 200)) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func pick(_ clip: Clip, history: ClipboardHistory) {
        history.copy(clip)
        close()
        guard Self.canAutoPaste else { return }
        // The panel never activated Kitesail, so ⌘V lands in the app you were typing in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}

struct ClipboardPicker: View {
    let history: ClipboardHistory
    let pick: (Clip) -> Void
    let dismiss: () -> Void
    @Local private var query = ""
    @Local private var index = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = Array(history.filtered(query).prefix(50))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { if items.indices.contains(index) { pick(items[index]) } }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, clip in
                            ClipRow(clip: clip, selected: i == index)
                                .id(clip.id)
                                .onTapGesture { pick(clip) }
                        }
                        if items.isEmpty {
                            Text(history.clips.isEmpty ? "Copy something and it shows up here." : "No matches.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: index) { _, i in if items.indices.contains(i) { proxy.scrollTo(items[i].id) } }
            }
            Divider()
            Text(ClipboardPanel.canAutoPaste ? "↩ paste · esc close" : "↩ copy, then ⌘V · esc close")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
        }
        .frame(width: 440, height: 480)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }
}

struct ClipRow: View {
    let clip: Clip
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let data = clip.thumb, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 32).clipShape(.rect(cornerRadius: 4))
                } else {
                    Image(systemName: clip.pinned ? "pin.fill" : "text.alignleft")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.text ?? "Image").font(.system(size: 12)).lineLimit(2)
                Text([clip.source, clip.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }
}

struct ClipboardView: View {
    let history: ClipboardHistory
    @Local private var query = ""
    @Local private var trusted = ClipboardPanel.canAutoPaste
    @Local private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HStack(alignment: .top, spacing: 12) {
                    IconWell(symbol: "keyboard")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Press \(history.shortcutLabel) anywhere to open your clipboard history").font(.system(size: 13, weight: .semibold))
                        Text(trusted ? "Picking an item pastes it straight into the app you were using."
                             : "Picking an item copies it; press ⌘V to paste. Allow Accessibility to paste automatically.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !trusted { Button("Allow Accessibility…") { ClipboardPanel.requestAutoPaste() } }
                    Toggle("Record clipboard history", isOn: Binding(get: { history.enabled }, set: { history.enabled = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .help("Record clipboard history")
                }
                .panel()
                HStack {
                    Text("Shortcut").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Shortcut", selection: Binding(get: { history.useOptionShortcut }, set: { history.useOptionShortcut = $0 })) {
                        Text("⇧⌘V").tag(false)
                        Text("⌥⌘V  (keeps ⇧⌘V for “paste as plain text”)").tag(true)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        CardTitle(title: "History", detail: "Skips password managers and copies marked secret · history stays in memory, only pins are saved")
                    }
                    .padding(.bottom, 8)
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.bottom, 8)
                    let items = history.filtered(query)
                    if items.isEmpty {
                        Text(!history.enabled ? "History is off. Turn it on to start recording."
                             : query.isEmpty ? "Nothing copied yet." : "No matches for “\(query)”.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, clip in
                        if i > 0 { Divider() }
                        HStack(spacing: 8) {
                            ClipRow(clip: clip)
                            Button { history.copy(clip) } label: { Image(systemName: "doc.on.doc").frame(width: 26, height: 26) }
                                .buttonStyle(.borderless).help("Copy")
                            Button { history.togglePin(clip) } label: { Image(systemName: clip.pinned ? "pin.slash" : "pin").frame(width: 26, height: 26) }
                                .buttonStyle(.borderless).help(clip.pinned ? "Unpin" : "Pin (kept forever)")
                            Button { history.delete(clip) } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                                .buttonStyle(.borderless).help("Remove")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .panel()
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Clipboard")
        .navigationSubtitle("\(plural(history.clips.count, "item")) · \(history.clips.filter(\.pinned).count) pinned")
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear History", systemImage: "xmark.bin") }
                    .help("Clear everything except pins")
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clearHistory() }
        } message: {
            Text("Pinned items stay.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = ClipboardPanel.canAutoPaste
        }
    }
}
