// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Vendored into Whispera (see Packages/VENDORED.md): Hub and Tokenizers only. Generation, Models,
// the Transformers product and the test targets were removed; dependencies are local paths.

import PackageDescription

/// Define the strict concurrency settings to be applied to all targets.
let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "swift-transformers",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Hub", targets: ["Hub"]),
        .library(name: "Tokenizers", targets: ["Tokenizers"]),
    ],
    dependencies: [
        .package(path: "../swift-jinja"),
        .package(path: "../swift-collections"),
        .package(path: "../swift-crypto"),
        .package(path: "../yyjson"),
    ],
    targets: [
        .target(
            name: "Hub",
            dependencies: [
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "yyjson", package: "yyjson"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "Tokenizers", dependencies: ["Hub", .product(name: "Jinja", package: "swift-jinja")]),
    ]
)
