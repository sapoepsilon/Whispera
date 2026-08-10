// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Testing

@testable import Whispera

/// The `auto` engine's resolution policy, exercised as a pure function of
/// what discovery found — no network, no backend, no MainActor. See WHI-58
/// and AUTOCHOOSE-RESULT.md for the decision table this pins.
struct AutoEnginePolicyTests {
	private static func server(
		id: String,
		label: String? = nil,
		isOnline: Bool = true,
		supportsRealtime: Bool = true,
		isDefault: Bool = false,
		granularity: StreamingGranularity = .utterance
	) -> DiscoveredServer {
		DiscoveredServer(
			id: id, label: label ?? id, isOnline: isOnline, supportsRealtime: supportsRealtime,
			isDefault: isDefault, granularity: granularity)
	}

	// MARK: - No server to talk to

	@Test func noURLConfiguredGoesLocalWithoutAttemptingDiscovery() {
		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: false, pinnedServerId: "",
			discovery: .unavailable(reason: "no transcription server configured"))

		#expect(resolution == .local(reason: "no transcription server configured"))
	}

	@Test func discoveryFailureGoesLocal() {
		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "",
			discovery: .unavailable(reason: "backend unreachable"))

		#expect(resolution == .local(reason: "backend unreachable"))
	}

	@Test func noUsableServerInTheListGoesLocal() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "offline-one", isOnline: false),
			Self.server(id: "no-realtime", supportsRealtime: false),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(resolution == .local(reason: "no realtime server available"))
	}

	// MARK: - Granularity ranking

	@Test func nativeDeltaBeatsSynthesizedBeatsUtterance() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "utterance-only", granularity: .utterance),
			Self.server(id: "synthesized", granularity: .synthesizedDelta),
			Self.server(id: "native", granularity: .nativeDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(resolution == .server(id: "native", label: "native", granularity: .nativeDelta))
	}

	@Test func synthesizedBeatsUtteranceWithNoNativeOnOffer() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "utterance-only", granularity: .utterance),
			Self.server(id: "synthesized", granularity: .synthesizedDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(
			resolution == .server(id: "synthesized", label: "synthesized", granularity: .synthesizedDelta)
		)
	}

	/// Absent `granularity` (an older backend, or one whose delta-synthesis
	/// hasn't landed) reads as `.utterance` — the worst case, not the best.
	@Test func absentGranularityDegradesToUtteranceRatherThanWinning() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "unlabeled"),
			Self.server(id: "synthesized", granularity: .synthesizedDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(
			resolution == .server(id: "synthesized", label: "synthesized", granularity: .synthesizedDelta)
		)
	}

	@Test func aTieInGranularityPrefersTheBackendsOwnDefault() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "alpha", isDefault: false, granularity: .synthesizedDelta),
			Self.server(id: "beta", isDefault: true, granularity: .synthesizedDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(resolution == .server(id: "beta", label: "beta", granularity: .synthesizedDelta))
	}

	// MARK: - Pinning

	@Test func aPinnedServerWinsEvenOverBetterGranularityElsewhere() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "native", granularity: .nativeDelta),
			Self.server(id: "pinned", granularity: .utterance),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "pinned", discovery: discovery)

		#expect(resolution == .server(id: "pinned", label: "pinned", granularity: .utterance))
	}

	/// A pin that no longer names a usable server (renamed, offline, dropped
	/// realtime support) is not a dead end — falls through to the normal
	/// ranking instead of going local outright.
	@Test func aPinThatIsNoLongerUsableFallsThroughToRanking() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "native", granularity: .nativeDelta),
			Self.server(id: "pinned-but-offline", isOnline: false),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "pinned-but-offline", discovery: discovery)

		#expect(resolution == .server(id: "native", label: "native", granularity: .nativeDelta))
	}

	// MARK: - Summary text

	@Test func theSummaryNamesTheChoiceAndWhy() {
		#expect(
			AutoEngineResolution.server(id: "speaches-lan", label: "speaches-lan", granularity: .synthesizedDelta)
				.summary == "auto: server speaches-lan (synthesized-delta)")
		#expect(
			AutoEngineResolution.local(reason: "backend unreachable").summary
				== "auto: local WhisperKit (backend unreachable)")
	}
}
