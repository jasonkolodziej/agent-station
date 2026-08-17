// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentStation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentStationCore", targets: ["AgentStationCore"]),
        .executable(name: "agentstationd", targets: ["agentstationd"]),
        .executable(name: "station", targets: ["station"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgentStationCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("../../Resources/migrations")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(name: "agentstationd", dependencies: ["AgentStationCore"]),
        .executableTarget(
            name: "station",
            dependencies: [
                "AgentStationCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AgentStationCoreTests",
            dependencies: ["AgentStationCore"],
            resources: [.copy("../../fixtures")]
        ),
    ]
)
