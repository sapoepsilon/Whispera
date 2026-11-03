import Foundation

/// Where to connect and what to ask for.
public struct DictationConfiguration: Sendable {
	/// The WebSocket endpoint. `ws://` or `wss://`.
	public var endpoint: URL
	/// The transcription model. Sent in `session.update`, which is mandatory —
	/// see `RealtimeProtocol.sessionUpdate`.
	public var model: String
	/// BCP-47-ish language hint, or nil to let the engine detect.
	public var language: String?
	/// How much audio to put in one frame. 50 ms of 24 kHz PCM16 is 2400 bytes,
	/// which is a comfortable frame size and well under the proxy's 1 MiB cap.
	public var chunkDuration: Double
	/// Silence appended when the audio ends.
	///
	/// Load-bearing, not politeness. The engine's turn detection is server-side VAD
	/// and it commits an utterance when it hears the speech stop. End the stream on
	/// the final syllable and the VAD never fires, so the last utterance — often the
	/// only one — is never transcribed.
	public var trailingSilence: Double
	/// How long to wait after flushing before giving up on a final transcript.
	public var finalTranscriptTimeout: Double
	/// Overrides the engine's own VAD silence threshold, in milliseconds. `nil`
	/// leaves the engine's advertised default alone.
	///
	/// This is the knob for the latency between a speaker stopping and a
	/// transcript appearing: the engine will not close an utterance until it has
	/// seen this much trailing silence, and every millisecond of it is dead time
	/// the speaker spent waiting. Measured against speaches with a 5.16 s fixture
	/// paced at 24 kHz: the engine's own default (550 ms) cost ~0.96 s from the
	/// last spoken sample to a completed transcript; 300 ms cost ~0.66 s, three
	/// runs each, consistent to within 60 ms. That is most of the latency this
	/// package has any control over — the transcription pass itself, not this
	/// package's business, accounted for the rest.
	///
	/// Re-measured 2026-08-10 against speaches 0.9.0-rc.3 in `intent=transcription`
	/// mode (see `LATENCY-RESULT.md`): the same override still applies the same
	/// way — 550 ms cost ~0.85 s, 300 ms cost ~0.59 s, three runs each — a modest
	/// improvement over the numbers above from a faster engine build, not a
	/// change in how the knob behaves. A distil-large-v3-turbo checkpoint was
	/// also measured on the same fixture and was not faster once warm (~0.87 s at
	/// 550 ms, ~0.64 s at 300 ms) — the ASR pass on a 5 s clip is not where this
	/// model's speed advantage shows up — so it is not the default.
	///
	/// 300 is the default rather than something lower because it was the only
	/// value actually measured here — not because it is known to be a floor.
	/// Pushing it lower trades the same latency against a real cost this fixture
	/// cannot expose: a speaker's natural mid-sentence breath is itself a few
	/// hundred milliseconds of silence, and a threshold below that starts reading
	/// pauses as sentence ends, splitting one utterance into several. A host
	/// dictating short, clipped commands can likely go lower than one dictating
	/// long sentences; override per use case rather than trusting this default
	/// for both.
	public var vadSilenceDurationMs: Int?
	/// Whether to send `input_audio_buffer.commit` when the audio ends.
	///
	/// Off, and that is not an oversight. Against an engine with server-side VAD —
	/// which speaches always has, and cannot disable — the VAD has already committed
	/// the utterance and created the conversation item by the time the audio stops.
	/// The explicit commit then races the VAD's own commit for the same item.
	/// Measured against speaches, not assumed, and the exact wording has moved
	/// between builds: the pre-upgrade engine answered
	/// `Error adding item: the item with id '…' already exists`; 0.9.0-rc.3
	/// instead answers `Error committing input audio buffer: buffer too small`,
	/// because by the time the explicit commit arrives the VAD has already
	/// drained the buffer it would have committed. Both arrive as an error frame
	/// that `RealtimeProtocol.decode` now recognises and treats as informational
	/// — see its handling of `"already exists"` and `"buffer too small"` — so
	/// turning this on no longer tears the session down before the transcript is
	/// delivered. It remains off by default because the race has nothing to gain
	/// against a server-VAD engine: the VAD is what actually closes the turn.
	///
	/// Turn it on for an engine whose VAD is off, where nothing else would ever
	/// close the utterance.
	public var sendsExplicitCommit: Bool
	/// How long to wait for the engine's `session.created` before giving up.
	///
	/// The socket opening is not the same as the session existing: a refused
	/// upgrade, a proxy that accepted the connection but cannot reach its engine,
	/// and a healthy-but-slow engine all look identical until the first frame
	/// arrives. The proxy's own upstream handshake budget is 10 seconds, so this
	/// sits just past it.
	public var handshakeTimeout: Double
	/// How many times to reopen the socket after a recoverable failure.
	///
	/// Bounded, and small. One attempt covers the two failures actually measured
	/// here — an engine that drops the session after an utterance, and a first
	/// connect that fails instantly and works on the retry — without turning a
	/// server that is simply down into an indefinite spinner. See
	/// `DictationError.isRecoverable` for what counts.
	public var reconnectLimit: Int
	/// Delay before the first reconnect, doubled for each attempt after it.
	public var reconnectBackoff: Double
	/// Whether the session keeps a copy of the audio it sends, for a second pass.
	///
	/// Off by default because it costs memory — up to ten minutes of engine-format
	/// PCM16, about 28.8 MB. Turn it on and `DictationSession.capturedAudio()`
	/// returns exactly the bytes the streaming engine heard: the normalized
	/// engine-format frames, after resampling and downmixing, without the synthetic
	/// trailing silence the flush appends. That is what a host wants for
	/// re-transcribing the whole utterance with a slower, more accurate model once
	/// the live pass is over.
	///
	/// When the retained audio outgrows the ten-minute cap, the oldest audio is
	/// dropped and the tail kept — the end of a dictation is worth more than its
	/// beginning to a second pass the user is waiting on — and
	/// `capturedAudioWasTruncated` reports that it happened.
	public var retainAudio: Bool
	/// The PCM this server wants.
	///
	/// Per-configuration rather than a global constant because the format is a
	/// property of the engine on the other end, not of this package: one backend
	/// fronts several engines and `GET /transcription/servers` advertises a
	/// `realtime.audio` block per server. Build it with
	/// `DictationServer.audioFormat` and the client honours whatever the server
	/// it is pointed at asked for. Defaulted to `.engine` (24 kHz mono PCM16), so
	/// a server that advertises nothing behaves exactly as before. See WHI-71.
	public var audioFormat: DictationAudioFormat
	/// How many seconds of audio the sender may run ahead of the wall clock
	/// before it waits, or `nil` to send as fast as the socket accepts.
	///
	/// Only consulted for a live source (`DictationAudioSource.isLive`) — a file
	/// being uploaded is *meant* to go as fast as it can, and pacing that would
	/// turn a five-second fixture into a five-second wait. For a microphone the
	/// audio is produced in real time anyway, so this costs nothing until
	/// something stalls: a wedged main thread or a network hiccup leaves a
	/// backlog, and draining it unpaced is what puts speaches' always-on VAD into
	/// its failure regime — one reproduction gave 18 duplicate `speech_stopped`
	/// frames, 17 `already exists` errors and a fatal Internal Server Error with
	/// an empty transcript. See WHI-70.
	public var maxAudioAheadOfRealtime: Double?

