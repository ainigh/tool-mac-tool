// swift-tools-version:5.9
import PackageDescription

// The tools' logic: Foundation only, so it's tested on any machine (swift test).
var targets: [Target] = [
    .target(name: "ToolCore"),
    .testTarget(name: "ToolCoreTests", dependencies: ["ToolCore"]),
]
var dependencies: [Package.Dependency] = []
#if os(macOS)
// The menu bar app: SwiftUI + AppKit, so only on the Mac. FluidAudio runs the open-source speech
// models (Kokoro's voices, Parakeet's listening) on this Mac; it needs Swift 6 to build.
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"))
targets.append(.executableTarget(name: "ToolMacTool", dependencies: [
    "ToolCore",
    .product(name: "FluidAudio", package: "FluidAudio"),
]))
#endif

let package = Package(name: "ToolMacTool", platforms: [.macOS(.v14)], dependencies: dependencies, targets: targets)
