// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kitesail",
    platforms: [.macOS(.v26)],
    targets: [
        // Private CoreGraphics virtual-display API (same one BetterDisplay/DeskPad use) for HiDPI on 1x monitors.
        .target(name: "VirtualDisplayPrivate", path: "Sources/VirtualDisplayPrivate"),
        .executableTarget(
            name: "Kitesail",
            dependencies: ["VirtualDisplayPrivate"],
            path: "Sources/Kitesail",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
