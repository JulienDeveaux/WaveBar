// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WaveBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WaveBar",
            path: "Sources/WaveBar",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=targeted"])
            ]
        )
    ]
)
