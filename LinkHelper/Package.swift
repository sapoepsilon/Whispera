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
			revision: "1f15ab9c7f53e2180348a7e0a3861acc54354a9a"),
		.package(url: "https://github.com/sapoepsilon/agent-tui-protocol", revision: "c17ca27cdc54a311d310cb8da532734634026cbd"),
        .package(url: "https://github.com/sapoepsilon/agent-herdr", revision: "631e50ebb8b77ab1db6105b31cc5127eb1b97616"),
        .package(url: "https://github.com/sapoepsilon/agent-tmux", revision: "a6caf9dd203b3c1d08218d5fd2457363ec3454ea")
	],
	targets: [
		.target(name: "LinkHelperXPC"),
		.target(
			name: "LinkHelperCore",
			dependencies: [
				"LinkHelperXPC",
				.product(name: "WhisperaLink", package: "whispera-components"),
				.product(name: "WhisperaLinkServer", package: "whispera-components"),
				.product(name: "WhisperaHerdr", package: "agent-herdr"),
                .product(name: "WhisperaTmux", package: "agent-tmux"),
				.product(name: "WhisperaRecipes", package: "whispera-components"),
				.product(name: "WhisperaOpenAI", package: "whispera-components"),
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
