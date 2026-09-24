// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jev-cua",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JevCore", targets: ["JevCore"]),
        .library(name: "JevMac", targets: ["JevMac"]),
        .executable(name: "jev-cua", targets: ["jev-cua"]),
    ],
    targets: [
        // Headless engine: contracts, config, Jev client, questions, spans, policy, session.
        // No AppKit, no microphone. Everything here is testable without a GUI.
        .target(name: "JevCore", path: "Sources/JevCore"),

        // Mac adapter: speech providers, permissions, perception, executors, overlay.
        .target(name: "JevMac", dependencies: ["JevCore"], path: "Sources/JevMac"),

        // CLI and app entry point. No third-party dependencies: the build must not need the
        // network, and SwiftPM plugins from dependencies do not compile under this toolchain.
        .executableTarget(name: "jev-cua", dependencies: ["JevCore", "JevMac"], path: "Sources/jev-cua"),

        .testTarget(name: "JevCoreTests", dependencies: ["JevCore"], path: "Tests/JevCoreTests"),
        .testTarget(name: "JevMacTests", dependencies: ["JevMac"], path: "Tests/JevMacTests"),
    ]
)
