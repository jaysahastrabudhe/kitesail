import SwiftUI
import AppKit

@main
struct KitesailApp: App {
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage(Prefs.alerts) private var alerts = false
    @Local private var store = Store()
    private var watchdog: Watchdog { store.watchdog }

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
        if !SnapshotMode.requested { Launches.record() }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Support Kitesail…") { Support.open() }
                Button("Show Setup on Next Launch") { UserDefaults.standard.set(false, forKey: "onboardingDone") }
            }
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarPanel(model: watchdog)
        } label: {
            Label("\(watchdog.usedPercent)%", systemImage: "memorychip")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Form {
                Toggle("Show memory in the menu bar", isOn: $showMenuBarItem)
                Toggle("Notify me when memory is tight", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { Watchdog.requestNotifications() } }
                Section {
                    Button("Support Kitesail on Buy Me a Coffee…") { Support.open() }
                } footer: {
                    Text("Kitesail is free and open source. If it helps you, a coffee keeps it going.")
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Navigation

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case overview, disk, cleanup, duplicates, uninstaller, memory, apps, energy, startup, display, clipboard
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"; case .disk: "Disk Map"; case .cleanup: "Clean Up"
        case .duplicates: "Duplicates"; case .uninstaller: "Uninstaller"
        case .memory: "Memory"; case .apps: "Apps"; case .energy: "Energy"; case .startup: "Startup"
        case .display: "Display"; case .clipboard: "Clipboard"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"; case .disk: "square.grid.3x3.square"
        case .cleanup: "sparkles"; case .duplicates: "doc.on.doc"; case .uninstaller: "shippingbox"
        case .memory: "memorychip"; case .apps: "square.stack.3d.up"
        case .energy: "bolt"; case .startup: "power"; case .display: "display"; case .clipboard: "list.clipboard"
        }
    }
}

/// Every model lives for the app's lifetime, not the window's: closing the window must not drop an active
/// HiDPI boost, leak observers, or orphan scans. Scans are cancelled explicitly when the window goes away.
@MainActor
final class Store {
    let watchdog = Watchdog()
    let energy = EnergyModel()
    let startup = StartupModel()
    let duplicates = DuplicatesModel()
    let uninstaller = UninstallerModel()
    let disk = DiskModel()
    let cleanup = CleanupModel()
    let memory = MemoryModel()
    let display = DisplayModel()
}

struct RootView: View {
    let store: Store
    @Local private var pane: Pane? = .overview
    @Local private var paletteOpen = false
    @AppStorage("onboardingDone") private var onboardingDone = false
    @AppStorage("donatePromptShown") private var donatePromptShown = false
    /// One sheet slot: two `.sheet` modifiers on the same view can stop one of them from ever presenting.
    enum StartSheet: String, Identifiable { case onboarding, donate; var id: String { rawValue } }
    @Local private var startSheet: StartSheet?