	public init(
		endpoint: URL,
		model: String,
		language: String? = "en",
		chunkDuration: Double = 0.05,
		trailingSilence: Double = 2.0,
		sendsExplicitCommit: Bool = false,
		finalTranscriptTimeout: Double = 15,
		vadSilenceDurationMs: Int? = 300,
		handshakeTimeout: Double = 12,
		reconnectLimit: Int = 1,
		reconnectBackoff: Double = 0.4,
		retainAudio: Bool = false,
		audioFormat: DictationAudioFormat = .engine,
		maxAudioAheadOfRealtime: Double? = 1.0
	) {
		self.endpoint = endpoint
		self.model = model
		self.language = language
		self.chunkDuration = chunkDuration
		self.trailingSilence = trailingSilence
		self.sendsExplicitCommit = sendsExplicitCommit
		self.finalTranscriptTimeout = finalTranscriptTimeout
		self.vadSilenceDurationMs = vadSilenceDurationMs
		self.handshakeTimeout = handshakeTimeout
		self.reconnectLimit = reconnectLimit
		self.reconnectBackoff = reconnectBackoff
		self.retainAudio = retainAudio
		self.audioFormat = audioFormat
		self.maxAudioAheadOfRealtime = maxAudioAheadOfRealtime
	}

	/// Through the Whispera backend, which is the shipping path: it holds the
	/// engine's address and key, so a client never learns either.
	///
	/// - Parameters:
	///   - baseURL: the backend origin, e.g. `http://localhost:3000`.
	///   - server: the `id` of a server from `GET /transcription/servers`. Omit to
	///     take the backend's default.
	///   - audio: the PCM that server wants, from its `realtime.audio` block —
	///     `DictationServer.audioFormat` hands it over directly. Defaulted so a
	///     caller that has not discovered a server yet still gets the engine
	///     default rather than nothing.
	public static func backend(
		_ baseURL: URL,
		server: String? = nil,
		model: String,
		language: String? = "en",
		audio: DictationAudioFormat = .engine
	) -> Self {
		var components = URLComponents(
			url: baseURL.appendingPathComponent("transcription/stream"),
			resolvingAgainstBaseURL: false)!
		// http → ws, because a host naturally has the origin it uses for REST.
		components.scheme = (components.scheme == "https") ? "wss" : "ws"
		var queryItems: [URLQueryItem] = []
		if let server {
			queryItems.append(URLQueryItem(name: "server", value: server))
		}
		// See `directEngine` for why this is always sent.
		queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
		components.queryItems = queryItems
		return Self(
			endpoint: components.url!, model: model, language: language, audioFormat: audio)
	}

