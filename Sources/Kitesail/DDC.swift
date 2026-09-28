import Foundation
import IOKit
import CoreGraphics

// Private IOKit calls Apple Silicon uses to talk I²C to external monitors (same path MonitorControl/BetterDisplay use).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// MCCS VCP codes Kitesail exposes.
enum VCP: UInt8 {
    case brightness = 0x10, contrast = 0x12, volume = 0x62, input = 0x60
}

/// DDC/CI over an Apple Silicon AV service. Every call is blocking I²C with short sleeps, so call off the main thread.
final class DDCChannel: @unchecked Sendable {
    private let service: CFTypeRef
    private static let chip: UInt32 = 0x37
    private static let hostAddress: UInt32 = 0x51
    private let lock = NSLock()

    private init(_ service: CFTypeRef) { self.service = service }

    /// External AV services in registry order. Mapping to displays is by order among external displays,
    /// which is right for one external monitor and usually right for two.
    static func externalChannels() -> [DDCChannel] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var channels: [DDCChannel] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            channels.append(DDCChannel(av))
        }
        return channels
    }

    /// Packet layout: [0x80 | length, opcode, payload…, checksum], checksum = XOR of 0x6E, 0x51 and every byte.
    static func packet(_ body: [UInt8]) -> [UInt8] {
        var p = [0x80 | UInt8(body.count)] + body
        p.append(p.reduce(UInt8(0x6E) ^ UInt8(hostAddress)) { $0 ^ $1 })
        return p
    }

    func write(_ code: VCP, _ value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var p = Self.packet([0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
        // Many monitors drop the first write after idling; send twice.
        var ok = false
        for _ in 0..<2 {
            ok = IOAVServiceWriteI2C(service, Self.chip, Self.hostAddress, &p, UInt32(p.count)) == KERN_SUCCESS || ok
            usleep(10_000)
        }
        return ok
    }

    /// Returns (current, max), or nil if the monitor doesn't answer.
    func read(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<3 {
            var request = Self.packet([0x01, code.rawValue])
            guard IOAVServiceWriteI2C(service, Self.chip, Self.hostAddress, &request, UInt32(request.count)) == KERN_SUCCESS else { continue }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, Self.chip, Self.hostAddress, &reply, UInt32(reply.count)) == KERN_SUCCESS else { continue }
            if let parsed = Self.parseReply(reply, code: code) { return parsed }
            usleep(20_000)
        }
        return nil
    }

    /// Reply: [src, 0x88, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]; result 0 = supported.
    static func parseReply(_ r: [UInt8], code: VCP) -> (current: UInt16, max: UInt16)? {
        guard r.count >= 11, r[1] == 0x88, r[2] == 0x02, r[3] == 0x00, r[4] == code.rawValue else { return nil }
        let max = UInt16(r[6]) << 8 | UInt16(r[7])
        let cur = UInt16(r[8]) << 8 | UInt16(r[9])
        return max > 0 ? (cur, max) : nil
    }
}

/// Common MCCS input source codes.
enum MonitorInput: UInt16, CaseIterable, Identifiable {
    case displayPort1 = 0x0F, displayPort2 = 0x10, hdmi1 = 0x11, hdmi2 = 0x12, usbC = 0x1B
    var id: UInt16 { rawValue }
    var label: String {
        switch self {
        case .displayPort1: "DisplayPort 1"; case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"; case .hdmi2: "HDMI 2"; case .usbC: "USB-C"
        }
    }
}