    private var watchdog: Watchdog { store.watchdog }
    private var energy: EnergyModel { store.energy }
    private var startup: StartupModel { store.startup }
    private var duplicates: DuplicatesModel { store.duplicates }
    private var uninstaller: UninstallerModel { store.uninstaller }
    private var disk: DiskModel { store.disk }
    private var cleanup: CleanupModel { store.cleanup }
    private var memory: MemoryModel { store.memory }
    private var display: DisplayModel { store.display }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label(Pane.overview.title, systemImage: Pane.overview.symbol).tag(Pane.overview)
                Section("Storage") {
                    row(.disk)
                    row(.cleanup, detail: cleanup.measured && cleanup.reclaimable > 0 ? formatBytes(cleanup.reclaimable) : nil)
                    row(.duplicates)
                    row(.uninstaller)
                }
                Section("Performance") {
                    row(.memory, detail: watchdog.snapshot.map { formatGB($0.used) })
                    row(.apps)
                    row(.energy)
                    row(.startup)
                }
                Section("Tools") {
                    row(.display)
                    row(.clipboard)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    SupportRow().padding(.horizontal, 12).padding(.bottom, 4)
                    StorageFooter(volume: disk.volume)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch pane ?? .overview {
                case .overview: OverviewView(disk: disk, cleanup: cleanup, memory: memory, display: display, watchdog: watchdog, pane: $pane)
                case .disk: DiskView(model: disk)
                case .cleanup: CleanupView(model: cleanup)
                case .duplicates: DuplicatesView(model: duplicates)
                case .uninstaller: UninstallerView(model: uninstaller)
                case .memory: MemoryView(model: memory)
                case .apps: AppsView(watchdog: watchdog)
                case .energy: EnergyView(model: energy, awake: watchdog.awake)
                case .startup: StartupView(model: startup)
                case .display: DisplayView(model: display)
                case .clipboard: ClipboardView(history: watchdog.clipboard)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Translucent window: the desktop shows through, blurred, like MonoCode. Costs nothing, the window server draws it.
        .containerBackground(.thinMaterial, for: .window)
        .overlay {
            if paletteOpen {
                CommandPalette(commands: commands, dismiss: { withAnimation(.snappy(duration: 0.15)) { paletteOpen = false } })
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background {
            Button("Command Palette") { withAnimation(.snappy(duration: 0.15)) { paletteOpen.toggle() } }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .task {
            if SnapshotMode.requested {
                await SnapshotMode.runIfRequested(select: { pane = $0 }, disk: disk, clipboard: watchdog.clipboard)
            } else if !onboardingDone {
                startSheet = .onboarding                   // one setup sheet for every permission
            } else if !donatePromptShown, Launches.count >= Launches.askOnLaunch {
                try? await Task.sleep(for: .seconds(3))    // let people settle in before asking
                startSheet = .donate
                donatePromptShown = true
            }
            // `--capture-once <file>`: normal launch, then one window capture after 7 s (used to verify first-run UI).
            if let i = CommandLine.arguments.firstIndex(of: "--capture-once"), i + 1 < CommandLine.arguments.count {
                try? await Task.sleep(for: .seconds(7))
                let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                SnapshotMode.capture(to: out)
                let list = NSApp.windows.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible) sheet=\($0.isSheet) attached=\($0.attachedSheet != nil)" }
                try? list.joined(separator: "\n").write(to: out.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                if let sheet = NSApp.windows.compactMap(\.attachedSheet).first {
                    SnapshotMode.captureWindow(sheet, to: out.deletingPathExtension().appendingPathExtension("sheet.png"))
                }
                NSApp.terminate(nil)
            }
        }
        .sheet(item: $startSheet, onDismiss: { onboardingDone = true }) { sheet in
            switch sheet {
            case .onboarding: OnboardingSheet(finish: { onboardingDone = true; startSheet = nil })
            case .donate: DonateSheet(dismiss: { startSheet = nil })
            }
        }
        .onDisappear {
            disk.cancelScan()
            duplicates.cancel()
        }
    }

    private var commands: [PaletteCommand] {
        var list: [PaletteCommand] = Pane.allCases.map { p in
            PaletteCommand(id: "go-\(p.rawValue)", title: "Go to \(p.title)", symbol: p.symbol, run: { pane = p })
        }
        let awake = watchdog.awake
        let guardOn = UserDefaults.standard.bool(forKey: Prefs.guardOn)
        list += [
            PaletteCommand(id: "clipboard", title: "Clipboard History", subtitle: watchdog.clipboard.shortcutLabel, symbol: "list.clipboard",
                           run: { ClipboardPanel.shared.toggle(history: watchdog.clipboard) }),
            PaletteCommand(id: "awake60", title: "Keep Awake for 1 Hour", subtitle: "caffeinate", symbol: "cup.and.saucer",
                           run: { awake.start(minutes: 60) }),
            PaletteCommand(id: "awakeOn", title: "Keep Awake Until Turned Off", subtitle: "caffeinate", symbol: "cup.and.saucer.fill",
                           run: { awake.start(minutes: nil) }),
            PaletteCommand(id: "guard", title: guardOn ? "Turn Off Memory Guard" : "Turn On Memory Guard", subtitle: "auto-quit idle apps under pressure",
                           symbol: "shield.lefthalf.filled", run: { UserDefaults.standard.set(!guardOn, forKey: Prefs.guardOn) }),
            PaletteCommand(id: "dups", title: "Find Duplicate Files", symbol: "doc.on.doc", run: { pane = .duplicates; duplicates.scan() }),
            PaletteCommand(id: "caches", title: "Clean App Caches", subtitle: "asks first", symbol: "sparkles", run: {
                pane = .cleanup
                if cleanup.measured, cleanup.busyGroup == nil, let g = cleanup.groups.first(where: { $0.id == "caches" }), g.size > 0 {
                    cleanup.pendingGroup = g
                }
            }),
            PaletteCommand(id: "purge", title: "Flush File Cache", subtitle: "purge, needs your password", symbol: "wind", run: { memory.purge() }),
            PaletteCommand(id: "rescan", title: "Rescan Disk Map", symbol: "arrow.clockwise", run: { pane = .disk; disk.scan(force: true) }),
            PaletteCommand(id: "quitall", title: "Quit All Apps", subtitle: "keeps your keep list", symbol: "xmark.circle",
                           needsQuery: true, run: {
                let alert = NSAlert()
                alert.messageText = "Quit \(plural(watchdog.quitCandidates().count, "app"))?"
                alert.informativeText = "Apps with unsaved work will ask before closing. Your keep list stays open."
                alert.addButton(withTitle: "Quit All")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { watchdog.quitAll() }
            }),
        ]
        if awake.isOn {
            list.insert(PaletteCommand(id: "awakeOff", title: "Stop Keep Awake", symbol: "moon.zzz", run: { awake.stop() }), at: 0)
        }
        for app in watchdog.quitCandidates() {
            let name = app.localizedName ?? "App"
            list.append(PaletteCommand(id: "quit-\(app.processIdentifier)", title: "Quit \(name)", symbol: "xmark.app",
                                       needsQuery: true, run: { app.terminate() }))
        }
        for app in uninstaller.apps {
            list.append(PaletteCommand(id: "uninstall-\(app.bundleID)", title: "Uninstall \(app.name)", subtitle: "review leftovers first",
                                       symbol: "shippingbox", needsQuery: true, run: {
                pane = .uninstaller
                Task { await uninstaller.select(app.id) }
            }))
        }
        return list
    }

    /// Trailing detail is drawn inside the row (not `.badge`): a changing badge made the row drop its selection highlight.
    private func row(_ p: Pane, detail: String? = nil) -> some View {
        HStack {
            Label(p.title, systemImage: p.symbol)
            Spacer(minLength: 4)
            Text(detail ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(p)
    }
}

struct StorageFooter: View {
    let volume: (total: Int64, available: Int64)?

    var body: some View {
        if let v = volume {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(bootVolumeName).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(formatBytes(v.available)) free").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                UsageBar(fraction: 1 - Double(v.available) / Double(max(v.total, 1)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Design system
//
// Monochrome, native-first (after MonoCode): system type at 13 pt, SF Symbols in monochrome, one card style,
// an 4/8/12/16/20 spacing scale, and color reserved for status and data.

/// Command Line Tools ship without the SwiftUI macro plugin, so use the property-wrapper type directly
/// instead of the `@State` macro.
typealias Local<Value> = SwiftUICore.State<Value>

enum Metrics {
    static let page: CGFloat = 20      // outer page padding
    static let gap: CGFloat = 16       // between cards
    static let card: CGFloat = 16      // inside cards
    static let row: CGFloat = 8        // vertical padding of list rows inside cards
    static let radius: CGFloat = 12
}

/// "1 app", "3 apps".
func plural(_ n: Int, _ word: String, _ pluralWord: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? word : (pluralWord ?? word + "s"))"
}

/// The boot volume's real name (many Macs have renamed "Macintosh HD").
let bootVolumeName: String = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?
    .volumeLocalizedName ?? "Macintosh HD"

/// One toast style everywhere: bottom-centre glass capsule, auto-dismiss after 5 s.
struct Toast: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { self.message = nil }
                    }
            }
        }
        .animation(.smooth, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View { modifier(Toast(message: message)) }
}

enum Tone {
    static let good = Color(hex: 0x5FD08A)
    static let warn = Color(hex: 0xF2B64C)
    static let bad = Color(hex: 0xF0645E)
}

private struct AccentKey: EnvironmentKey { static let defaultValue: Color = .primary }

extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

struct Card: ViewModifier {
    var padding: CGFloat = Metrics.card
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }
}

extension View {
    func panel(padding: CGFloat = Metrics.card) -> some View { modifier(Card(padding: padding)) }
}

/// Small card heading: 13 pt semibold, optional trailing detail.
struct CardTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}

/// Symbol in a fixed square so rows line up regardless of glyph width.
struct IconWell: View {
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7, style: .continuous))
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color? = nil
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint ?? (fraction > 0.9 ? Tone.bad : fraction > 0.8 ? Tone.warn : Color.primary.opacity(0.7)))
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
        }
        .frame(height: 4)
    }
}

