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
			revision: "da80e3b3247dec9c561396452b88d5d301eecbbe")
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
		.testTarget(name: "LinkHelperCoreTests", dependencies: ["LinkHelperCore"]),
	]
)
