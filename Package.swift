// swift-tools-version:5.9
import PackageDescription

// The tools' logic: Foundation only, so it's tested on any machine (swift test).
var targets: [Target] = [
    .target(name: "ToolCore"),
    .testTarget(name: "ToolCoreTests", dependencies: ["ToolCore"]),
]
#if os(macOS)
// The menu bar app: SwiftUI + AppKit, so only on the Mac.
targets.append(.executableTarget(name: "ToolMacTool", dependencies: ["ToolCore"]))
#endif

let package = Package(name: "ToolMacTool", platforms: [.macOS(.v13)], targets: targets)
