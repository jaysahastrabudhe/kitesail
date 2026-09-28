import Foundation
import CoreGraphics

/// `Kitesail --selftest`: checks the pure logic (treemap geometry, diagnosis, live readers) without UI.
enum SelfTest {
    static func run() {
        // Treemap: every block inside the frame, areas proportional, no overlaps.
        let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let values: [Double] = [500, 300, 120, 80, 40, 30, 10, 5, 1]
        let rects = Treemap.layout(values, in: frame)
        let total = values.reduce(0, +)
        precondition(rects.count == values.count)
        for (v, r) in zip(values, rects) {
            precondition(frame.insetBy(dx: -0.01, dy: -0.01).contains(r), "rect escapes frame: \(r)")
            let expected = v / total * Double(frame.width * frame.height)
            precondition(abs(Double(r.width * r.height) - expected) < 0.5, "area mismatch for \(v)")
        }
        for i in rects.indices { for j in rects.indices where i < j {
            let overlap = rects[i].intersection(rects[j])
            precondition(overlap.isNull || overlap.width * overlap.height < 0.01, "overlap \(i) \(j)")
        } }
        precondition(Treemap.layout([], in: frame).isEmpty)

        // Diagnosis: healthy Mac says "don't bother"; swapping Mac points at the heaviest quittable app.
        let gib = Diagnosis.gib
        let calm = MemorySnapshot(total: 8 * gib, app: 3 * gib, wired: gib, compressed: 0, cached: 2 * gib,
                                  swapUsed: 0, swapTotal: 0, pressure: .normal)
        precondition(Diagnosis.insights(calm, top: []).first?.tone == .good)
        let chrome = ProcGroup(id: "/Applications/Google Chrome.app", name: "Google Chrome",
                               appPath: "/Applications/Google Chrome.app", bytes: 3 * gib, pids: Array(1...20))
        let stressed = MemorySnapshot(total: 8 * gib, app: 5 * gib, wired: gib, compressed: 2 * gib, cached: 0,
                                      swapUsed: 3 * gib, swapTotal: 4 * gib, pressure: .critical)
        let tips = Diagnosis.insights(stressed, top: [chrome])
        precondition(tips.contains { $0.title.contains("Google Chrome") })
        precondition(tips.contains { $0.title.contains("swapped") && $0.tone == .warn })
        precondition(MemoryReader.identity(path: "/Applications/Google Chrome.app/Contents/Frameworks/X.app/Contents/MacOS/Helper", pid: 1).app
               == "/Applications/Google Chrome.app")

        // Lift Score: healthy Mac scores 100, a full disk + swapping Mac scores low, paths inside libraries are protected.
        precondition(HealthScore.compute(freeFraction: 0.3, pressure: .normal, swapGB: 0) == 100)
        precondition(HealthScore.compute(freeFraction: 0.05, pressure: .critical, swapGB: 6) == 10)
        precondition(CleanupModel.isInsidePackage("/Users/j/Pictures/Photos Library.photoslibrary/originals/A/1.mov"))
        precondition(!CleanupModel.isInsidePackage("/Users/j/Movies/render.final.mov"))

        // Leak watch: steady climb flags, a spike that recovers or a small drift does not.
        let mb: UInt64 = 1_048_576
        let climb = (0..<40).map { UInt64(800 + $0 * 30) * mb }
        precondition(LeakWatch.growth(climb) != nil)
        precondition(LeakWatch.growth(Array(climb.prefix(10))) == nil)
        precondition(LeakWatch.growth((0..<40).map { UInt64($0 % 2 == 0 ? 800 : 2000) * mb }) == nil)
        precondition(LeakWatch.growth((0..<40).map { UInt64(800 + $0) * mb }) == nil)
        precondition(StartupScanner.isSafeLabel("com.google.keystone.agent") && !StartupScanner.isSafeLabel("x; rm -rf ~"))

        // Duplicate finder: two identical files + one different file → one group of two; clones/hard links skipped.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "kitesail-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let blob = Data(repeating: 7, count: 1_200_000)
        try? blob.write(to: tmp.appending(path: "a.bin"))
        try? blob.write(to: tmp.appending(path: "b.bin"))
        var other = blob; other[1_100_000] = 9
        try? other.write(to: tmp.appending(path: "c.bin"))
        try? FileManager.default.linkItem(at: tmp.appending(path: "a.bin"), to: tmp.appending(path: "a-hardlink.bin"))
        let dups = DuplicateFinder.scan(tmp) { _ in }
        precondition(dups.count == 1 && dups[0].files.count == 2, "duplicate finder: \(dups.map { $0.files.count })")
        try? FileManager.default.removeItem(at: tmp)
        precondition(JunkGroup.installerExtensions.contains("dmg"))

        // Weekly recap sums only its own kinds.
        let r = ActivityLog.summarize([.init(date: .now, kind: .freed, bytes: 100), .init(date: .now, kind: .freed, bytes: 50),
                                       .init(date: .now, kind: .guardQuit, bytes: 999)], scores: [64, 70, 81])
        precondition(r == ActivityLog.Recap(freed: 150, guardQuits: 1, scoreStart: 64, scoreEnd: 81))

        // Command palette: word-order-free matching, destructive commands hidden until you type.
        let cmds = [PaletteCommand(id: "a", title: "Keep Awake for 1 Hour", symbol: "", run: {}),
                    PaletteCommand(id: "b", title: "Quit All Apps", symbol: "", needsQuery: true, run: {})]
        precondition(PaletteSearch.filter(cmds, "").map(\.id) == ["a"])
        precondition(PaletteSearch.filter(cmds, "apps quit").map(\.id) == ["b"])
        precondition(PaletteSearch.filter(cmds, "hour awake").map(\.id) == ["a"])

        // DDC: set-brightness-50 packet and checksum, and a well-formed reply parse.
        precondition(DDCChannel.packet([0x03, 0x10, 0x00, 0x32]) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32])
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        precondition(DDCChannel.parseReply(reply, code: .brightness).map { [$0.current, $0.max] } == [50, 100])
        precondition(DDCChannel.parseReply(reply, code: .volume) == nil)

