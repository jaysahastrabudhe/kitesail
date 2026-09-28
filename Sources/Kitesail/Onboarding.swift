import SwiftUI
import AppKit
import UserNotifications

/// First-run setup: one place for every permission (instead of prompts popping up feature by feature).
/// Shown once; everything here can also be granted later from each screen.
struct OnboardingSheet: View {
    let finish: () -> Void
    @Local private var step = 0
    @Local private var fullDisk = DiskScanner.hasFullDiskAccess()
    @Local private var accessibility = ClipboardPanel.canAutoPaste
    @Local private var notifications = false
    @AppStorage(Prefs.alerts) private var alerts = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                default: permissions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<2) { i in
                        Circle().fill(i == step ? Color.primary : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step == 1 {
                    Button("Back") { withAnimation(.snappy) { step -= 1 } }
                    Button("Done", action: finish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { withAnimation(.snappy) { step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .task {
            // Live status: permissions granted in System Settings tick over without reopening this sheet.
            while !Task.isCancelled {
                fullDisk = DiskScanner.hasFullDiskAccess()
                accessibility = ClipboardPanel.canAutoPaste
                notifications = await Self.notificationsAllowed()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(spacing: 6) {
                Text("Welcome to Kitesail").font(.system(size: 22, weight: .semibold))
                Text("Keep your Mac light: storage, memory and displays in one small app.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("square.grid.3x3.square", "See what fills your disk", "and clean caches, duplicates and old apps safely. Everything goes to the Trash first.")
                feature("memorychip", "Understand your memory", "with plain-English advice, and let Memory Guard quit idle apps when it gets tight.")
                feature("display", "Sharpen any monitor", "with HiDPI on 1080p and 1440p screens, plus refresh rate and brightness control.")
                feature("lock", "Private by design", "Kitesail never connects to the internet. No accounts, no analytics.")
            }
            .padding(.top, 6)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up permissions once").font(.system(size: 18, weight: .semibold))
                Text("All optional. Grant what you want now so nothing interrupts you later. You can change these anytime.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            permissionRow(symbol: "internaldrive", title: "Full Disk Access",
                          why: "Lets Disk Map and Clean Up see protected folders like Mail, Messages and the Trash. Kitesail won't be in the list yet: drag it in from the Finder window that opens (or click + and pick it), switch it on, then reopen Kitesail.",
                          granted: fullDisk, action: "Add Kitesail…") { DiskScanner.revealAppForFullDiskAccess() }
            permissionRow(symbol: "keyboard", title: "Accessibility",
                          why: "Lets clipboard history paste straight into the app you're typing in. Without it, picking an item just copies it.",
                          granted: accessibility, action: "Allow…") { ClipboardPanel.requestAutoPaste() }
            permissionRow(symbol: "bell", title: "Notifications",
                          why: "A heads-up when memory gets tight, when Memory Guard steps in, and a short weekly recap.",
                          granted: notifications, action: "Allow…") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    if ok { Task { @MainActor in alerts = true } }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 28)
                Text("A few actions (flushing the file cache, system startup items, some uninstalls) ask for your Mac password each time. That's macOS protecting system files; no app can pre-approve it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Pieces

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconWell(symbol: symbol)
            (Text(title).fontWeight(.semibold) + Text(" " + detail).foregroundStyle(.secondary))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(symbol: String, title: String, why: String, granted: Bool,
                               action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconWell(symbol: symbol, tint: granted ? Tone.good : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tone.good).labelStyle(.titleAndIcon)
            } else {
                Button(action, action: perform)
            }
        }
        .panel(padding: 12)
    }

    static func notificationsAllowed() async -> Bool {
        guard Watchdog.canNotify else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }
}
