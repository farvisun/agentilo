// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLimits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentLimits", targets: ["AgentLimits"]),
    ],
    targets: [
        .target(
            name: "AgentLimitsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AgentLimits",
            dependencies: ["AgentLimitsCore"]
        ),
        .testTarget(
            name: "AgentLimitsCoreTests",
            dependencies: ["AgentLimitsCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
