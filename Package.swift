// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Netbite",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetbiteCore", targets: ["NetbiteCore"]),
        .executable(name: "netbite", targets: ["netbite"]),
        // Not "Netbite": on a case-insensitive disk it would collide with the `netbite` CLI binary.
        .executable(name: "NetbiteApp", targets: ["NetbiteApp"]),
        .executable(name: "netbited", targets: ["netbited"]),
    ],
    targets: [
        .target(name: "NetbiteCore"),
        .executableTarget(name: "netbite", dependencies: ["NetbiteCore"]),
        .executableTarget(name: "NetbiteApp", dependencies: ["NetbiteCore"]),
        // The privileged helper; it runs as root, so it stays small and depends on the core only.
        .executableTarget(name: "netbited", dependencies: ["NetbiteCore"]),
        .testTarget(name: "NetbiteCoreTests", dependencies: ["NetbiteCore"]),
    ]
)
