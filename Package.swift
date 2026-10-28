// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpacetimeDB",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2),
        .watchOS(.v11)
    ],
    products: [
        .library(
            name: "SpacetimeDB",
            targets: ["SpacetimeDB"]
        ),
        .plugin(
            name: "SpacetimeDBCodegenPlugin",
            targets: ["SpacetimeDBCodegenPlugin"]
        ),
    ],
    targets: [
        .target(
            name: "SpacetimeDB"
        ),
        .plugin(
            name: "SpacetimeDBCodegenPlugin",
            capability: .buildTool()
        ),
        .testTarget(
            name: "SpacetimeDBTests",
            dependencies: ["SpacetimeDB"]
        ),
    ]
)
