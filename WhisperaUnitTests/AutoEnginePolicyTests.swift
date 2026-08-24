// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaDictation

@testable import Whispera

/// The `auto` engine's resolution policy, exercised as a pure function of
/// what discovery found — no network, no backend, no MainActor. See WHI-58
/// and AUTOCHOOSE-RESULT.md for the decision table this pins.
struct AutoEnginePolicyTests {
	/// `DictationServer` is `Decodable` with no memberwise initialiser — it is a
	/// wire type, and the package deliberately does not offer a way to
	/// hand-assemble one. Building fixtures through the decoder is therefore not
	/// a workaround: it also pins that the JSON shape the backend sends is the
	/// one the policy ranks.
	private static func server(
		id: String,
		label: String? = nil,
		isOnline: Bool = true,
		supportsRealtime: Bool = true,
		granularity: StreamingGranularity = .utterance,
		isDefault: Bool = false
	) -> DictationServer {
		let realtime =
			supportsRealtime
			? #"{"protocol":"openai-realtime","path":"/s","granularity":"\#(granularity.rawValue)"}"#
			: "null"
		let json = """
			{
				"id": "\(id)",
				"label": "\(label ?? id)",
				"model": "",
				"capabilities": [\(supportsRealtime ? "\"realtime\"" : "")],
				"status": "\(isOnline ? "online" : "offline")",
				"realtime": \(realtime),
				"default": \(isDefault)
			}
			"""
		return try! JSONDecoder().decode(DictationServer.self, from: Data(json.utf8))
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
			Self.server(id: "alpha", granularity: .synthesizedDelta, isDefault: false),
			Self.server(id: "beta", granularity: .synthesizedDelta, isDefault: true),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(resolution == .server(id: "beta", label: "beta", granularity: .synthesizedDelta))
	}

	// MARK: - The engine-family pin (WHI-74)

	/// The pin itself. nemo-stream advertises `native-delta`, which is the best
	/// granularity on offer and would win the ranking outright — and it is the
	/// one engine whose delta contract is known to be broken (WHI-67). Until that
	/// contract is verified end to end, speaches wins even while advertising
	/// worse deltas. Owner's call, 2026-08-18: "default = on-device WhisperKit,
	/// auto prefers speaches over nemo-stream".
	@Test func speachesOutranksNemoStreamDespiteWorseAdvertisedDeltas() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "nemo-stream", label: "NeMo", granularity: .nativeDelta),
			Self.server(id: "speaches-lan", label: "speaches", granularity: .synthesizedDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(
			resolution == .server(
				id: "speaches-lan", label: "speaches", granularity: .synthesizedDelta))
	}

	/// The pin demotes nemo-stream below *every* other usable server, not just
	/// below speaches — an unknown server matching neither fragment sits between
	/// the two.
	@Test func nemoStreamRanksLastAmongUsableServers() {
		#expect(AutoEnginePolicy.familyRank(of: "speaches-lan") == 0)
		#expect(AutoEnginePolicy.familyRank(of: "some-other-engine") == 1)
		#expect(AutoEnginePolicy.familyRank(of: "nemo-stream") == 2)

		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "nemo-stream", granularity: .nativeDelta, isDefault: true),
			Self.server(id: "unknown-engine", granularity: .utterance),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(
			resolution == .server(id: "unknown-engine", label: "unknown-engine", granularity: .utterance))
	}

	/// nemo-stream is demoted, not banned: with nothing else reachable it is
	/// still better than no live words at all.
	@Test func nemoStreamIsStillChosenWhenItIsTheOnlyServer() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "nemo-stream", label: "NeMo", granularity: .nativeDelta)
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "", discovery: discovery)

		#expect(resolution == .server(id: "nemo-stream", label: "NeMo", granularity: .nativeDelta))
	}

	/// A user who pinned nemo-stream by hand still gets it — the pin above is a
	/// default, not a policy about what a user is allowed to choose.
	@Test func anExplicitPinStillBeatsTheEngineFamilyPreference() {
		let discovery = AutoDiscoveryOutcome.servers([
			Self.server(id: "speaches-lan", granularity: .synthesizedDelta),
			Self.server(id: "nemo-stream", granularity: .nativeDelta),
		])

		let resolution = AutoEnginePolicy.resolve(
			serverURLConfigured: true, pinnedServerId: "nemo-stream", discovery: discovery)

		#expect(
			resolution == .server(id: "nemo-stream", label: "nemo-stream", granularity: .nativeDelta))
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
