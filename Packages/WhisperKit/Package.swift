// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Vendored into Whispera (see Packages/VENDORED.md): WhisperKit only. TTSKit, SpeakerKit, the
// CLI and its server mode, and the test targets were removed; dependencies are local paths.

import PackageDescription

let package = Package(
    name: "whisperkit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "WhisperKit",
            targets: ["WhisperKit"]
        ),
    ],
    dependencies: [
        .package(path: "../swift-transformers"),
    ],
    targets: [
        .target(
            name: "ArgmaxCore",
            dependencies: [
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "WhisperKit",
            dependencies: [
                "ArgmaxCore",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
