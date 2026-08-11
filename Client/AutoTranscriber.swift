// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaDictation

/// How close to real-time a server's words arrive. Ranked so `auto` can prefer
/// the best available delta quality when the user hasn't pinned a specific
/// server — a native streaming engine beats one whose deltas are synthesized
/// by the proxy, which beats a server that only hands back whole utterances.
///
/// Absent or unrecognised reads as `.utterance`, the worst case: an older
/// backend, or one whose delta-synthesis work hasn't landed yet, simply looks
/// like it has no live words rather than being assumed to have the best kind.
/// See AUTOCHOOSE-RESULT.md.
enum StreamingGranularity: String, Sendable, Equatable {
	case nativeDelta = "native-delta"
	case synthesizedDelta = "synthesized-delta"
	case utterance

	static func from(_ raw: String?) -> StreamingGranularity {
		raw.flatMap(StreamingGranularity.init(rawValue:)) ?? .utterance
	}

	/// Lower sorts first: native beats synthesized beats utterance-only.
	var rank: Int {
		switch self {
		case .nativeDelta: return 0
		case .synthesizedDelta: return 1
		case .utterance: return 2
		}
	}
}

/// One server as `auto` needs to see it to rank and pick — a local mirror of
/// `WhisperaDictation.DictationServer` plus the one field that package does not
/// decode yet. See `ServerDiscoveryProbe` for why this exists instead of
/// reusing the package's type.
struct DiscoveredServer: Sendable, Equatable {
	let id: String
	let label: String
	/// What the server runs, for the Settings server list. The policy never
	/// ranks on it — granularity is the quality signal — but a user pinning a
	/// server picks by model name as much as by label.
	let model: String
	let isOnline: Bool
	let supportsRealtime: Bool
	let isDefault: Bool
	let granularity: StreamingGranularity
}

/// Talks to `GET /transcription/servers` directly rather than through
/// `WhisperaDictation.DictationServerDirectory`, because that package's
/// `DictationServer` does not decode `realtime.granularity` — the field this
/// whole feature ranks on — and this worktree does not touch the package (see
/// AUTOCHOOSE-RESULT.md for the one-struct change that would let this go away).
///
/// The request is built the same way `DictationServerDirectory.servers()`
/// builds its own — same path, same credential placement — so the two only
/// ever drift if the backend's contract changes, not because this drifted from
/// it by accident.
enum ServerDiscoveryProbe {
	private struct Response: Decodable {
		struct Server: Decodable {
			struct Realtime: Decodable { let granularity: String? }
			let id: String
			let label: String
			let model: String?
			let capabilities: [String]
			let status: String?
			let realtime: Realtime?
			let `default`: Bool?
		}
		let servers: [Server]
	}

	static func fetch(
		baseURL: URL,
		credentials: DictationCredentialProvider,
		session: URLSession,
		timeout: TimeInterval
	) async throws -> [DiscoveredServer] {
		let credential = try await credentials.credential()

		guard
			var components = URLComponents(
				url: baseURL.appendingPathComponent("transcription/servers"),
				resolvingAgainstBaseURL: false)
		else {
			throw StreamingTranscriberError.invalidServerURL
		}
		if !credential.queryItems.isEmpty {
			components.queryItems = (components.queryItems ?? []) + credential.queryItems
		}
		guard let url = components.url else {
			throw StreamingTranscriberError.invalidServerURL
		}

		var request = URLRequest(url: url, timeoutInterval: timeout)
		for (name, value) in credential.headers { request.setValue(value, forHTTPHeaderField: name) }

		let (data, response) = try await session.data(for: request)
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw StreamingTranscriberError.engineUnreachable(baseURL.host ?? baseURL.absoluteString)
		}

		let decoded = try JSONDecoder().decode(Response.self, from: data)
		return decoded.servers.map {
			DiscoveredServer(
				id: $0.id,
				label: $0.label,
				model: $0.model ?? "",
				isOnline: $0.status == nil || $0.status == "online",
				supportsRealtime: $0.capabilities.contains("realtime"),
				isDefault: $0.default ?? false,
				granularity: .from($0.realtime?.granularity))
		}
	}
}

/// What discovery produced, kept separate from *why* it produced nothing so the
/// policy below can say something more useful than "unavailable" when it logs.
enum AutoDiscoveryOutcome: Equatable {
	case unavailable(reason: String)
	case servers([DiscoveredServer])
}

/// What `auto` decided, and — for a remote pick — which server and how good its
/// deltas are, so the caller can both connect and explain the choice.
enum AutoEngineResolution: Equatable {
	case local(reason: String)
	case server(id: String, label: String, granularity: StreamingGranularity)

	/// One line naming the choice and why. Logged, and shown once as the
	/// streaming HUD's status text — see `AutoTranscriber.apply(_:)`.
	var summary: String {
		switch self {
		case .local(let reason):
			return "auto: local WhisperKit (\(reason))"
		case .server(_, let label, let granularity):
			return "auto: server \(label) (\(granularity.rawValue))"
		}
	}
}

