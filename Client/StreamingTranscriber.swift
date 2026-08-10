// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaDictation

/// The streaming conformer: a WebSocket to the Whispera transcription proxy,
/// behind the same interface as the on-device model.
///
/// The socket, the resampling to the engine's format and the credential
/// handling all live in the `WhisperaDictation` package — this type only
/// resolves which server to talk to, turns that package's events into the
/// shared `LiveTranscriptionState`, and hands the same lifecycle back to
/// `AudioManager` that WhisperKit hands it. See WHI-58.
///
/// Server capabilities, the realtime path and the audio format are read from
/// `GET /transcription/servers` rather than hardcoded, so a new engine on the
/// backend needs no client change.
@MainActor
final class StreamingTranscriber: SpeechTranscribing {
	static let shared = StreamingTranscriber()
	/// Same conformer, addressed straight at an engine. Separate instance because
	/// each holds its own socket and resolved server.
	static let direct = StreamingTranscriber(
		baseURLProvider: { WhisperaSettings.transcriptionServerURL },
		directProvider: { true })

	private let engineCase: TranscriptionEngine
	nonisolated var engine: TranscriptionEngine { engineCase }

	/// One-shot transcription runs the same socket with a file or buffer source
	/// instead of the microphone, so text mode works on this engine too.
	nonisolated var capabilities: TranscriptionCapabilities {
		[.streaming, .fileTranscription, .bufferTranscription]
	}

	var onLiveAudioSamples: (@MainActor ([Float]) -> Void)?

	private let live = LiveTranscriptionState.shared
	private let baseURLProvider: () -> URL?
	private let serverIdProvider: () -> String
	private let credentials: DictationCredentialProvider
	private let isDirect: () -> Bool
	private let directModel: () -> String

	private var session: DictationSession?
	private var eventTask: Task<Void, Never>?
	private var wordTracker: DictationWordTracker?
	private var cachedServer: DictationServer?
	private var startContinuation: CheckedContinuation<Void, Error>?
	/// The session can reach `.listening` — or fail outright — before the
	/// continuation below is installed. Recording the outcome means that start
	/// resolves immediately instead of waiting on a resume that already happened.
	private var startOutcome: Result<Void, Error>?
	/// The newest committed utterance, so the HUD can show the words that just
	/// landed. The package emits it just before the whole-transcript event.
	private var lastUtterance = ""
	private var didTranscribeAnything = false

	private(set) var state: TranscriptionEngineState = .unavailable(
		"Not connected to a transcription server yet.")

	init(
		baseURLProvider: @escaping () -> URL? = { WhisperaSettings.transcriptionServerURL },
		serverIdProvider: @escaping () -> String = { WhisperaSettings.transcriptionServerId },
		// Direct mode addresses an OpenAI-Realtime engine itself, with no Whispera
		// backend in the path: no discovery to ask for a model, and no proxy to
		// hold the engine's credentials. Useful on a trusted network, and the only
		// shape available to a host that has no backend at all.
		directProvider: @escaping () -> Bool = { false },
		modelProvider: @escaping () -> String = { WhisperaSettings.transcriptionDirectModel },
		tokenStore: AuthTokenStore = .shared
	) {
		self.baseURLProvider = baseURLProvider
		self.serverIdProvider = serverIdProvider
		self.isDirect = directProvider
		self.directModel = modelProvider
		self.engineCase = directProvider() ? .realtimeDirect : .whisperaStreaming
		// Read at connect time and dropped afterwards, and re-read on the one
		// unauthorized retry, so a short-lived session token survives it.
		// A missing token is not fatal: a self-hosted proxy on a trusted network
		// may not require one, and refusing to connect would make the app harder
		// to bring up than the server it talks to. If the server does want a
		// credential it answers 4401, which surfaces as a real error.
		self.credentials = .refreshingBearer {
			(try? tokenStore.load()).flatMap { $0.isEmpty ? nil : $0 } ?? ""
		}
	}

