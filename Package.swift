// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipThat",
    platforms: [
        // 14.2+ is required for per-application audio capture via ScreenCaptureKit.
        // We target 15 to get the newest, most stable SCStream APIs.
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "ClipThat",
            path: "Sources/ClipThat",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
