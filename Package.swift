// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMedal",
    platforms: [
        // 14.2+ is required for per-application audio capture via ScreenCaptureKit.
        // We target 15 to get the newest, most stable SCStream APIs.
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MacMedal",
            path: "Sources/MacMedal",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
