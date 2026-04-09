// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "claude-gavel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gavel", targets: ["Gavel"]),
        .executable(name: "gavel-hook", targets: ["GavelHook"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Gavel",
            dependencies: [],
            path: "Sources/Gavel",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "GavelHook",
            dependencies: [],
            path: "Sources/GavelHook"
        ),
        .testTarget(
            name: "GavelTests",
            dependencies: ["Gavel"],
            path: "Tests/GavelTests"
        ),
    ]
)
