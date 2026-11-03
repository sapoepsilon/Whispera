// swift-tools-version: 5.9
import PackageDescription

// This manifest sits at the repository root rather than in `apple/` because
// SwiftPM only resolves a remote dependency whose Package.swift is at the root
// of the checkout. The Swift sources still live under `apple/` next to the web
// ports, so every target carries an explicit `path:` — one manifest, no second
// copy under `apple/` to drift out of step with this one.
//
// Vendored into Whispera (see Packages/VENDORED.md): trimmed to the products the
// Mac app and its link helper link. WhisperaComponents, WhisperaDictationUI, the
// demo and self-test executables and every test target were removed.
let package = Package(
	name: "whispera-components",
	// iOS first on purpose: a macOS-only package defeats the point of extracting
	// these at all. Metal and SwiftUI cover both; the AppKit-bound parts of the
	// original are shimmed rather than shipped.
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [
		// Two dictation products, not one, because a host can take the transport and
		// drive its own UI. A single library would force every host that only wants
		// text to link SwiftUI views it never renders.
		.library(name: "WhisperaDictation", targets: ["WhisperaDictation"]),
		// One client for every OpenAI-compatible server. Separate from the
		// dictation transport because a host can want batch transcription or a
		// chat call without ever opening a socket.
		.library(name: "WhisperaOpenAI", targets: ["WhisperaOpenAI"]),
		// Recipes are prompt templates with a trigger phrase. The product exists
		// so a host gets them without linking anything that knows a backend
		// exists — which is the whole reason they were extracted.
		.library(name: "WhisperaRecipes", targets: ["WhisperaRecipes"]),
		// Deliberately last, deliberately alone: the only product that knows the
		// Whispera backend's shape. Nothing else in this package imports it, and
		// a host that removes it must still build.
		.library(name: "WhisperaBackend", targets: ["WhisperaBackend"]),
		// The Mac <-> iPhone link protocol: WL1 request signing, device keys,
		// pairing, approvals, the daemon client, and the end-to-end sealed
		// envelope the relay carries. Foundation, CryptoKit, Security and
		// LocalAuthentication only — no UIKit, no AppKit — so the iPhone app, the
		// Mac app and its login helper all link the same bytes.
		.library(name: "WhisperaLink", targets: ["WhisperaLink"]),
		// The receiving side: verifying incoming WL1 requests and remembering
		// nonces. Separate so a phone never links server code it does not run.
		.library(name: "WhisperaLinkServer", targets: ["WhisperaLinkServer"]),
		// Signing into a Whispera account: OpenID Connect with PKCE (hosted or
		// self-hosted issuer) or a pasted server token, the token store, and
		// refresh. Foundation, CryptoKit, Security and AuthenticationServices only,
		// and nothing from WhisperaLink: it yields a bearer string, which is all
		// the device registry needs.
		.library(name: "WhisperaAccount", targets: ["WhisperaAccount"]),
	],
	targets: [
		// Deliberately depends on nothing — not even WhisperaComponents. That target
		// carries Metal, which `swift build` cannot compile; a transport that needed
		// it would be unbuildable under Command Line Tools for no benefit.
		// Foundation and AVFoundation are the whole dependency list.
		.target(name: "WhisperaDictation", path: "apple/Sources/WhisperaDictation"),

		// Foundation and Security, nothing else. Notably not WhisperaDictation:
		// an HTTP client that had to link an audio transport to make a chat call
		// would be the wrong shape for every host that only wants one of them.
		.target(name: "WhisperaOpenAI", path: "apple/Sources/WhisperaOpenAI"),

		// Depends on WhisperaOpenAI and on nothing that knows a backend exists.
		// `grep -r WhisperaBackend Sources/WhisperaRecipes` returning nothing is
		// a standing acceptance criterion, not an accident of the current code.
		.target(name: "WhisperaRecipes", dependencies: ["WhisperaOpenAI"], path: "apple/Sources/WhisperaRecipes"),

		// The thin layer, parked. It depends on the other three rather than the
		// other way round, which is what lets a host drop it entirely.
		.target(
			name: "WhisperaBackend",
			dependencies: ["WhisperaDictation", "WhisperaOpenAI", "WhisperaRecipes"],
			path: "apple/Sources/WhisperaBackend"
		),

		// Depends on nothing else in this package: the link has no business
		// knowing about dictation, a chat client, or the Whispera backend's
		// transcription API.
		.target(name: "WhisperaLink", path: "apple/Sources/WhisperaLink"),
		.target(
			name: "WhisperaLinkServer",
			dependencies: ["WhisperaLink"],
			path: "apple/Sources/WhisperaLinkServer"
		),
		.target(name: "WhisperaAccount", path: "apple/Sources/WhisperaAccount"),
	]
)
