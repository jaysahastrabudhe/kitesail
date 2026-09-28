import SwiftUI
import AppKit

struct SecurityCheck: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let passed: Bool?        // nil = couldn't tell
    let good: String         // what "on" means
    let fix: String          // what to do if off
    let settingsURL: String? // where to fix it; nil if it can't be changed from Settings
}

enum SecurityScanner {
    static func run(_ tool: String, _ args: [String]) -> String {
        StartupScanner.runStatus(tool, args).output.lowercased()
    }

    /// Every check reads status only; nothing here changes a setting or needs admin rights.
    static func scan() -> [SecurityCheck] {
        let fileVault = run("/usr/bin/fdesetup", ["status"])
        let sip = run("/usr/bin/csrutil", ["status"])
        let gatekeeper = run("/usr/sbin/spctl", ["--status"])
        let firewall = run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        func updatePref(_ key: String) -> Bool? {
            let out = run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out == "1" ? true : out == "0" ? false : nil
        }
        let autoMacOS = updatePref("AutomaticallyInstallMacOSUpdates")
        let autoSecurity = updatePref("CriticalUpdateInstall")
        return [
            SecurityCheck(id: "filevault", title: "FileVault disk encryption", symbol: "lock.shield",
                          passed: fileVault.isEmpty ? nil : fileVault.contains("filevault is on"),
                          good: "Your disk is encrypted. A lost or stolen Mac doesn't expose your files.",
                          fix: "Turn on FileVault so a stolen Mac can't be read. It encrypts in the background.",
                          settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"),
            SecurityCheck(id: "firewall", title: "Firewall", symbol: "flame",
                          passed: firewall.isEmpty ? nil : (firewall.contains("enabled") && !firewall.contains("disabled")),
                          good: "Incoming connections are filtered.",
                          fix: "Turn on the firewall, especially if you use public or office Wi-Fi.",
                          settingsURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"),
            SecurityCheck(id: "gatekeeper", title: "Gatekeeper", symbol: "checkmark.shield",
                          passed: gatekeeper.isEmpty ? nil : gatekeeper.contains("assessments enabled"),
                          good: "macOS checks apps before they first run.",
                          fix: "Gatekeeper is off, so any app can run unchecked. Turn it back on in Privacy & Security.",
                          settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
            SecurityCheck(id: "sip", title: "System Integrity Protection", symbol: "cpu",
                          passed: sip.isEmpty ? nil : sip.contains("enabled"),
                          good: "Core system files can't be modified, even by admin apps.",
                          fix: "SIP is off. Re-enable it from Recovery (hold the power button, Options → Terminal → csrutil enable).",
                          settingsURL: nil),
            SecurityCheck(id: "updates", title: "Automatic security updates", symbol: "arrow.down.circle",
                          passed: autoSecurity.map { $0 && (autoMacOS ?? true) },
                          good: "Security fixes and macOS updates install on their own.",
                          fix: "Turn on automatic installs for macOS updates and security responses.",
                          settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"),
        ]
    }
}

@MainActor @Observable
final class SecurityModel {
    var checks: [SecurityCheck] = []
    var scanning = false
    var passed: Int { checks.filter { $0.passed == true }.count }

    func scan() async {
        scanning = true
        let result = await Task.detached(priority: .utility) { SecurityScanner.scan() }.value
        withAnimation(.smooth) { checks = result }
        scanning = false
    }
}

struct SecurityView: View {
    @Bindable var model: SecurityModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle(title: "Security checkup", detail: model.checks.isEmpty ? "Checking…" : "\(model.passed) of \(model.checks.count) on")
                        .padding(.bottom, 8)
                    ForEach(Array(model.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 40) }
                        row(check)
                    }
                }
                .panel()
                Text("Kitesail only reads these settings. Changing them always happens in System Settings, by you.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Security")
        .navigationSubtitle(model.checks.isEmpty ? "Checking…" : model.passed == model.checks.count ? "Everything important is on" : "\(model.checks.count - model.passed) to review")
        .toolbar { ToolbarItem { Button { Task { await model.scan() } } label: { Label("Check Again", systemImage: "arrow.clockwise") } } }
        .task { await model.scan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.scan() }   // pick up changes made in System Settings
        }
    }

    private func row(_ c: SecurityCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconWell(symbol: c.symbol, tint: c.passed == true ? Tone.good : c.passed == false ? Tone.warn : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.title).font(.system(size: 13, weight: .medium))
                    Text(c.passed == true ? "On" : c.passed == false ? "Off" : "Unknown")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.passed == true ? Tone.good : c.passed == false ? Tone.warn : .secondary)
                }
                Text(c.passed == false ? c.fix : c.good).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if c.passed == false, let s = c.settingsURL, let url = URL(string: s) {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.vertical, Metrics.row)
    }
}
