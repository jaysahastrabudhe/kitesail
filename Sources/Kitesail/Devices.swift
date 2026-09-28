import SwiftUI
import AppKit
import IOKit
import IOKit.ps

// MARK: - Charger

struct ChargerInfo {
    let watts: Int
    let volts: Double
    let amps: Double
    let profiles: [Int]          // USB-PD voltage levels it offers, in volts
    let chargingWatts: Double?   // what's actually flowing into the battery right now
}

// MARK: - USB

struct USBDevice: Identifiable {
    let id: UInt64
    let name: String
    let vendor: String?
    let speed: Int?              // IOUSBHost "Device Speed": 0 low, 1 full, 2 high, 3 super, 4 super+, 5 super+ x2
    let isStorage: Bool

    var speedLabel: String {
        switch speed {
        case 0: "USB 1 · 1.5 Mb/s"; case 1: "USB 1 · 12 Mb/s"; case 2: "USB 2 · 480 Mb/s"
        case 3: "USB 3 · 5 Gb/s"; case 4: "USB 3.2 · 10 Gb/s"; case 5: "USB 3.2 · 20 Gb/s"
        default: "Speed unknown"
        }
    }

    /// The WhatCable insight: a drive stuck at USB 2 speed almost always means a USB 2-only cable or hub.
    var warning: String? {
        guard isStorage, let speed, speed <= 2 else { return nil }
        return "This drive is running at USB 2 speed, about 40 MB/s. The cable or hub is probably USB 2 only; a USB 3 or USB-C data cable can make it 10× faster."
    }
}

// MARK: - Bluetooth

struct BluetoothDevice: Identifiable {
    let id: String
    let name: String
    let kind: String?
    let levels: [(label: String, percent: Int)]   // e.g. Left 80, Right 75, Case 40 / or a single Battery level
    var lowest: Int? { levels.map(\.percent).min() }
}

enum DeviceScanner {
    static func charger() -> ChargerInfo? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details["Watts"] as? Int, watts > 0 else { return nil }
        let menu = details["UsbHvcMenu"] as? [[String: Any]] ?? []
        let profiles = Array(Set(menu.compactMap { ($0["MaxVoltage"] as? Int).map { $0 / 1000 } })).sorted()
        return ChargerInfo(watts: watts,
                           volts: Double(details["AdapterVoltage"] as? Int ?? 0) / 1000,
                           amps: Double(details["Current"] as? Int ?? 0) / 1000,
                           profiles: profiles,
                           chargingWatts: batteryInputWatts())
    }

    /// Voltage × amperage from the battery gauge. Amperage is signed (negative while discharging).
    static func batteryInputWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func num(_ key: String) -> Int64? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.int64Value
        }
        guard let mv = num("Voltage"), let raw = num("Amperage") else { return nil }
        let ma = Int64(Int32(truncatingIfNeeded: raw))
        return ma > 0 ? Double(mv) * Double(ma) / 1_000_000 : nil
    }

    static func usbDevices() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [USBDevice] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            let name = (prop("USB Product Name") ?? prop("kUSBProductString")) as? String ?? "USB device"
            // Skip the Mac's own internal hubs and controllers.
            if name.localizedCaseInsensitiveContains("root hub") { continue }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            devices.append(USBDevice(id: id, name: name, vendor: (prop("USB Vendor Name") ?? prop("kUSBVendorString")) as? String,
                                     speed: (prop("Device Speed") ?? prop("USBSpeed")) as? Int,
                                     isStorage: hasChild(entry, className: "IOMedia")))
        }
        return devices
    }

    private static func hasChild(_ entry: io_registry_entry_t, className: String) -> Bool {
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, className) != 0 { return true }
        }
        return false
    }

    /// Magic Keyboard / Mouse / Trackpad report battery directly in the IORegistry (cheap: no process launch).
    static func magicDevices() -> [BluetoothDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [BluetoothDevice] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let percent = prop("BatteryPercent") as? Int, let name = prop("Product") as? String else { continue }
            out.append(BluetoothDevice(id: "hid-\(name)", name: name, kind: "Accessory", levels: [("Battery", percent)]))
        }
        return out
    }

    /// AirPods and other headphones: `system_profiler` has their per-bud battery levels (run only on demand).
    static func audioDevices() -> [BluetoothDevice] {
        let json = StartupScanner.runStatus("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).output
        return parseBluetooth(Data(json.utf8))
    }

    static func parseBluetooth(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [BluetoothDevice] = []
        for c in controllers {
            for entry in c["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let keys: [(String, String)] = [("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
                                                    ("device_batteryLevelCase", "Case"), ("device_batteryLevelMain", "Battery")]
                    let levels = keys.compactMap { key, label -> (String, Int)? in
                        guard let s = info[key] as? String, let n = Int(s.replacingOccurrences(of: "%", with: "")) else { return nil }
                        return (label, n)
                    }
                    out.append(BluetoothDevice(id: "bt-\(name)", name: name, kind: info["device_minorType"] as? String, levels: levels))
                }
            }
        }
        return out
    }
}

