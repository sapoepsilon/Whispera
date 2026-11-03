import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// Every way a call to an OpenAI-compatible endpoint can fail, split by who is
/// at fault: the configuration, the network, the server, or the payload.
///
/// The split matters because only one of these categories is worth retrying —
/// see `OpenAITransportRetryPolicy` — and because a host that shows the raw
/// `localizedDescription` of a URLError to a user is showing them the wrong
/// sentence.
public enum OpenAIError: LocalizedError, Equatable {
	/// No model named on the request and none configured as the default.
	case noModel
	/// The server could not be reached at all. `retried` records whether the one
	/// bounded retry was spent, so the message can say so.
	case unreachable(url: String, reason: String, retried: Bool)
	/// The server answered, with a status outside 2xx. Never retried: an answer
	/// is an answer.
	case http(status: Int, body: String)
	/// A 2xx with nothing usable in it.
	case empty
	/// A 2xx whose body did not match the shape the endpoint documents.
	case decoding(String)
	/// `/models` answered, but nothing it serves matches the requested task.
	case noModelsAvailable(String)

	public var errorDescription: String? {
		switch self {
		case .noModel:
			return "No model set. Choose a model, or set one on the request."
		case .unreachable(let url, let reason, let retried):
			return "Couldn't reach the model server at \(url) — \(reason)."
				+ (retried ? " Retried once." : "")
		case .http(let status, let body):
			return "Model server error (HTTP \(status))\(body.isEmpty ? "" : ": \(body)")"
		case .empty:
			return "The model returned an empty response."
		case .decoding(let detail):
			return "The model server's response could not be read: \(detail)"
		case .noModelsAvailable(let destination):
			return "\(destination) serves no model that can do this."
		}
	}
}

/// Classifies transport failures: which ones earn the single retry, and the
/// short phrase a HUD can show for them. Pure — no network, no state — so the
/// whole decision table is testable on its own.
public enum OpenAITransportRetryPolicy {
	/// Transient conditions where the server may simply be waking up or the
	/// route flickered. HTTP status codes never come through here (they are real
	/// answers from a reachable server), and cancellation, TLS refusals, bad
	/// URLs and the like are not transient, so none of them retry.
	public static let retryableCodes: Set<URLError.Code> = [
		.timedOut,
		.cannotConnectToHost,
		.cannotFindHost,
		.dnsLookupFailed,
		.networkConnectionLost,
		.notConnectedToInternet,
	]

	public static func shouldRetry(_ code: URLError.Code) -> Bool {
		retryableCodes.contains(code)
	}

	/// HUD-sized phrasing for the common transport failures; anything else falls
	/// back to the system's own description.
	public static func shortReason(for error: URLError) -> String {
		switch error.code {
		case .timedOut: return "the request timed out"
		case .cannotConnectToHost: return "the connection was refused"
		case .cannotFindHost, .dnsLookupFailed: return "the host was not found"
		case .networkConnectionLost: return "the connection was lost"
		case .notConnectedToInternet: return "the network is offline"
		default: return error.localizedDescription
		}
	}
}
