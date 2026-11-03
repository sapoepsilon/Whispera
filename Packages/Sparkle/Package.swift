// swift-tools-version:5.3
import PackageDescription

// Vendored into Whispera (see Packages/VENDORED.md). Upstream's manifest points a binaryTarget at
// the Sparkle-for-Swift-Package-Manager.zip release asset; this one points at that asset's
// unpacked Sparkle.xcframework instead. bin/sign_update and bin/generate_keys come from the same
// zip and are what scripts/release-distribute-ci.sh and scripts/generate-sparkle-keys.sh run.
let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "Sparkle",
            targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework"
        )
    ]
)
