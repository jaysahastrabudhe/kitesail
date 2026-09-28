import SwiftUI
import IOKit.hid

// Apple Silicon temperature sensors via the private IOHIDEventSystem API (same source Stats/iStat use).
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ t: Int64, _ o: Int32, _ f: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: AnyObject, _ f: Int32) -> Double

struct TemperatureGroup: Identifiable, Equatable {
    let id: String          // "CPU", "Chip", "SSD", "Battery"
    let symbol: String
    let celsius: Double     // hottest sensor in the group
}

enum Sensors {
    private static let temperatureEvent: Int64 = 15   // kIOHIDEventTypeTemperature

    /// Name → group. Sensors outside 1–130 °C are placeholders (some report −22 °C) and are dropped.
    static func group(for name: String) -> (id: String, symbol: String)? {
        if name.hasPrefix("PMU") && name.contains("tdie") { return ("CPU", "cpu") }
        if name.hasPrefix("PMGR SOC Die") { return ("Chip", "memorychip") }
        if name.hasPrefix("NAND") { return ("SSD", "internaldrive") }
        if name.lowercased().contains("battery") { return ("Battery", "battery.75percent") }
        return nil
    }

    static func read() -> [TemperatureGroup] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var hottest: [String: (symbol: String, value: Double)] = [:]
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let g = group(for: name),
                  let e = IOHIDServiceClientCopyEvent(s, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(e, Int32(temperatureEvent << 16))
            guard (1...130).contains(v) else { continue }
            if v > (hottest[g.id]?.value ?? -1) { hottest[g.id] = (g.symbol, v) }
        }
        let order = ["CPU", "Chip", "SSD", "Battery"]
        return order.compactMap { id in hottest[id].map { TemperatureGroup(id: id, symbol: $0.symbol, celsius: $0.value) } }
    }

    static func tone(_ c: Double) -> Color { c >= 95 ? Tone.bad : c >= 80 ? Tone.warn : Tone.good }
}

struct TemperatureCard: View {
    let groups: [TemperatureGroup]
    let history: [Double]      // hottest CPU reading per sample

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Temperatures", detail: "hottest sensor in each group")
            if groups.isEmpty {
                Text("No readable sensors on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(g.id, systemImage: g.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(String(format: "%.0f °C", g.celsius)).font(.figure(20)).foregroundStyle(Sensors.tone(g.celsius))
                                .contentTransition(.numericText())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if history.count > 1 {
                    Sparkline(values: history).frame(height: 28)
                    Text("CPU, last few minutes. Apple Silicon runs up to about 100 °C by design; sustained 90 °C+ on a fanless Mac means it's slowing itself down.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .panel()
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let lo = (values.min() ?? 0) - 2, hi = (values.max() ?? 1) + 2
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                     y: geo.size.height * (1 - CGFloat((v - lo) / max(hi - lo, 1))))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
