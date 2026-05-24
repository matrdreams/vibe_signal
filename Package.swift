// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "VibeSignal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VibeSignalCore", targets: ["VibeSignalCore"]),
        .executable(name: "VibeSignalApp", targets: ["VibeSignalApp"]),
        .executable(name: "vibe-signal", targets: ["VibeSignalCLI"])
    ],
    targets: [
        .target(name: "VibeSignalCore"),
        .executableTarget(
            name: "VibeSignalApp",
            dependencies: ["VibeSignalCore"]
        ),
        .executableTarget(
            name: "VibeSignalCLI",
            dependencies: ["VibeSignalCore"]
        ),
        .testTarget(
            name: "VibeSignalCoreTests",
            dependencies: ["VibeSignalCore"]
        )
    ]
)
