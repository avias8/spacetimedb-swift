// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpacetimeDBBenchmarks",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(name: "spacetimedb-swift", path: ".."),
        .package(
            url: "https://github.com/ordo-one/benchmark",
            from: "1.30.0",
            traits: []
        ),
    ],
    targets: [
        .executableTarget(
            name: "SpacetimeDBBenchmarks",
            dependencies: [
                .product(name: "SpacetimeDB", package: "spacetimedb-swift"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "SpacetimeDBBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
        .executableTarget(
            name: "GeneratedBindingsBenchmarks",
            dependencies: [
                .product(name: "SpacetimeDB", package: "spacetimedb-swift"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "GeneratedBindingsBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
