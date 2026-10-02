// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    // 14.2 is the floor: Apple introduced AudioHardwareCreateProcessTap there,
    // and it is the only route to per-application volume on current macOS.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "VolumeMixer",
            path: "Sources/VolumeMixer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VolumeMixerTests",
            dependencies: ["VolumeMixer"],
            path: "Tests/VolumeMixerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)