        // Review fixes: bare commands aren't orphans, VM bundles are protected, unreadable files never hash equal.
        let agent = StartupItem(plist: URL(fileURLWithPath: "/tmp/x.plist"), label: "x", program: "node",
                                scope: .user, disabled: false, runningBytes: 0, runningCount: 0)
        precondition(!agent.orphaned)
        precondition(CleanupModel.isInsidePackage("/Users/j/Parallels/Win11.pvm/harddisk.hdd"))
        precondition(DuplicateFinder.digest(URL(fileURLWithPath: "/nonexistent/a"), limit: nil, expected: 10) == nil)

        // CPU ticks: a wrapped 32-bit counter still gives the right delta.
        let before = SystemReader.Ticks(user: .max - 9, system: 0, idle: .max - 29, nice: 0)
        let after = SystemReader.Ticks(user: 10, system: 0, idle: 10, nice: 0)
        precondition(SystemReader.delta(before, after) == (busy: 20, total: 60))

        // Sensors: known names map to groups, unknown ones are ignored.
        precondition(Sensors.group(for: "PMU tdie3")?.id == "CPU" && Sensors.group(for: "NAND CH0 temp")?.id == "SSD")
        precondition(Sensors.group(for: "PMU tdev1") == nil)

        // New tools: snapshot parsing, Bluetooth battery parsing, window-snap geometry.
        let snaps = SystemDataScanner.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-28-101010.local\ncom.apple.TimeMachine.2026-09-27-090000.local")
        precondition(snaps.count == 2 && snaps[0] > snaps[1])
        let bt = DeviceScanner.parseBluetooth(Data(#"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_batteryLevelLeft":"80%","device_batteryLevelRight":"75%","device_minorType":"Headphones"}}]}]}"#.utf8))
        precondition(bt.first?.lowest == 75 && bt.first?.levels.count == 2)
        let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)
        precondition(SnapTarget.leftHalf.frame(in: screen) == CGRect(x: 0, y: 25, width: 600, height: 800))
        precondition(SnapTarget.lastThird.frame(in: screen).maxX == 1200)
        precondition(USBDevice(id: 1, name: "SSD", vendor: nil, speed: 2, isStorage: true).warning != nil)

        // Live readers return sane values on this machine.
        let snap = MemoryReader.snapshot()
        precondition(snap != nil && snap!.total > 0 && snap!.used <= snap!.total)
        precondition(!MemoryReader.topGroups(limit: 5).isEmpty)

        print("selftest ok — memory used \(formatGB(snap!.used)) / \(formatGB(snap!.total)), swap \(formatGB(snap!.swapUsed))")
    }
}
