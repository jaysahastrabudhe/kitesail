import SwiftUI
import AppKit
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Window snapping (Rectangle-style hotkeys, zero background cost: Carbon hotkeys + Accessibility)

enum SnapTarget: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center, firstThird, centerThird, lastThird
    var id: Self { self }

    var title: String {
        switch self {
        case .leftHalf: "Left half"; case .rightHalf: "Right half"; case .topHalf: "Top half"; case .bottomHalf: "Bottom half"
        case .maximize: "Maximize"; case .center: "Center"
        case .firstThird: "First third"; case .centerThird: "Center third"; case .lastThird: "Last third"
        }
    }
    /// ⌃⌥ + key, matching Rectangle's defaults so muscle memory carries over.
    var key: (code: Int, label: String) {
        switch self {
        case .leftHalf: (kVK_LeftArrow, "←"); case .rightHalf: (kVK_RightArrow, "→")
        case .topHalf: (kVK_UpArrow, "↑"); case .bottomHalf: (kVK_DownArrow, "↓")
        case .maximize: (kVK_Return, "↩"); case .center: (kVK_ANSI_C, "C")
        case .firstThird: (kVK_ANSI_D, "D"); case .centerThird: (kVK_ANSI_F, "F"); case .lastThird: (kVK_ANSI_G, "G")
        }
    }

    /// Target frame inside a screen's visible area (top-left origin, like the Accessibility API).
    func frame(in v: CGRect) -> CGRect {
        let w = v.width, h = v.height
        switch self {
        case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: v.minX + w / 2, y: v.minY, width: w / 2, height: h)
        case .topHalf: return CGRect(x: v.minX, y: v.minY, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: v.minX, y: v.minY + h / 2, width: w, height: h / 2)
        case .maximize: return v
        case .center: return CGRect(x: v.minX + w * 0.15, y: v.minY + h * 0.1, width: w * 0.7, height: h * 0.8)
        case .firstThird: return CGRect(x: v.minX, y: v.minY, width: w / 3, height: h)
        case .centerThird: return CGRect(x: v.minX + w / 3, y: v.minY, width: w / 3, height: h)
        case .lastThird: return CGRect(x: v.minX + 2 * w / 3, y: v.minY, width: w / 3, height: h)
        }
    }
}

@MainActor
enum WindowSnapper {
    private static let baseID: UInt32 = 100

    static func setEnabled(_ on: Bool) {
        for (i, t) in SnapTarget.allCases.enumerated() {
            let id = baseID + UInt32(i)
            HotKey.unregister(id: id)
            if on {
                HotKey.register(keyCode: t.key.code, modifiers: controlKey | optionKey, id: id) {
                    MainActor.assumeIsolated { snap(t) }
                }
            }
        }
    }

    static func snap(_ target: SnapTarget) {
        guard AXIsProcessTrusted() else { ClipboardPanel.requestAutoPaste(); return }
        let system = AXUIElementCreateSystemWide()
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let appElement = app else { return }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement as! AXUIElement, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return }
        let w = window as! AXUIElement

        // Find the screen the window is on (Cocoa uses bottom-left origin; AX uses top-left of the main screen).
        guard let primary = NSScreen.screens.first else { return }
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
        let cocoaPoint = CGPoint(x: pos.x + 1, y: primary.frame.height - pos.y - 1)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main ?? primary
        let vf = screen.visibleFrame
        let visibleTopLeft = CGRect(x: vf.minX, y: primary.frame.height - vf.maxY, width: vf.width, height: vf.height)

        let rect = target.frame(in: visibleTopLeft)
        var origin = rect.origin, size = rect.size
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }   // again, after the move
    }
}

// MARK: - Menu bar tidy (Hidden Bar technique: a divider item that stretches to push icons off-screen)

@MainActor
final class MenuBarTidy {
    static let shared = MenuBarTidy()
    private var toggle: NSStatusItem?
    private var divider: NSStatusItem?
    private var collapseTask: Task<Void, Never>?
    private(set) var collapsed = true
    private static let hiddenLength: CGFloat = 10_000

    func setEnabled(_ on: Bool) {
        if on {
            guard toggle == nil else { return }
            // Created first = rightmost. Icons you ⌘-drag to the LEFT of the divider get hidden.
            let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            t.autosaveName = "KitesailTidyToggle"
            t.button?.target = self
            t.button?.action = #selector(toggleTapped)
            let d = NSStatusBar.system.statusItem(withLength: 8)
            d.autosaveName = "KitesailTidyDivider"
            d.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Kitesail divider")
            d.button?.appearsDisabled = true
            toggle = t
            divider = d
            setCollapsed(true)
        } else {
            collapseTask?.cancel()
            if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
            if let divider { NSStatusBar.system.removeStatusItem(divider) }
            toggle = nil
            divider = nil
        }
    }

    @objc private func toggleTapped() { setCollapsed(!collapsed) }

    private func setCollapsed(_ c: Bool) {
        collapsed = c
        divider?.length = c ? Self.hiddenLength : 8
        toggle?.button?.image = NSImage(systemSymbolName: c ? "chevron.left" : "chevron.right", accessibilityDescription: c ? "Show hidden icons" : "Hide icons")
        collapseTask?.cancel()
        if !c {   // auto-hide again after 10 s so the bar stays tidy
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.setCollapsed(true)
            }
        }
    }
}

// MARK: - Smooth scrolling + mouse-only scroll direction (event tap; trackpads are never touched)

final class SmoothScroll: @unchecked Sendable {
    static let shared = SmoothScroll()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let marker: Int64 = 0x4B495445   // tags our own synthesized events so the tap ignores them