/// The resolution policy itself, pure and synchronous: given what discovery
/// found (or why it didn't), decide local vs. a specific server. Kept apart
/// from the network and the caching around it so the whole decision table is
/// exercisable without a backend — see `AutoEnginePolicyTests`.
enum AutoEnginePolicy {
	static func resolve(
		serverURLConfigured: Bool,
		pinnedServerId: String,
		discovery: AutoDiscoveryOutcome
	) -> AutoEngineResolution {
		guard serverURLConfigured else {
			return .local(reason: "no transcription server configured")
		}
		guard case .servers(let servers) = discovery else {
			if case .unavailable(let reason) = discovery {
				return .local(reason: reason)
			}
			return .local(reason: "backend unreachable")
		}

		let usable = servers.filter { $0.isOnline && $0.supportsRealtime }
		guard !usable.isEmpty else {
			return .local(reason: "no realtime server available")
		}

		if !pinnedServerId.isEmpty, let pinned = usable.first(where: { $0.id == pinnedServerId }) {
			return .server(id: pinned.id, label: pinned.label, granularity: pinned.granularity)
		}

		// No pin — or a pin that isn't currently usable — falls through to
		// picking the best granularity among what is usable, tie-broken by the
		// backend's own default flag and then id, so the choice is deterministic.
		let best = usable.sorted { lhs, rhs in
			if lhs.granularity.rank != rhs.granularity.rank {
				return lhs.granularity.rank < rhs.granularity.rank
			}
			if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
			return lhs.id < rhs.id
		}.first!
		return .server(id: best.id, label: best.label, granularity: best.granularity)
	}
}

/// The `auto` conformer: decides between `WhisperKitTranscriber` and the
/// streaming conformer at the top of every call, then delegates to whichever
/// it picked. Its own `engine` reads `.auto` — it is not "the streaming
/// conformer" the way `StreamingTranscriber` is, even on a call it delegates
/// to a socket — which is what keeps `TranscriptionRouter.transcriber(for:)`
/// exhaustive without reopening a switch anywhere else. See WHI-58.
///
/// Resolution is cached for a short window rather than re-run on every call:
/// "at dictation start, not per frame" from the brief means a rapid
/// stop/start shouldn't double the network round trip a user is already
/// waiting on, but a session that runs for a while should eventually notice a
/// server that came back up.
@MainActor
final class AutoTranscriber: SpeechTranscribing {
	static let shared = AutoTranscriber()

	nonisolated var engine: TranscriptionEngine { .auto }

	/// The union of what either candidate can do. Honest per-call capability
	/// reporting would mean this changes after every resolution, but nothing
	/// reads `capabilities` mid-dictation to react to a change — the router and
	/// the settings UI both read it once, up front.
	nonisolated var capabilities: TranscriptionCapabilities {
		[.fileTranscription, .bufferTranscription, .timestamps, .streaming, .managedModels, .translation]
	}

	var onLiveAudioSamples: (@MainActor ([Float]) -> Void)? {
		didSet { delegate.onLiveAudioSamples = onLiveAudioSamples }
	}

	/// A reference box rather than a stored property read by `remote`'s
	/// `serverIdProvider`, because that closure is built during `init`, before
	/// `self` exists to capture.
	private final class ServerIdBox: @unchecked Sendable {
		var value = ""
	}

	private let local: SpeechTranscribing
	private let remote: StreamingTranscriber
	private let serverIdBox: ServerIdBox
	private let baseURLProvider: () -> URL?
	private let pinnedServerIdProvider: () -> String
	private let credentials: DictationCredentialProvider
	private let urlSession: URLSession

	/// Which conformer calls land on right now. Starts pointed at on-device
	/// WhisperKit — the safe assumption before the first resolution ever runs,
	/// and exactly the fallback `auto` would pick anyway with no server
	/// configured, which is the common fresh-install case.
	private var delegate: SpeechTranscribing
	private var lastResolution: (at: Date, resolution: AutoEngineResolution)?

	private static let discoveryTimeout: TimeInterval = 3
	private static let cacheTTL: TimeInterval = 20

	init(
		local: SpeechTranscribing = WhisperKitTranscriber.shared,
		baseURLProvider: @escaping () -> URL? = { WhisperaSettings.transcriptionServerURL },
		pinnedServerIdProvider: @escaping () -> String = { WhisperaSettings.transcriptionServerId },
		tokenStore: AuthTokenStore = .shared,
		urlSession: URLSession = .shared
	) {
		self.local = local
		self.baseURLProvider = baseURLProvider
		self.pinnedServerIdProvider = pinnedServerIdProvider
		self.urlSession = urlSession
		self.credentials = .refreshingBearer {
			(try? tokenStore.load()).flatMap { $0.isEmpty ? nil : $0 } ?? ""
		}
		let serverIdBox = ServerIdBox()
		self.serverIdBox = serverIdBox
		self.remote = StreamingTranscriber(
			baseURLProvider: baseURLProvider,
			serverIdProvider: { serverIdBox.value })
		self.delegate = local
	}

