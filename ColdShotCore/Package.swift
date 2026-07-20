// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ColdShotCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ColdShotCore", targets: ["ColdShotCore"])
    ],
    targets: [
        .target(
            name: "ColdShotCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ColdShotCoreTests",
            dependencies: ["ColdShotCore"]
        )
    ]
)