	// MARK: - Lifecycle

	func prepare() async throws {
		// Direct mode has no registry to consult; the endpoint and model are the
		// host's to state, and the first connect is what proves them.
		guard !isDirect() else { return }
		_ = try await resolveServer()
	}

	func shutdown() {
		teardown()
		cachedServer = nil
		state = .unavailable("Not connected to a transcription server yet.")
	}

	// MARK: - Models

	var activeModel: String? { isDirect() ? directModel() : cachedServer?.model }

	/// The backend lists one model per server, so the model list is the server
	/// list. Selecting one records which server to stream through.
	func models() async throws -> [TranscriptionModelInfo] {
		if isDirect() {
			let model = directModel()
			return [TranscriptionModelInfo(id: model, displayName: model)]
		}
		return try await directory().servers()
			.filter { $0.supportsRealtime && $0.isOnline }
			.map { TranscriptionModelInfo(id: $0.id, displayName: "\($0.label) — \($0.model)") }
	}

	func selectModel(_ id: String) async throws {
		if isDirect() {
			WhisperaSettings.transcriptionDirectModel = id
			return
		}
		WhisperaSettings.transcriptionServerId = id
		cachedServer = nil
		_ = try await resolveServer()
	}

	// MARK: - One-shot

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String {
		let source = try AudioFileSource(url: url)
		return try await runOneShot(audio: source, options: options)
	}

	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
		guard !samples.isEmpty else { return "No audio data provided" }

		// Declare the capture format and let the package resample; it owns the
		// conversion to whatever the engine wants.
		let source = PushAudioSource(
			format: DictationAudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
		samples.withUnsafeBufferPointer { buffer in
			source.push(Data(buffer: buffer))
		}
		source.finish()

		return try await runOneShot(audio: source, options: options)
	}

	private func runOneShot(audio: DictationAudioSource, options: TranscriptionOptions) async throws
		-> String
	{
		let configuration = try await configuration(for: options)
		let text = try await DictationSession.transcribe(
			configuration: configuration, credentials: credentials, audio: audio)
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? "No speech detected" : trimmed
	}

	// MARK: - Streaming

	func resetStreamingSession() {
		teardown()
		live.reset()
	}

	func startStreaming(options: TranscriptionOptions) async throws {
		live.beginWaiting()
		live.waitingForModelStatusText = "Connecting to \(serverIdProvider().isEmpty ? "transcription server" : serverIdProvider())..."
		lastUtterance = ""
		didTranscribeAnything = false
		startOutcome = nil

		do {
			let configuration = try await configuration(for: options)

			// The input device the user picked has to be the system default before
			// the package opens its own capture, which follows the default.
			await AudioDeviceManager.shared.activateSelectedDevice()

			wordTracker = DictationWordTracker()
			wordTracker?.startNewSession()

			let session = DictationSession(
				configuration: configuration, credentials: credentials, audio: MicrophoneSource())
			self.session = session

			eventTask = Task { @MainActor [weak self] in
				for await event in session.events {
					self?.handle(event)
				}
				self?.finishStartIfPending(throwing: nil)
			}

			await session.start()
			try await awaitCaptureEstablished()
		} catch {
			live.isWaitingForModel = false
			live.isTranscribing = false
			if live.waitingForModelStatusText.isEmpty {
				live.waitingForModelStatusText = "Unable to start dictation."
			}
			live.shouldShowLiveTranscriptionWindow = true
			teardown()
			AppLogger.shared.transcriber.error("Failed to start remote live stream: \(error)")
			throw error
		}
	}

	/// AVAudioEngine pins its input at start, so an established remote stream
	/// keeps the device it opened on. The selection is activated here and takes
	/// effect on the next dictation.
	func switchStreamingDevice() async {
		await AudioDeviceManager.shared.activateSelectedDevice()
		AppLogger.shared.transcriber.info(
			"Input device selection applied; the running remote stream keeps its original input until it is restarted")
	}

