// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agentilo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Agentilo", targets: ["Agentilo"]),
    ],
    targets: [
        .target(
            name: "AgentiloCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Agentilo",
            dependencies: ["AgentiloCore"]
        ),
        .testTarget(
            name: "AgentiloCoreTests",
            dependencies: ["AgentiloCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