func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func formatGB(_ value: UInt64) -> String {
    String(format: "%.1f GB", Double(value) / 1_073_741_824)
}

// MARK: - Snapshot mode

/// `Kitesail --snapshot <dir>`: opens each pane, renders the window's own view hierarchy to PNG, then quits.
/// Lets layout be reviewed without Screen Recording permission (materials render flat).
enum SnapshotMode {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    /// Stand-in data for screens that would otherwise show personal files or clipboard contents in public screenshots.
    static var sampleLargeFiles: [LargeFile] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        let day = 86_400.0
        return [("Movies/Travel Edit 4K Export.mov", 6_400_000_000, 40.0), ("Downloads/Xcode_26.xip", 3_100_000_000, 120.0),
                ("Downloads/Windows 11 ARM.iso", 2_700_000_000, 200.0), ("Documents/Archive/Photos 2023.zip", 1_900_000_000, 400.0),
                ("Movies/Screen Recording 2026-08-14.mov", 1_300_000_000, 45.0), ("Downloads/Figma-Installer.dmg", 620_000_000, 90.0)]
            .map { LargeFile(url: h.appending(path: $0.0), size: $0.1, lastUsed: Date.now.addingTimeInterval(-$0.2 * day)) }
    }

    @MainActor
    static func loadSampleClips(into history: ClipboardHistory) {
        history.clips = [
            Clip(text: "https://developer.apple.com/documentation/swiftui", date: .now.addingTimeInterval(-40), source: "Safari"),
            Clip(text: "Launch checklist: screenshots, release notes, DMG, announce", date: .now.addingTimeInterval(-300), source: "Notes", pinned: true),
            Clip(text: "#1F1F24", date: .now.addingTimeInterval(-900), source: "Figma"),
            Clip(text: "git log --oneline --graph --decorate", date: .now.addingTimeInterval(-1800), source: "Terminal"),
            Clip(text: "Let's meet Thursday at 4 to review the new onboarding flow.", date: .now.addingTimeInterval(-3600), source: "Mail"),
        ]
    }

    @MainActor
    static func runIfRequested(select: (Pane) -> Void, disk: DiskModel, clipboard: ClipboardHistory) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        clipboard.pauseRecording()          // temporary; the saved preference is untouched
        NSApp.activate()                     // active-window styling: accent switches, selected sidebar row
        NSApp.windows.forEach { $0.ignoresMouseEvents = true }   // nobody can steer it mid-capture
        loadSampleClips(into: clipboard)
        let dir = URL(fileURLWithPath: args[i + 1])
        try? await Task.sleep(for: .seconds(1.5))
        for p in Pane.allCases {
            NSApp.activate()
            select(p)
            try? await Task.sleep(for: .seconds(p == .disk ? 10 : 3))
            capture(to: dir.appending(path: "pane-\(p.rawValue).png"))
        }
        NSApp.terminate(nil)
    }

    /// Window-server capture of our own window (real glass + translucency). The API is obsoleted in the Swift
    /// overlay, so it's looked up at runtime; capturing your own windows needs no Screen Recording permission.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @MainActor
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // .optionIncludingWindow = 8; imageOption .bestResolution = 8
        return create(.null, 8, UInt32(window.windowNumber), 8)?.takeRetainedValue()
    }

    @MainActor
    static func captureWindow(_ window: NSWindow, to url: URL) {
        guard let image = windowServerImage(window) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    static func capture(to url: URL) {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
           let image = windowServerImage(window), image.width > 100 {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path, "(window server)")
            return
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        if let table = findTable(in: view) { print("sidebar rows: \(table.numberOfRows)") }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }

    @MainActor
    private static func findTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = findTable(in: sub) { return t } }
        return nil
    }
}
