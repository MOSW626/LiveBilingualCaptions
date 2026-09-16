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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaptionsCoreTests",
            dependencies: ["CaptionsCore"]
        )
    ]
)