@MainActor @Observable
final class DevicesModel {
    var charger: ChargerInfo?
    var usb: [USBDevice] = []
    var bluetooth: [BluetoothDevice] = []
    var loaded = false

    /// Runs only while the Devices tab is on screen.
    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))   // system_profiler is a process launch, so not too often
        }
    }

    func refresh() async {
        let result = await Task.detached(priority: .utility) {
            (DeviceScanner.charger(), DeviceScanner.usbDevices(), DeviceScanner.magicDevices() + DeviceScanner.audioDevices())
        }.value
        withAnimation(.smooth) {
            charger = result.0
            usb = result.1
            bluetooth = result.2
        }
        loaded = true
    }
}

struct DevicesView: View {
    @Bindable var model: DevicesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                chargerCard
                usbCard
                bluetoothCard
            }
            .padding(Metrics.page)
        }
        .navigationTitle("Devices")
        .navigationSubtitle(model.loaded ? "\(plural(model.usb.count, "USB device")) · \(plural(model.bluetooth.count, "Bluetooth device"))" : "Looking…")
        .toolbar { ToolbarItem { Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } } }
        .task { await model.monitor() }
    }

    private var chargerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Charger")
            if let c = model.charger {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(c.watts) W").font(.figure(24))
                    if c.volts > 0 { Text(String(format: "%.0f V · %.1f A", c.volts, c.amps)).font(.figure(12, weight: .regular)).foregroundStyle(.secondary) }
                    Spacer()
                    if let w = c.chargingWatts {
                        Label(String(format: "Charging at %.0f W", w), systemImage: "bolt.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Tone.good)
                    }
                }
                Text(chargerAdvice(c)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !c.profiles.isEmpty {
                    Text("USB-C Power Delivery levels: " + c.profiles.map { "\($0) V" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else {
                Text("No charger connected.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func chargerAdvice(_ c: ChargerInfo) -> String {
        switch c.watts {
        case ..<20: "Low-power charger. Your Mac may charge very slowly or not at all while it's busy."
        case 20..<30: "Enough to charge a MacBook Air slowly. A 30 W+ charger charges at full speed."
        case 30..<65: "Full-speed charging for a MacBook Air. A MacBook Pro charges faster on 67 W or more."
        default: "Plenty of power. Your Mac takes only what it needs, so a bigger charger is safe."
        }
    }

    private var usbCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "USB devices", detail: "What each one is actually running at").padding(.bottom, 8)
            if model.usb.isEmpty {
                Text("Nothing plugged in over USB.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(Array(model.usb.enumerated()), id: \.element.id) { index, d in
                if index > 0 { Divider().padding(.leading, 40) }
                HStack(alignment: .top, spacing: 12) {
                    IconWell(symbol: d.isStorage ? "externaldrive" : "cable.connector", tint: d.warning == nil ? .secondary : Tone.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 13, weight: .medium))
                        if let v = d.vendor { Text(v).font(.system(size: 11)).foregroundStyle(.tertiary) }
                        if let w = d.warning { Text(w).font(.system(size: 12)).foregroundStyle(Tone.warn).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 12)
                    Text(d.speedLabel).font(.figure(12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.vertical, Metrics.row)
            }
        }
        .panel()
    }

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Bluetooth batteries", detail: "Connected devices").padding(.bottom, 8)
            if model.bluetooth.isEmpty {
                Text(model.loaded ? "No Bluetooth devices connected." : "Looking…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(Array(model.bluetooth.enumerated()), id: \.element.id) { index, d in
                if index > 0 { Divider().padding(.leading, 40) }
                HStack(spacing: 12) {
                    IconWell(symbol: symbol(for: d), tint: (d.lowest ?? 100) < 20 ? Tone.bad : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 13, weight: .medium))
                        if let k = d.kind { Text(k).font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                    Spacer(minLength: 12)
                    if d.levels.isEmpty {
                        Text("Doesn't report battery").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 14) {
                            ForEach(d.levels, id: \.label) { level in
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("\(level.percent)%").font(.figure(13)).foregroundStyle(level.percent < 20 ? Tone.bad : .primary)
                                    Text(level.label).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Metrics.row)
            }
        }
        .panel()
    }

    private func symbol(for d: BluetoothDevice) -> String {
        let n = (d.name + " " + (d.kind ?? "")).lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("head") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}
