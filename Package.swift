// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentDock", targets: ["AgentDock"]),
        .executable(name: "AgentDockScan", targets: ["AgentDockScan"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentDockCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AgentDock", dependencies: ["AgentDockCore"]),
        .executableTarget(name: "AgentDockScan", dependencies: ["AgentDockCore"]),
        .testTarget(name: "AgentDockCoreTests", dependencies: ["AgentDockCore", "CSQLite"])
    ]
)
