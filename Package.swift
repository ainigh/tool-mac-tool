// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ToolMacTool",
    platforms: [.macOS(.v13)],
    targets: [
        // The tools' logic: Foundation only, so it's tested on any machine (swift test).
        .target(name: "ToolCore"),
        // The menu bar app: SwiftUI + AppKit.
        .executableTarget(name: "ToolMacTool", dependencies: ["ToolCore"]),
        .testTarget(name: "ToolCoreTests", dependencies: ["ToolCore"]),
    ]
)
