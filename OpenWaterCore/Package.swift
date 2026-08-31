// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWaterCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "OpenWaterCore", targets: ["OpenWaterCore"])
    ],
    targets: [
        .target(
            name: "OpenWaterCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenWaterCoreTests",
            dependencies: ["OpenWaterCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
