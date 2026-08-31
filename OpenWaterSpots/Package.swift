// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWaterSpots",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "OpenWaterSpots", targets: ["OpenWaterSpots"])
    ],
    dependencies: [
        .package(path: "../OpenWaterCore")
    ],
    targets: [
        .target(
            name: "OpenWaterSpots",
            dependencies: ["OpenWaterCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenWaterSpotsTests",
            dependencies: ["OpenWaterSpots"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
