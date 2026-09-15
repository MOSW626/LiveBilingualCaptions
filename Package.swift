// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveBilingualCaptions",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CaptionsCore"),
        .executableTarget(
            name: "LiveBilingualCaptions",
            dependencies: ["CaptionsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)] // Task 7에서 .v6으로 전환
        ),
        .testTarget(
            name: "CaptionsCoreTests",
            dependencies: ["CaptionsCore"]
        )
    ]
)