    var smooth = true
    var reverseMouse = false

    // Animation state (main thread only)
    private var remaining = CGPoint.zero
    private var timer: Timer?

    @MainActor
    func setEnabled(_ on: Bool) {
        if on {
            guard tap == nil, AXIsProcessTrusted() else { if !AXIsProcessTrusted() { ClipboardPanel.requestAutoPaste() }; return }
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
                SmoothScroll.shared.handle(type, event)
            }, userInfo: nil)
            guard let tap else { return }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            tap = nil
            source = nil
            timer?.invalidate()
            timer = nil
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0   // mouse wheel, not trackpad/Magic Mouse
        else { return Unmanaged.passUnretained(event) }

        let sign: Int64 = reverseMouse ? -1 : 1
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1) * sign
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2) * sign
        guard smooth else {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: dy)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: dx)
            return Unmanaged.passUnretained(event)
        }
        // Swallow the notchy line event; glide the same distance in pixels over ~200 ms.
        let pixelsPerLine: CGFloat = 40
        DispatchQueue.main.async {
            self.remaining.x += CGFloat(dx) * pixelsPerLine
            self.remaining.y += CGFloat(dy) * pixelsPerLine
            self.startGlide()
        }
        return nil
    }

    private func startGlide() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let step = CGPoint(x: self.remaining.x * 0.18, y: self.remaining.y * 0.18)   // ease-out
            if abs(step.x) < 0.5 && abs(step.y) < 0.5 {
                self.remaining = .zero
                t.invalidate()
                self.timer = nil
                return
            }
            self.remaining.x -= step.x
            self.remaining.y -= step.y
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(step.y.rounded()), wheel2: Int32(step.x.rounded()), wheel3: 0) {
                e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                e.post(tap: .cgSessionEventTap)
            }
        }
    }
}

// MARK: - Preferences + view

enum DesktopPrefs {
    static let snapping = "desktopSnapping"
    static let tidy = "desktopMenuBarTidy"
    static let smooth = "desktopSmoothScroll"
    static let reverse = "desktopReverseMouse"

    /// Called at launch: restore whatever the user switched on last time.
    @MainActor
    static func apply() {
        let d = UserDefaults.standard
        WindowSnapper.setEnabled(d.bool(forKey: snapping))
        MenuBarTidy.shared.setEnabled(d.bool(forKey: tidy))
        SmoothScroll.shared.smooth = d.bool(forKey: smooth)
        SmoothScroll.shared.reverseMouse = d.bool(forKey: reverse)
        SmoothScroll.shared.setEnabled(d.bool(forKey: smooth) || d.bool(forKey: reverse))
    }
}

struct DesktopView: View {
    @AppStorage(DesktopPrefs.snapping) private var snapping = false
    @AppStorage(DesktopPrefs.tidy) private var tidy = false
    @AppStorage(DesktopPrefs.smooth) private var smooth = false
    @AppStorage(DesktopPrefs.reverse) private var reverse = false
    @Local private var trusted = AXIsProcessTrusted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                if !trusted && (snapping || smooth || reverse) {
                    HStack(spacing: 12) {
                        IconWell(symbol: "hand.raised", tint: Tone.warn)
                        Text("Window snapping and scrolling need the Accessibility permission to move windows and read the mouse wheel.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Allow Accessibility…") { ClipboardPanel.requestAutoPaste() }
                    }
                    .panel(padding: 12)
                }
                snappingCard
                tidyCard
                scrollCard
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Desktop")
        .navigationSubtitle("Window snapping, menu bar tidy, smooth scrolling")
        .onChange(of: snapping) { _, on in WindowSnapper.setEnabled(on) }
        .onChange(of: tidy) { _, on in MenuBarTidy.shared.setEnabled(on) }
        .onChange(of: smooth) { _, _ in applyScroll() }
        .onChange(of: reverse) { _, _ in applyScroll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
            if trusted { applyScroll() }   // the tap can only start once permission exists
        }
    }

    private func applyScroll() {
        SmoothScroll.shared.smooth = smooth
        SmoothScroll.shared.reverseMouse = reverse
        SmoothScroll.shared.setEnabled(false)
        SmoothScroll.shared.setEnabled(smooth || reverse)
    }

    private var snappingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleHeader("rectangle.split.2x1", "Window snapping", "Move the front window with the keyboard. Same shortcuts as Rectangle.", $snapping)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(SnapTarget.allCases) { t in
                    HStack(spacing: 8) {
                        Text("⌃⌥\(t.key.label)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 5))
                        Text(t.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(snapping ? 1 : 0.5)
        }
        .panel()
    }

    private var tidyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleHeader("menubar.rectangle", "Menu bar tidy", "Hide menu bar icons behind a divider; click the arrow to show them for 10 seconds.", $tidy)
            if tidy {
                Text("Hold ⌘ and drag the icons you want hidden to the left of the ⁄ divider. Everything left of it tucks away.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .panel()
    }

    private var scrollCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconWell(symbol: "computermouse")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mouse scrolling").font(.system(size: 13, weight: .semibold))
                    Text("Only affects a mouse wheel. Trackpads and Magic Mouse are left exactly as they are.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Toggle("Smooth scrolling (glide instead of notchy jumps)", isOn: $smooth).toggleStyle(.checkbox).font(.system(size: 12))
            Toggle("Reverse the wheel for the mouse only (keep natural scrolling on the trackpad)", isOn: $reverse).toggleStyle(.checkbox).font(.system(size: 12))
        }
        .panel()
    }

    private func toggleHeader(_ symbol: String, _ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconWell(symbol: symbol, tint: isOn.wrappedValue ? Tone.good : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}
