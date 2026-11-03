// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Vendored into Whispera (see Packages/VENDORED.md): test target removed; dependencies are local paths.

import PackageDescription

let package = Package(
    name: "Jinja",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Jinja",
            targets: ["Jinja"]
        )
    ],
    dependencies: [
        .package(path: "../swift-collections")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Jinja",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections")
            ]
        ),
    ]
)
