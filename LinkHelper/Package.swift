// swift-tools-version: 5.9
import PackageDescription

// The Mac side of whispera-link, ported from the v1 Python daemon. A package of its own so the
// protocol logic builds and tests with `swift test` in seconds, without the app, WhisperKit or
// a signing identity. The login-item app target links `LinkHelperCore` and adds the on-device
// speech engine; the main app links only `LinkHelperXPC`.
//
// whispera-components is pinned to the same revision as the Xcode project's reference: SwiftPM
// refuses two different requirements for one package identity.
let package = Package(
	name: "WhisperaLinkHelper",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "LinkHelperCore", targets: ["LinkHelperCore"]),
		.library(name: "LinkHelperXPC", targets: ["LinkHelperXPC"]),
	],
	dependencies: [
		.package(
			url: "https://github.com/sapoepsilon/whispera-components",
			revision: "fa1be6cf73bfe6cb684f8c3eccc14cbe75760f88")
	],
	targets: [
		.target(name: "LinkHelperXPC"),
		.target(
			name: "LinkHelperCore",
			dependencies: [
				"LinkHelperXPC",
				.product(name: "WhisperaLink", package: "whispera-components"),
				.product(name: "WhisperaLinkServer", package: "whispera-components"),
			]
		),
		// The helper without the speech engine, for `swift run` and the e2e scripts on a machine
		// that has not built the app. The shipped helper is the login-item app target.
		.executableTarget(name: "link-helper-serve", dependencies: ["LinkHelperCore"]),
		// A software-key phone for the e2e scripts: pairing v2 (commit, then reveal) and WL1-signed
		// calls against a standalone helper. Never the app's or the iPhone's keys.
		.executableTarget(
			name: "link-soft-phone",
			dependencies: [.product(name: "WhisperaLink", package: "whispera-components")]),
		.testTarget(name: "LinkHelperCoreTests", dependencies: ["LinkHelperCore", "LinkHelperXPC"]),
	]
)