	func stopStreaming() {
		live.isWaitingForModel = false
		live.waitingForModelStatusText = ""
		live.isTranscribing = false
		live.shouldShowLiveTranscriptionWindow = false
		AudioDeviceManager.shared.restoreSystemDefault()

		guard let session else {
			teardown()
			return
		}
		self.session = nil

		Task { @MainActor [weak self] in
			let transcript = await session.finish()
			guard let self else { return }
			let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				self.live.ingest(committed: trimmed, draft: "")
			}
			self.live.setPending("")
			self.wordTracker?.endSession()
			self.wordTracker = nil
			self.eventTask?.cancel()
			self.eventTask = nil
			AppLogger.shared.transcriber.info("Remote live streaming stopped")
		}
	}

	// MARK: - Events

	private func handle(_ event: DictationEvent) {
		// Every event, at debug level. A remote session that stalls used to leave
		// no trace at all between "connecting" and silence, which made a stuck
		// socket and a silent microphone look identical from the log.
		AppLogger.shared.transcriber.debug("Remote dictation event: \(String(describing: event))")
		switch event {
		case .connectionState(let connectionState):
			handle(connectionState)

		case .partialTranscript(let draft):
			live.ingest(committed: live.confirmedText, draft: draft)

		case .finalTranscript(let utterance):
			// Remembered only so the HUD can show the words that just landed.
			// `.transcript` immediately after carries the whole transcript, and
			// consuming both would double-count.
			lastUtterance = utterance
			didTranscribeAnything = true

		case .transcript(let whole):
			live.ingest(committed: whole, draft: lastUtterance)

		case .audioLevel(let level):
			// The level meter wants samples, not an RMS. Spreading the reported
			// level across a short window is what the file-recorder path already
			// does with AVAudioRecorder's average power.
			onLiveAudioSamples?((0..<700).map { _ in level + Float.random(in: -0.02...0.02) })

		case .failed(let error):
			AppLogger.shared.transcriber.error("Remote dictation failed: \(error.localizedDescription)")
			state = .unavailable(error.localizedDescription)
			live.isWaitingForModel = true
			live.waitingForModelStatusText = error.localizedDescription
			live.shouldShowLiveTranscriptionWindow = true
			finishStartIfPending(throwing: error)
		}
	}

	private func handle(_ connectionState: DictationConnectionState) {
		switch connectionState {
		case .idle, .connecting, .finishing:
			break

		case .listening:
			state = .ready
			live.isWaitingForModel = false
			live.waitingForModelStatusText = ""
			live.isTranscribing = true
			live.shouldShowLiveTranscriptionWindow = true
			finishStartIfPending(throwing: nil)

		case .closed(let reason):
			live.isTranscribing = false
			switch reason {
			case .finished, .cancelled:
				break
			case .failed(let error):
				// The engine tears the socket down right after it commits an
				// utterance, so a failure that arrives with words already in hand
				// is the end of a good dictation, not a lost one.
				if didTranscribeAnything {
					AppLogger.shared.transcriber.info(
						"Remote session closed after transcribing: \(error.localizedDescription)")
				} else {
					AppLogger.shared.transcriber.error(
						"Remote session closed without a transcript: \(error.localizedDescription)")
					finishStartIfPending(throwing: error)
				}
			}
		}
	}

	private func finishStartIfPending(throwing error: Error?) {
		let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
		guard let continuation = startContinuation else {
			// Nobody is waiting yet. Keep the first outcome so the waiter that
			// arrives next resolves on it rather than hanging.
			if startOutcome == nil { startOutcome = outcome }
			return
		}
		startContinuation = nil
		startOutcome = nil
		continuation.resume(with: outcome)
	}

	/// Waits for the session to reach `.listening`, or for the first failure.
	/// Capture is established when the engine says it is listening. Without a
	/// deadline a session that never reaches that state hangs this call forever:
	/// the continuation is only resumed by an event, so a socket that stalls or a
	/// microphone that never yields frames leaves dictation silently wedged with
	/// nothing logged. Fail loudly instead.
	private func awaitCaptureEstablished() async throws {
		if let outcome = startOutcome {
			startOutcome = nil
			return try outcome.get()
		}
		let deadline = Task { @MainActor [weak self] in
			try await Task.sleep(nanoseconds: UInt64(Self.captureTimeout * 1_000_000_000))
			guard !Task.isCancelled else { return }
			AppLogger.shared.transcriber.error(
				"Remote capture did not start within \(Self.captureTimeout)s; giving up")
			self?.finishStartIfPending(throwing: StreamingTranscriberError.captureTimedOut)
		}
		defer { deadline.cancel() }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			startContinuation = continuation
		}
	}

	private static let captureTimeout: Double = 15

	private func teardown() {
		eventTask?.cancel()
		eventTask = nil
		let closing = session
		session = nil
		wordTracker?.endSession()
		wordTracker = nil
		finishStartIfPending(throwing: CancellationError())
		if let closing {
			Task { await closing.cancel() }
		}
	}

	// MARK: - Server resolution

	private func directory() throws -> DictationServerDirectory {
		guard let baseURL = baseURLProvider() else {
			throw StreamingTranscriberError.invalidServerURL
		}
		return DictationServerDirectory(baseURL: baseURL, credentials: credentials)
	}

	/// Picks the server to stream through: the one the user named, otherwise the
	/// backend's own default among those that report realtime support and are
	/// online.
	private func resolveServer() async throws -> DictationServer {
		if let cachedServer { return cachedServer }

		let directory = try directory()
		let wanted = serverIdProvider()
		let server: DictationServer?
		if wanted.isEmpty {
			server = try await directory.preferredRealtimeServer()
		} else {
			server = try await directory.servers().first { $0.id == wanted }
		}

		guard let server else {
			throw StreamingTranscriberError.noRealtimeServer(requested: wanted)
		}
		guard server.supportsRealtime else {
			throw StreamingTranscriberError.serverCannotStream(server.label)
		}

		cachedServer = server
		state = .ready
		AppLogger.shared.transcriber.info(
			"Streaming through \(server.id) (\(server.model)); audio \(server.realtime?.audio?.encoding ?? "unknown") at \(server.realtime?.audio?.sampleRate ?? 0) Hz")
		return server
	}

	private func configuration(for options: TranscriptionOptions) async throws
		-> DictationConfiguration
	{
		guard let baseURL = baseURLProvider() else {
			throw StreamingTranscriberError.invalidServerURL
		}
		if isDirect() {
			let model = directModel()
			AppLogger.shared.transcriber.info(
				"Streaming direct to \(baseURL.absoluteString) (\(model)); no backend in the path")
			return .directEngine(baseURL, model: model, language: options.language)
		}
		let server = try await resolveServer()
		return .backend(
			baseURL, server: server.id, model: server.model, language: options.language)
	}
}

enum StreamingTranscriberError: LocalizedError, Equatable {
	case notSignedIn
	case invalidServerURL
	case noRealtimeServer(requested: String)
	case serverCannotStream(String)
	case captureTimedOut

	var errorDescription: String? {
		switch self {
		case .captureTimedOut:
			return "The transcription server did not start listening. Check that it is reachable."
		case .notSignedIn:
			return "Streaming transcription needs an auth token (Account settings)."
		case .invalidServerURL:
			return "Invalid transcription server URL"
		case .noRealtimeServer(let requested):
			return requested.isEmpty
				? "No transcription server on the backend supports streaming."
				: "Transcription server '\(requested)' was not found on the backend."
		case .serverCannotStream(let label):
			return "\(label) does not support streaming transcription."
		}
	}
}
