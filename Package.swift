// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hector",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HectorCore", targets: ["HectorCore"]),
        .executable(name: "hector", targets: ["hector"]),
        // Not "Hector": on a case-insensitive disk it would collide with the `hector` CLI binary.
        .executable(name: "HectorApp", targets: ["HectorApp"]),
        .executable(name: "hectord", targets: ["hectord"]),
    ],
    targets: [
        .target(name: "HectorCore"),
        .executableTarget(name: "hector", dependencies: ["HectorCore"]),
        .executableTarget(name: "HectorApp", dependencies: ["HectorCore"]),
        // The privileged helper; it runs as root, so it stays small and depends on the core only.
        .executableTarget(name: "hectord", dependencies: ["HectorCore"]),
        .testTarget(name: "HectorCoreTests", dependencies: ["HectorCore"]),
    ]
)
