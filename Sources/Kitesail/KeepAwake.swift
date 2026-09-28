import SwiftUI
import IOKit.pwr_mgt

/// Amphetamine-style keep-awake via a power assertion (the same mechanism `caffeinate` uses). Released on quit.
@MainActor @Observable
final class KeepAwake {
    var until: Date?            // nil = off, .distantFuture = until turned off
    var keepDisplayOn = true
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var expiry: Task<Void, Never>?

    var isOn: Bool { until != nil }

    var label: String {
        guard let until else { return "Off" }
        if until == .distantFuture { return "On until you turn it off" }
        return "On until \(until.formatted(date: .omitted, time: .shortened))"
    }

    /// `minutes == nil` keeps the Mac awake until turned off.
    func start(minutes: Int?) {
        stop()
        let type = (keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Kitesail Keep Awake" as CFString, &assertion) == kIOReturnSuccess else { return }
        until = minutes.map { Date.now.addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        if let minutes {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        expiry?.cancel()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        until = nil
    }
}

struct KeepAwakeCard: View {
    let awake: KeepAwake

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconWell(symbol: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer", tint: awake.isOn ? Tone.good : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Awake").font(.system(size: 13, weight: .semibold))
                    Text(awake.label).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if awake.isOn { Button("Turn Off") { awake.stop() } }
            }
            HStack(spacing: 8) {
                ForEach([(30, "30 min"), (60, "1 hour"), (120, "2 hours")], id: \.0) { minutes, title in
                    Button(title) { awake.start(minutes: minutes) }
                }
                Button("Until I turn it off") { awake.start(minutes: nil) }
                Spacer()
                Toggle("Keep display on", isOn: Binding(get: { awake.keepDisplayOn }, set: { awake.keepDisplayOn = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            .controlSize(.small)
            Text("For exports, downloads and presentations. Released the moment you quit Kitesail.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .panel()
    }
}