	/// Straight at an OpenAI-Realtime-compatible engine, with no backend in front.
	///
	/// For development on a trusted network. The trailing-slash detail is real: the
	/// speaches build this was tested against answers `101` on `/v1/realtime` and
	/// `500` on `/v1/realtime/`.
	///
	/// `intent=transcription` is not decoration. Against speaches 0.9.0-rc.3 it is
	/// what makes `session.created.input_audio_transcription.model` come back as
	/// the model actually requested — without it the pre-upgrade engine silently
	/// substituted `small.en`, which `RealtimeProtocol.sessionUpdate` already
	/// works around, but transcription intent is also what puts the session into
	/// a mode with nothing to generate a reply for: `session.created`'s
	/// `turn_detection.create_response` reads `false` by default in this mode,
	/// where the conversational default is `true`. `sessionUpdate` still sends
	/// `create_response: false` explicitly rather than relying on that default —
	/// cheap belt-and-braces against an engine build that reverts the default, and
	/// it was measured to draw no complaint of its own in transcription mode.
	public static func directEngine(
		_ baseURL: URL, model: String, language: String? = "en",
		audio: DictationAudioFormat = .engine
	) -> Self {
		var components = URLComponents(
			url: baseURL.appendingPathComponent("realtime"), resolvingAgainstBaseURL: false)!
		components.scheme = (components.scheme == "https") ? "wss" : "ws"
		components.queryItems = [
			URLQueryItem(name: "model", value: model),
			URLQueryItem(name: "intent", value: "transcription"),
		]
		return Self(
			endpoint: components.url!, model: model, language: language, audioFormat: audio)
	}

	/// Applies a credential's query items to the endpoint.
	func requestURL(with credential: DictationCredential) throws -> URL {
		guard credential.queryItems.isEmpty else {
			guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
				throw DictationError.connectionFailed("the endpoint is not a valid URL")
			}
			components.queryItems = (components.queryItems ?? []) + credential.queryItems
			guard let url = components.url else {
				throw DictationError.connectionFailed("the credential's query items produced an invalid URL")
			}
			return url
		}
		return endpoint
	}

	func request(with credential: DictationCredential) throws -> URLRequest {
		var request = URLRequest(url: try requestURL(with: credential))
		for (name, value) in credential.headers {
			request.setValue(value, forHTTPHeaderField: name)
		}
		return request
	}
}
