// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Vendored into Whispera (see Packages/VENDORED.md): the cmark-gfm-bin and api_test executables
// were removed with their sources.

import PackageDescription

#if os(Windows)
    // When building the library on Windows, we do not have proper control of
    // whether it is being built statically or dynamically.  However, given the
    // current default of static, we will assume that we are building
    // statically.  More importantly, should this not hold, this will fail at
    // link time.
    let cSettings: [CSetting] = [
        .define("CMARK_GFM_STATIC_DEFINE", .when(platforms: [.windows])),
    ]
#else
    let cSettings: [CSetting] = []
#endif

let package = Package(
    name: "cmark-gfm",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "cmark-gfm",
            targets: ["cmark-gfm"]),
        .library(
            name: "cmark-gfm-extensions",
            targets: ["cmark-gfm-extensions"]),
    ],
    targets: [
        .target(name: "cmark-gfm",
          path: "src",
          exclude: [
            "scanners.re",
            "libcmark-gfm.pc.in",
            "config.h.in",
            "CMakeLists.txt",
          ],
          cSettings: cSettings
        ),
        .target(name: "cmark-gfm-extensions",
          dependencies: [
            "cmark-gfm",
          ],
          path: "extensions",
          exclude: [
            "CMakeLists.txt",
            "ext_scanners.re",
          ],
          cSettings: cSettings
        ),
    ]
)
