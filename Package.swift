// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Netbite",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetbiteCore", targets: ["NetbiteCore"]),
        .executable(name: "netbite", targets: ["netbite"]),
    ],
    targets: [
        .target(name: "NetbiteCore"),
        .executableTarget(name: "netbite", dependencies: ["NetbiteCore"]),
        .testTarget(name: "NetbiteCoreTests", dependencies: ["NetbiteCore"]),
    ]
)
