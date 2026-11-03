// swift-tools-version:6.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftCrypto open source project
//
// Copyright (c) 2019-2023 Apple Inc. and the SwiftCrypto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftCrypto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// This package contains a vendored copy of BoringSSL. For ease of tracking
// down problems with the copy of BoringSSL in use, we include a copy of the
// commit hash of the revision of BoringSSL included in the given release.
// This is also reproduced in a file called hash.txt in the
// Sources/CCryptoBoringSSL directory. The source repository is at
// https://boringssl.googlesource.com/boringssl.
//
// BoringSSL Commit: 0226f30467f540a3f62ef48d453f93927da199b6

import PackageDescription

// Vendored into Whispera (see Packages/VENDORED.md), which builds only for macOS. On Apple
// platforms `Crypto` re-exports CryptoKit, so the BoringSSL and XKCP targets it links on Linux,
// Android, Windows, WASI and OpenBSD were removed together with CryptoExtras, _CryptoExtras,
// crypto-shasum, the tests, and the swift-asn1 dependency that only CryptoExtras used.
let swiftSettings: [SwiftSetting] = [
    .define("CRYPTO_IN_SWIFTPM"),
]
let dependencies: [Target.Dependency] = []

// This doesn't work when cross-compiling: the privacy manifest will be included in the Bundle and
// Foundation will be linked. This is, however, strictly better than unconditionally adding the
// resource.
#if canImport(Darwin)
let privacyManifestExclude: [String] = []
let privacyManifestResource: [PackageDescription.Resource] = [.copy("PrivacyInfo.xcprivacy")]
#else
// Exclude on other platforms to avoid build warnings.
let privacyManifestExclude: [String] = ["PrivacyInfo.xcprivacy"]
let privacyManifestResource: [PackageDescription.Resource] = []
#endif

let package = Package(
    name: "swift-crypto",
    products: [
        .library(name: "Crypto", targets: ["Crypto"]),
    ],
    targets: [
        .target(
            name: "Crypto",
            dependencies: dependencies,
            exclude: privacyManifestExclude + [
                "CMakeLists.txt",
                "AEADs/Nonces.swift.gyb",
                "Digests/Digests.swift.gyb",
                "Key Agreement/ECDH.swift.gyb",
                "Signatures/ECDSA.swift.gyb",
                "Signatures/MLDSA.swift.gyb",
                "Signatures/BoringSSL/MLDSA_boring.swift.gyb",
                "KEM/MLKEM.swift.gyb",
                "KEM/BoringSSL/MLKEM_boring.swift.gyb",
            ],
            resources: privacyManifestResource,
            swiftSettings: swiftSettings
        ),
    ],
    cxxLanguageStandard: .cxx17
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
