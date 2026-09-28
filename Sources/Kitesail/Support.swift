import SwiftUI
import AppKit

enum Support {
    static let url = URL(string: "https://buymeacoffee.com/LCIJOxlNF")!
    static func open() { NSWorkspace.shared.open(url) }
}

/// Launch counter behind the one-time support ask (third launch: people have used it a bit by then).
enum Launches {
    static let key = "launchCount"
    static let askOnLaunch = 3
    static func record() { UserDefaults.standard.set(count + 1, forKey: key) }
    static var count: Int { UserDefaults.standard.integer(forKey: key) }
}

/// Shown once, on the third launch.
struct DonateSheet: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text("Enjoying Kitesail?").font(.system(size: 18, weight: .semibold))
                Text("Kitesail is free and open source, built by one person. If it keeps your Mac light and you'd like to support its development, you can buy me a coffee. No features are locked, ever.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Maybe Later", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Support.open()
                    dismiss()
                } label: {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("It's also at the bottom of the sidebar, anytime.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// Always-available, low-key support link at the bottom of the sidebar.
struct SupportRow: View {
    @Local private var hovering = false
    var body: some View {
        Button(action: Support.open) {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 12))
                Text("Support development").font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).opacity(hovering ? 1 : 0.5)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Buy Me a Coffee: buymeacoffee.com/LCIJOxlNF")
    }
}