	// MARK: - Lifecycle

	func prepare() async throws {
		_ = await resolve()
		try await delegate.prepare()
	}

	func shutdown() { delegate.shutdown() }

	var state: TranscriptionEngineState { delegate.state }

	// MARK: - Models
	// Model management always addresses the on-device bank Whispera already
	// manages regardless of engine, the same way the Settings "Whisper Model"
	// section is unconditional on the engine picker — there is no server
	// pinned by `auto` for a user to manage models against even when a
	// dictation happens to run remote.

	var activeModel: String? { local.activeModel }
	func models() async throws -> [TranscriptionModelInfo] { try await local.models() }
	func selectModel(_ id: String) async throws { try await local.selectModel(id) }
	func downloadModel(_ id: String) async throws { try await local.downloadModel(id) }
	func cancelModelDownload() { local.cancelModelDownload() }

	// MARK: - One-shot

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String {
		_ = await resolve()
		return try await delegate.transcribe(fileAt: url, options: options)
	}

	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
		_ = await resolve()
		return try await delegate.transcribe(samples: samples, options: options)
	}

	func transcribeWithTimestamps(fileAt url: URL, options: TranscriptionOptions) async throws
		-> [TranscriptionSegment]
	{
		_ = await resolve()
		return try await delegate.transcribeWithTimestamps(fileAt: url, options: options)
	}

	// MARK: - Streaming

	func resetStreamingSession() { delegate.resetStreamingSession() }

	func startStreaming(options: TranscriptionOptions) async throws {
		_ = await resolve()
		try await delegate.startStreaming(options: options)
	}

	func switchStreamingDevice() async { await delegate.switchStreamingDevice() }

	@discardableResult
	func stopStreaming() async -> String { await delegate.stopStreaming() }

	/// Forwarded, not re-resolved: the pass belongs to the session the current
	/// delegate just stopped, and resolution only ever moves at dictation start.
	func finalizeDictation(draft: String) async -> String? {
		await delegate.finalizeDictation(draft: draft)
	}

	// MARK: - Resolution

	/// A one-line caption for Settings: what `auto` currently resolves to,
	/// using the same cache a dictation would. Reading it does not skip the
	/// cache — opening Settings should not itself trigger a discovery round
	/// trip more often than starting a dictation would.
	func resolutionCaption() async -> String {
		switch await resolve() {
		case .local(let reason):
			return "Currently on-device (WhisperKit) — \(reason)."
		case .server(_, let label, let granularity):
			return "Currently streaming through \(label) (\(granularity.rawValue))."
		}
	}

	private func resolve() async -> AutoEngineResolution {
		if let lastResolution, Date().timeIntervalSince(lastResolution.at) < Self.cacheTTL {
			return lastResolution.resolution
		}

		let resolution = await Self.computeResolution(
			baseURL: baseURLProvider(),
			pinnedServerId: pinnedServerIdProvider(),
			credentials: credentials,
			session: urlSession,
			timeout: Self.discoveryTimeout)

		apply(resolution)
		lastResolution = (Date(), resolution)
		return resolution
	}

	private static func computeResolution(
		baseURL: URL?,
		pinnedServerId: String,
		credentials: DictationCredentialProvider,
		session: URLSession,
		timeout: TimeInterval
	) async -> AutoEngineResolution {
		guard let baseURL else {
			return AutoEnginePolicy.resolve(
				serverURLConfigured: false,
				pinnedServerId: pinnedServerId,
				discovery: .unavailable(reason: "no transcription server configured"))
		}
		do {
			let servers = try await ServerDiscoveryProbe.fetch(
				baseURL: baseURL, credentials: credentials, session: session, timeout: timeout)
			return AutoEnginePolicy.resolve(
				serverURLConfigured: true, pinnedServerId: pinnedServerId, discovery: .servers(servers))
		} catch {
			AppLogger.shared.transcriber.debug(
				"auto: discovery failed, falling back to local: \(error)")
			return AutoEnginePolicy.resolve(
				serverURLConfigured: true,
				pinnedServerId: pinnedServerId,
				discovery: .unavailable(reason: "backend unreachable"))
		}
	}

	private func apply(_ resolution: AutoEngineResolution) {
		switch resolution {
		case .local:
			delegate = local
		case .server(let id, _, _):
			serverIdBox.value = id
			delegate = remote
		}
		delegate.onLiveAudioSamples = onLiveAudioSamples
		// Set once, here, at the top of resolution — not on every event. The
		// delegate's own startStreaming immediately refines this with its own
		// connecting/loading text, which is expected: this is only the first
		// word on which engine `auto` picked and why.
		LiveTranscriptionState.shared.waitingForModelStatusText = resolution.summary
		AppLogger.shared.transcriber.info(resolution.summary)
	}
}
