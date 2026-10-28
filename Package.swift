// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agentilo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Agentilo", targets: ["Agentilo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "AgentiloCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Agentilo",
            dependencies: ["AgentiloCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "AgentiloCoreTests",
            dependencies: ["AgentiloCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
