// swift-tools-version: 5.9
import PackageDescription

// The Mac side of whispera-link, ported from the v1 Python daemon. A package of its own so the
// protocol logic builds and tests with `swift test` in seconds, without the app, WhisperKit or
// a signing identity. The login-item app target links `LinkHelperCore` and adds the on-device
// speech engine; the main app links only `LinkHelperXPC`.
//
// Every dependency is a vendored copy under ../Packages (see Packages/VENDORED.md), the same
// directories the Xcode project references, so both builds share one package identity each.
let package = Package(
	name: "WhisperaLinkHelper",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "LinkHelperCore", targets: ["LinkHelperCore"]),
		.library(name: "LinkHelperXPC", targets: ["LinkHelperXPC"]),
	],
	dependencies: [
		.package(path: "../Packages/whispera-components"),
		.package(path: "../Packages/agent-tui-protocol"),
		.package(path: "../Packages/agent-herdr"),
		.package(path: "../Packages/agent-tmux"),
	],
	targets: [
		.target(name: "LinkHelperXPC"),
		// forkpty + exec for the phone's terminal view: Swift cannot fork safely on its own.
		.target(name: "LinkHelperPTY"),
		.target(
			name: "LinkHelperCore",
			dependencies: [
				"LinkHelperXPC",
				"LinkHelperPTY",
				.product(name: "WhisperaLink", package: "whispera-components"),
				.product(name: "WhisperaLinkServer", package: "whispera-components"),
				.product(name: "WhisperaHerdr", package: "agent-herdr"),
				.product(name: "WhisperaAgents", package: "agent-tui-protocol"),
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
		.testTarget(name: "LinkHelperCoreTests", dependencies: ["LinkHelperCore", "LinkHelperXPC"], resources: [.copy("Fixtures")]),
	]
)
