// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeoStat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NeoStat",
            path: "Sources/NeoStat",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
            ]
        )
    ]
)
