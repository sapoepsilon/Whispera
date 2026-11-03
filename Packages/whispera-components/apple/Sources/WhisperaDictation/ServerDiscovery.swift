import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

/// How close to real-time a server's words arrive.
///
/// Ranked, because a host choosing for the user should prefer the best delta
/// quality on offer: an engine that streams natively beats one whose deltas the
/// proxy synthesises, which beats a server that only returns whole utterances.
///
/// Absent or unrecognised reads as `.utterance`, the worst case — an older
/// backend simply looks like it has no live words, rather than being assumed to
/// have the best kind and then disappointing.
public enum StreamingGranularity: String, Sendable, Equatable, Codable {
	case nativeDelta = "native-delta"
	case synthesizedDelta = "synthesized-delta"
	case utterance

	public static func from(_ raw: String?) -> StreamingGranularity {
		raw.flatMap(StreamingGranularity.init(rawValue:)) ?? .utterance
	}

	/// Lower sorts first: native beats synthesized beats utterance-only.
	public var rank: Int {
		switch self {
		case .nativeDelta: return 0
		case .synthesizedDelta: return 1
		case .utterance: return 2
		}
	}
}

/// One transcription server the backend is willing to proxy to.
///
/// Note what is absent: the engine's address and its API key. The backend holds
/// both and never serialises either, which is the reason a client goes through it
/// at all.
public struct DictationServer: Sendable, Equatable, Decodable {
	public struct Realtime: Sendable, Equatable, Decodable {
		public let `protocol`: String
		/// Path *and* query, to be appended to the backend origin — it already
		/// carries `?server=<id>`.
		public let path: String
		public let audio: Audio?

		public struct Audio: Sendable, Equatable, Decodable {
			public let encoding: String
			public let sampleRate: Int
			public let channels: Int
		}

		/// How close to real time this server's words arrive: `native-delta`,
		/// `synthesized-delta`, or `utterance`. Optional because a backend that
		/// predates the field simply does not say.
		public let granularity: String?
	}

	public let id: String
	public let label: String
	public let model: String
	public let capabilities: [String]
	public let status: String?
	/// Why a server is not online, when it is not.
	public let detail: String?
	/// Absent when the server cannot do realtime at all.
	public let realtime: Realtime?
	public let `default`: Bool?

	public var supportsRealtime: Bool { capabilities.contains("realtime") }
	public var isOnline: Bool { status == nil || status == "online" }
	/// A server with no realtime block at all cannot stream, so it can only be
	/// the worst case — not an absent one.
	public var granularity: StreamingGranularity { .from(realtime?.granularity) }
	public var isDefault: Bool { `default` == true }

	/// The PCM this particular server wants, or the package default when it
	/// does not say.
	///
	/// Reading this rather than `DictationAudioFormat.engine` is the whole
	/// point of the field being on the wire: two engines behind one backend do
	/// not have to agree on a sample rate, and one that does not agree is not
	/// rejected — speaches silently time-compresses mismatched audio, which
	/// produces a plausible-looking wrong transcript rather than an error. An
	/// unrecognised encoding falls back to the default rather than guessing:
	/// `pcm16` is the only encoding this package can put on the wire. See
	/// WHI-71.
	public var audioFormat: DictationAudioFormat {
		guard let audio = realtime?.audio, audio.sampleRate > 0, audio.channels > 0,
			audio.encoding.lowercased().hasPrefix("pcm16")
		else {
			return .engine
		}
		return DictationAudioFormat(
			sampleRate: audio.sampleRate, channels: audio.channels, encoding: .pcm16)
	}
}

extension Sequence where Element == DictationServer {
	/// Usable servers, best delta quality first.
	///
	/// Ties break on the backend's own default flag and then on id, so the same
	/// list always produces the same choice — a picker that shuffled between two
	/// equally good servers would make every latency measurement unrepeatable.
	public func rankedForRealtime() -> [DictationServer] {
		filter { $0.supportsRealtime && $0.isOnline }
			.sorted { lhs, rhs in
				if lhs.granularity.rank != rhs.granularity.rank {
					return lhs.granularity.rank < rhs.granularity.rank
				}
				if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
				return lhs.id < rhs.id
			}
	}
}

/// `GET /transcription/servers`.
///
/// Worth having in the package rather than leaving to the host: picking a server
/// means knowing that `realtime` must be among its capabilities and that an
/// offline one is still listed. Encoding that once here is better than every host
/// rediscovering it.
public struct DictationServerDirectory: Sendable {
	private let baseURL: URL
	private let credentials: DictationCredentialProvider
	private let session: URLSession

	public init(
		baseURL: URL,
		credentials: DictationCredentialProvider,
		session: URLSession = .shared
	) {
		self.baseURL = baseURL
		self.credentials = credentials
		self.session = session
	}

	private struct Response: Decodable { let servers: [DictationServer] }

	public func servers() async throws -> [DictationServer] {
		let credential = try await credentials.credential()

		// Query items as well as headers. A provider that authenticates by query
		// parameter — which is half of what `DictationCredential` exists to express —
		// would otherwise stream fine and get a 401 from discovery alone.
		guard
			var components = URLComponents(
				url: baseURL.appendingPathComponent("transcription/servers"),
				resolvingAgainstBaseURL: false)
		else {
			throw DictationError.connectionFailed("the discovery URL is not valid")
		}
		if !credential.queryItems.isEmpty {
			let existing = components.queryItems ?? []
			components.queryItems = existing + credential.queryItems
		}
		guard let url = components.url else {
			throw DictationError.connectionFailed("the credential's query items produced an invalid URL")
		}
		var request = URLRequest(url: url)
		for (name, value) in credential.headers { request.setValue(value, forHTTPHeaderField: name) }

		let (data, response) = try await session.data(for: request)
		if let http = response as? HTTPURLResponse {
			if http.statusCode == 401 || http.statusCode == 403 { throw DictationError.unauthorized }
			guard (200..<300).contains(http.statusCode) else {
				throw DictationError.connectionFailed("discovery returned HTTP \(http.statusCode)")
			}
		}
		do {
			return try JSONDecoder().decode(Response.self, from: data).servers
		} catch {
			throw DictationError.protocolViolation("could not decode the server list: \(error)")
		}
	}

	/// The server a host should use absent any preference: the backend's default
	/// if it can do realtime and is up, otherwise the first that can.
	public func preferredRealtimeServer() async throws -> DictationServer? {
		let servers = try await servers()
		let usable = servers.filter { $0.supportsRealtime && $0.isOnline }
		return usable.first { $0.default == true } ?? usable.first
	}

	/// The server a host should use when it cares about how live the words look:
	/// best granularity first, the backend's default only as a tie-break. Kept
	/// separate from `preferredRealtimeServer()` so an existing caller's choice
	/// does not change under it.
	public func bestRealtimeServer() async throws -> DictationServer? {
		try await servers().rankedForRealtime().first
	}
}
