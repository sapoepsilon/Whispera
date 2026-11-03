import Foundation
import WhisperaDictation

/// What discovery produced, kept separate from *why* it produced nothing, so
/// the policy can say something more useful than "unavailable".
public enum AutoDiscoveryOutcome: Equatable, Sendable {
	case unavailable(reason: String)
	case servers([DictationServer])
}

/// What the policy decided, and — for a remote pick — which server and how good
/// its deltas are, so a caller can both connect and explain the choice.
public enum AutoEngineResolution: Equatable, Sendable {
	case local(reason: String)
	case server(id: String, label: String, granularity: StreamingGranularity)

	/// One line naming the choice and why.
	public var summary: String {
		switch self {
		case .local(let reason):
			return "auto: local engine (\(reason))"
		case .server(_, let label, let granularity):
			return "auto: server \(label) (\(granularity.rawValue))"
		}
	}
}

/// Local versus a specific server, as a pure function of what discovery found.
///
/// Kept apart from the network and the caching around it so the whole decision
/// table is exercisable without a backend at all — which is the only way to pin
/// a policy whose inputs are otherwise a live server list.
public enum AutoEnginePolicy {
	public static func resolve(
		serverURLConfigured: Bool,
		pinnedServerId: String,
		discovery: AutoDiscoveryOutcome
	) -> AutoEngineResolution {
		guard serverURLConfigured else {
			return .local(reason: "no transcription server configured")
		}
		guard case .servers(let servers) = discovery else {
			if case .unavailable(let reason) = discovery { return .local(reason: reason) }
			return .local(reason: "backend unreachable")
		}

		let ranked = servers.rankedForRealtime()
		guard let best = ranked.first else {
			return .local(reason: "no realtime server available")
		}

		// A pin that is not currently usable falls through to the ranking rather
		// than to local: the user asked for a server, and another working one is
		// closer to that than on-device is.
		if !pinnedServerId.isEmpty, let pinned = ranked.first(where: { $0.id == pinnedServerId }) {
			return .server(id: pinned.id, label: pinned.label, granularity: pinned.granularity)
		}
		return .server(id: best.id, label: best.label, granularity: best.granularity)
	}
}
