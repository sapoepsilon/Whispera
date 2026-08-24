// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaBackend
import WhisperaDictation
import WhisperaOpenAI

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
	///
	/// Addressed at the direct engine's own URL rather than at
	/// `transcriptionServerURL`: this conformer is direct by construction, so it
	/// must not resolve its base through whichever engine happens to be selected
	/// right now. `transcriptionDirectURL` is the normalised one — a base typed
	/// as `192.168.50.140:8000` reaches the socket as
	/// `http://192.168.50.140:8000/v1`, which is what makes the realtime path
	/// `/v1/realtime` instead of the `/realtime` speaches refuses with 403.
	static let direct = StreamingTranscriber(
		baseURLProvider: { WhisperaSettings.transcriptionDirectURL },
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
	/// Injectable so `models()`'s direct-mode fetch can be exercised against a
	/// mock in tests without a real engine on the network. Named apart from
	/// `session` below, which is the dictation socket, not an HTTP session.
	private let urlSession: URLSession

	private var session: DictationSession?
	private var eventTask: Task<Void, Never>?
	/// The previous session's close, still running behind the stop that returned
	/// immediately. The next start awaits it (bounded) before opening capture:
	/// in QA, back-to-back dictations opened the new AVAudioEngine while the old
	/// one still held the input device, and the new session heard only silence —
	/// or failed with -10868 once the engine gave up.
	private var closingTask: Task<Void, Never>?
	private var wordTracker: DictationWordTracker?
	/// Builds the in-flight utterance out of `.partialTranscript` deltas before
	/// they reach the live state; see the accumulator's own comment for why a
	/// partial cannot be displayed on its own.
	private var utteranceDraft = UtteranceDraftAccumulator()
	private var cachedServer: DictationServer?
	private var startContinuation: CheckedContinuation<Void, Error>?
	/// The session can reach `.listening` — or fail outright — before the
	/// continuation below is installed. Recording the outcome means that start
	/// resolves immediately instead of waiting on a resume that already happened.
	private var startOutcome: Result<Void, Error>?
	private var didTranscribeAnything = false
	/// Set while the package is replacing a socket, so the `.connecting` that
	/// follows a reconnect reads as recovery rather than as a fresh start.
	private var isRecovering = false
	/// Set the moment the user asks to stop, so a session that fails on the way
	/// down after handing back words does not raise an alert about it.
	private var isStopping = false
	/// Counts dictations. A pending second pass carries the generation it was
	/// snapshotted under and compares it against this to learn that a newer
	/// dictation owns the HUD — the same reason the close epilogue checks
	/// `self?.session == nil` before restoring the input device.
	private var dictationGeneration = 0
	/// The finalizer mode this session started with. Held rather than re-read at
	/// stop so flipping the setting mid-recording cannot promise a second pass
	/// over audio that was never retained.
	private var sessionTwoPassMode: TwoPassFinalizerMode = .off
	/// The options the running session started with, for the second pass to
	/// transcribe under the same language and mode.
	private var sessionOptions = TranscriptionOptions()
	/// The PCM format the running session streams in — the server's own, from its
	/// discovery entry. Held for the second pass, which reads the retained audio
	/// back and has to know what rate it is in. See WHI-71.
	private var sessionAudioFormat: DictationAudioFormat = .engine
	/// Everything the second pass needs, snapshotted by `stopStreaming` with no
	/// suspension in between, so no newer dictation can slip in before the
	/// snapshot exists. Consumed by `finalizeDictation`.
	private var pendingTwoPass: TwoPassContext?
	/// The in-flight second pass, kept so the next dictation can end the wait
	/// promptly instead of letting a stale pass run out its deadline.
	private var finalizeTask: (generation: Int, task: Task<TwoPassOutcome, Never>)?

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
		modelProvider: @escaping () -> String = { WhisperaSettings.speechServer.model },
		credentials: any DictationCredentialProvider = BackendCredentials.shared,
		urlSession: URLSession = .shared
	) {
		self.baseURLProvider = baseURLProvider
		self.serverIdProvider = serverIdProvider
		self.isDirect = directProvider
		self.directModel = modelProvider
		self.urlSession = urlSession
		self.engineCase = directProvider() ? .realtimeDirect : .whisperaStreaming
		self.credentials = credentials
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

	/// Backend mode lists one model per server, so the model list is the server
	/// list. Direct mode has no server registry to ask, so it asks the engine
	/// itself what it can run. Selecting one records which server/model to
	/// stream through.
	func models() async throws -> [TranscriptionModelInfo] {
		if isDirect() {
			return try await directModels()
		}
		return try await directory().servers()
			.filter { $0.supportsRealtime && $0.isOnline }
			.map { TranscriptionModelInfo(id: $0.id, displayName: "\($0.label) — \($0.model)") }
	}

	/// `GET <baseURL>/models`, OpenAI-compatible, through the package client.
	///
	/// The endpoint lists every model the engine serves — LLMs, TTS, embeddings
	/// on a multi-purpose host — so it is filtered to the ones that can
	/// transcribe, the same way backend mode filters servers to ones that support
	/// realtime. The request, the decoding and the filter are `WhisperaOpenAI`
	/// (WHI-93); what stays here is the mapping of its two failure shapes onto
	/// the messages this engine already shows.
	///
	/// A key is sent when the speech server has one. Direct mode used to send
	/// none on principle, which made "an OpenAI-compatible cloud" unreachable
	/// through a field labelled for a LAN engine — the same closed shape WHI-91
	/// removes from the LLM side.
	private func directModels() async throws -> [TranscriptionModelInfo] {
		guard let baseURL = baseURLProvider() else {
			throw StreamingTranscriberError.invalidServerURL
		}
		let destination = baseURL.host ?? baseURL.absoluteString
		let client = OpenAICompatibleClient(
			baseURL: baseURL,
			apiKeyProvider: WhisperaSettings.speechServer.keyProvider,
			session: urlSession,
			logger: .whispera)
		do {
			return try await client.transcriptionModels().map { TranscriptionModelInfo(id: $0.id) }
		} catch OpenAIError.noModelsAvailable {
			throw StreamingTranscriberError.noModelsInstalled(destination)
		} catch OpenAIError.http(let status, _) where status == 401 || status == 403 {
			// A server that answered is not an unreachable one, and saying so sends
			// the user to check whether it is running instead of at the thing that
			// is actually wrong. Same class of misdirection as the dictation path's
			// "sign in again" — see `failure(for:destination:reachedVia:)`.
			throw StreamingTranscriberError.engineRefused(destination, status: status)
		} catch {
			throw StreamingTranscriberError.engineUnreachable(destination)
		}
	}

	func selectModel(_ id: String) async throws {
		if isDirect() {
			UserDefaults.standard.set(id, forKey: ServerEntry.Capability.speech.modelKey)
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
		utteranceDraft.clear()
		live.reset()
	}

	func startStreaming(options: TranscriptionOptions) async throws {
		live.beginWaiting()
		live.waitingForModelStatusText = "Connecting to \(destinationName)…"
		didTranscribeAnything = false
		isRecovering = false
		isStopping = false
		startOutcome = nil
		// A dictation starting is what supersedes a pending second pass: the
		// pass belongs to the previous session's snapshot and the user has moved
		// on, so its wait ends now and its caller pastes the draft it already has.
		dictationGeneration += 1
		if let finalizeTask {
			AppLogger.shared.transcriber.info(
				"A new dictation superseded the pending two-pass finalize")
			finalizeTask.task.cancel()
		}
		finalizeTask = nil
		pendingTwoPass = nil
		sessionTwoPassMode = WhisperaSettings.twoPassFinalizer
		sessionOptions = options
		// A stale draft from the previous session must not prefix this one's
		// first partial.
		utteranceDraft.clear()

		do {
			// The previous session's microphone engine must be fully down before
			// this one opens its own, or the new capture starts against a device
			// the old engine still holds and delivers nothing.
			await awaitPreviousSessionClosed()

			var configuration = try await configuration(for: options)
			// Retention costs memory (the package caps it at ten minutes), so it
			// is paid only when a second pass will read the audio back.
			configuration.retainAudio = sessionTwoPassMode.isOn
			sessionAudioFormat = configuration.audioFormat

			// The input device the user picked has to be the system default before
			// the package opens its own capture, which follows the default.
			await AudioDeviceManager.shared.activateSelectedDevice()

			wordTracker = DictationWordTracker()
			wordTracker?.startNewSession()

			let session = DictationSession(
				configuration: configuration, credentials: credentials,
				audio: MicrophoneSource(format: configuration.audioFormat))
			self.session = session

			eventTask = Task { @MainActor [weak self] in
				for await event in session.events {
					self?.handle(event)
				}
				self?.finishStartIfPending(throwing: nil)
			}

			await session.start()
			try await awaitCaptureEstablished()
		} catch is CancellationError {
			// The user stopped before capture was established. The stop path owns
			// the state reset and the teardown; repeating either here would run
			// against whatever dictation is current by the time this resumes, and
			// there is no failure to report — ending a start is what was asked for.
			throw CancellationError()
		} catch {
			live.isWaitingForModel = false
			live.isTranscribing = false
			live.waitingForModelStatusText = ""
			live.shouldShowLiveTranscriptionWindow = false
			report(error)
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

	@discardableResult
	func stopStreaming() async -> String {
		isStopping = true
		live.isWaitingForModel = false
		live.waitingForModelStatusText = ""
		live.isTranscribing = false

		guard let session else {
			teardown()
			live.shouldShowLiveTranscriptionWindow = false
			AudioDeviceManager.shared.restoreSystemDefault()
			return LiveTranscriptionState.joined(
				committed: live.confirmedText, draft: live.pendingText
			).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		self.session = nil
		let tracker = wordTracker
		wordTracker = nil
		let events = eventTask
		eventTask = nil
		// A start still waiting on `.listening` resolves now, so its failure path
		// runs while this stop still owns the instance fields — not fifteen
		// seconds later, against a newer dictation's session.
		finishStartIfPending(throwing: CancellationError())

		// The transcript is already here: a streaming engine has fed every word
		// into the live state as it was spoken, so the socket's close handshake
		// adds nothing the paste needs. It used to gate the paste anyway, behind a
		// 3.5 s deadline race — and in QA even the deadline never fired, because
		// `addTask` children inherit this MainActor context and a wedged main
		// thread starves the timer along with everything else. So the stop path
		// now never suspends: take the words, hand them back, and let the close
		// run behind it. The draft is included — for a native-delta engine those
		// are real words the user spoke that the engine has not committed yet —
		// and a trailing final that lands after this is dropped on purpose.
		let transcript = LiveTranscriptionState.joined(
			committed: live.confirmedText, draft: live.pendingText
		).trimmingCharacters(in: .whitespacesAndNewlines)

		// This method has no suspension point before returning, so no newer
		// dictation can own the live state yet; promoting the draft here keeps
		// what the tracker and the HUD saw consistent with what gets pasted.
		if !transcript.isEmpty {
			live.ingest(committed: transcript, draft: "")
		}
		live.setPending("")
		live.shouldShowLiveTranscriptionWindow = false
		tracker?.endSession()
		events?.cancel()

		// The epilogue may take as long as the network wants; it touches only
		// this stop's snapshot, never the instance fields, which a newer dictation
		// may already own. cancel(), not finish(): finish() waits out trailing
		// silence plus the final-transcript timeout for a final this stop has
		// already chosen to drop. The input device is restored only after the
		// session's own microphone engine is down — switching the default device
		// under a still-running AVAudioEngine is the main-thread wedge suspected
		// in the QA hang — and only while no newer dictation has claimed it.
		closingTask = Task.detached { [weak self] in
			await session.cancel()
			await MainActor.run {
				guard self?.session == nil else { return }
				AudioDeviceManager.shared.restoreSystemDefault()
			}
		}

		if sessionTwoPassMode.isOn {
			// Snapshotted before this method returns — it still has no suspension
			// point — so the pass can never bind to a newer dictation's session.
			pendingTwoPass = TwoPassContext(
				session: session,
				audioFormat: sessionAudioFormat,
				closing: closingTask,
				mode: sessionTwoPassMode,
				options: sessionOptions,
				generation: dictationGeneration)
			// The paste is now waiting on the second pass. Announced on the
			// finalize channel, which only the listening pill renders: the words
			// window dismissed above, exactly as it does with the finalizer off,
			// and must not come back for the polish. Routing this through
			// isWaitingForModel put a second "Polishing…" capsule on screen.
			live.beginFinalizing(statusText: "Polishing…")
			AppLogger.shared.transcriber.info(
				"Remote live streaming stopped; draft held for the two-pass finalizer (\(sessionTwoPassMode.rawValue))")
			return transcript
		}

		AppLogger.shared.transcriber.info(
			"Remote live streaming stopped; returning the locally accumulated transcript")
		return transcript
	}

	/// Consumes the snapshot `stopStreaming` left behind and runs the second
	/// pass over the session's retained audio, bounded by the mode's deadline.
	/// Returns the polished transcript, or nil when the caller should paste the
	/// streaming draft — and logs which way it went and why.
	func finalizeDictation(draft: String) async -> String? {
		guard let pending = pendingTwoPass else { return nil }
		pendingTwoPass = nil

		AppLogger.shared.transcriber.info(
			"Two-pass finalize started (\(pending.mode.rawValue)); deadline \(pending.mode.deadline)s, draft \(draft.count) chars")

		let operation = finalizeOperation(for: pending)
		let race = Task { await TwoPassDeadline.race(seconds: pending.mode.deadline, operation: operation) }
		finalizeTask = (pending.generation, race)
		let outcome = await race.value
		// Guarded by generation: a rapid stop of the *next* dictation may have
		// installed its own pass here while this one was still resuming.
		if finalizeTask?.generation == pending.generation { finalizeTask = nil }

		// The polishing status belongs to this dictation alone; if a newer one
		// has started, it owns the HUD and nothing here may touch it.
		if pending.generation == dictationGeneration {
			live.endFinalizing()
		}

		if let text = TwoPassPolicy.finalizedText(from: outcome) {
			AppLogger.shared.transcriber.info(
				"Two-pass finalize produced \(text.count) chars; pasting the polished transcript")
			return text
		}
		let reason = TwoPassPolicy.fallbackReason(for: outcome) ?? "unknown"
		switch outcome {
		case .failed, .deadlineExpired:
			AppLogger.shared.transcriber.error(
				"Two-pass finalize failed; pasting the streaming draft: \(reason)")
		default:
			AppLogger.shared.transcriber.info(
				"Two-pass finalize skipped; pasting the streaming draft: \(reason)")
		}
		return nil
	}

	/// The pass itself, as a closure the deadline race can run off the main
	/// actor. Everything it needs is captured up front from the snapshot; it
	/// never reads instance state, which a newer dictation may own by the time
	/// it runs.
	private func finalizeOperation(for pending: TwoPassContext) -> @Sendable () async -> TwoPassOutcome {
		let session = pending.session
		let closing = pending.closing
		// The retained audio is in whatever format that session streamed in, which
		// is the server's, not the package default. Reading it back at 24 kHz when
		// the server asked for 16 would hand the second pass time-stretched audio.
		let audioFormat = pending.audioFormat
		let mode = pending.mode
		let options = pending.options
		let direct = isDirect()
		// Built here, on the actor, so the closure below stays free of
		// main-actor hops: the transcription backend is where discovery
		// advertises the batch capability, and its batch endpoint is the
		// existing POST /transcribe plumbing.
		let batchUploader = BackendTranscriber(
			baseURLProvider: { WhisperaSettings.transcriptionBackendURL },
			credentials: credentials)

		return {
			// The microphone half of the close is what stops frames being
			// retained; waiting for it makes capturedAudio() the whole utterance
			// rather than a prefix. It sits inside the deadline race, so a close
			// that hangs on the socket cannot hang the paste.
			if let closing { await closing.value }

			let audio = await session.capturedAudio()
			guard !audio.isEmpty else { return .noAudio }
			if await session.capturedAudioWasTruncated {
				// Finalize anyway: the buffer holds the most recent ten minutes,
				// and pasting an accurate tail beats failing the dictation.
				// Nothing user-visible is prepended.
				AppLogger.shared.transcriber.info(
					"Two-pass audio hit the retention cap; finalizing the retained tail only")
			}

			let samples = PCM16Resampler.float32Samples(
				fromPCM16LittleEndian: audio,
				sourceHz: audioFormat.sampleRate,
				targetHz: 16_000)

			switch mode {
			case .off:
				// Unreachable: stopStreaming only snapshots when the mode is on.
				return .failed("the finalizer is off")
			case .local:
				do {
					let text = try await WhisperKitTranscriber.shared.transcribe(
						samples: samples, options: options)
					return .finalized(text)
				} catch {
					return .failed("the on-device pass failed: \(error.localizedDescription)")
				}
			case .server:
				guard !direct else {
					// The batch upload is a backend route; a directly-addressed
					// realtime engine has no backend in the path to receive it.
					return .failed("the direct engine has no backend batch endpoint")
				}
				do {
					let text = try await batchUploader.transcribe(
						samples: samples, language: options.language)
					return .finalized(text)
				} catch {
					return .failed("the batch upload failed: \(error.localizedDescription)")
				}
			}
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

		case .partialTranscript(let delta):
			// A partial is a delta — only the fragment since the previous event, per
			// the OpenAI-Realtime contract — so it is appended to the utterance's
			// accumulator first. Passing the fragment alone as the draft made each
			// event replace the pill's tail with the latest few words instead of
			// growing it (nemo-stream QA, WHI-58). The accumulated draft also lands
			// in `pendingText`, which is what stop pastes for words still in flight.
			utteranceDraft.append(delta)
			live.ingest(committed: live.confirmedText, draft: utteranceDraft.draft)

		case .revisedTranscript(let hypothesis):
			// The engine re-sent the whole utterance rather than the fragment since
			// the last event, and said so. Replacing is the only correct move:
			// appending a string that already contains the draft renders the
			// sentence's own prefix twice, in the HUD and then in the paste. See
			// WHI-67/69 and `UtteranceDraftAccumulator`.
			utteranceDraft.replace(with: hypothesis)
			live.ingest(committed: live.confirmedText, draft: utteranceDraft.draft)

		case .finalTranscript:
			didTranscribeAnything = true
			// The utterance is settled; its deltas must not leak into the next one.
			utteranceDraft.clear()

		case .transcript(let whole):
			// The whole transcript already contains the utterance that just
			// finalized. Carrying that utterance forward as the draft — which this
			// used to do — put it in both halves at once, and the HUD showed it
			// twice until the next utterance's first partial replaced it. Clearing
			// the accumulator here as well covers an engine that emits the whole
			// transcript without a preceding final.
			utteranceDraft.clear()
			live.ingest(committed: whole, draft: "")

		case .audioLevel(let level):
			// The level meter wants samples, not an RMS. Spreading the reported
			// level across a short window is what the file-recorder path already
			// does with AVAudioRecorder's average power.
			onLiveAudioSamples?((0..<700).map { _ in level + Float.random(in: -0.02...0.02) })

		case .failed(let error):
			// Only terminal failures reach here — the package holds a recoverable one
			// back while it replaces the socket, and reports it only once the budget
			// is spent.
			AppLogger.shared.transcriber.error("Remote dictation failed: \(error.localizedDescription)")
			state = .unavailable(error.localizedDescription)
			live.isWaitingForModel = true
			live.waitingForModelStatusText = "Dictation stopped."
			live.shouldShowLiveTranscriptionWindow = true
			report(error)
			finishStartIfPending(throwing: error)
		}
	}

	private func handle(_ connectionState: DictationConnectionState) {
		switch connectionState {
		case .idle, .finishing:
			break

		case .connecting:
			// A reconnect emits `.reconnecting` and then `.connecting` again. Without
			// the flag the second one would read as a fresh connection and quietly
			// drop the warning that words are being missed right now.
			guard isRecovering else { break }
			live.waitingForModelStatusText = "Reconnecting to \(destinationName)…"

		case .reconnecting:
			isRecovering = true
			state = .preparing(progress: 0, status: "Reconnecting")
			live.isWaitingForModel = true
			live.waitingForModelStatusText = "Connection lost — reconnecting. Words spoken now are missed."
			live.shouldShowLiveTranscriptionWindow = true

		case .listening:
			if isRecovering {
				AppLogger.shared.transcriber.info("Remote session reconnected and is listening again")
			}
			isRecovering = false
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
				// A failure that arrives with words already in hand at the moment the
				// user is stopping is the end of a good dictation, not a lost one.
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

	/// What to call the thing on the other end, in a sentence a user reads.
	///
	/// The whole base URL for a direct engine, not just its host: the address is
	/// the thing the user typed and the thing they have to correct, and the part
	/// that was wrong in QA on 2026-08-23 was the missing `/v1` — invisible in a
	/// message that names only `192.168.50.140`.
	private var destinationName: String {
		if isDirect() {
			return baseURLProvider()?.absoluteString ?? "the transcription server"
		}
		let requested = serverIdProvider()
		if !requested.isEmpty { return requested }
		return cachedServer?.label ?? "the transcription server"
	}

	/// Turns a failure into something the user can act on, and raises it where it
	/// will be seen. Silent while the user is already stopping a dictation that
	/// produced words — interrupting them to report the end of a session they
	/// ended, and got what they wanted from, would be noise.
	private func report(_ error: Error) {
		guard !(isStopping && didTranscribeAnything) else { return }
		let failure = Self.failure(
			for: error, destination: destinationName, reachedVia: isDirect() ? .direct : .backend)
		live.failure = failure
		AppLogger.shared.transcriber.error(
			"Surfacing dictation failure: \(failure.title) — \(failure.message)")
		NotificationCenter.default.post(name: .transcriptionFailureRaised, object: nil)
	}

	/// How the failed connection was addressed, which is what decides whether an
	/// authorization failure has anything to do with the user's account.
	///
	/// A direct engine is reached with its own key, or with none at all — there
	/// is no Whispera account in the path — so telling its user to "sign in again
	/// under Account settings" points at a screen that cannot fix anything. QA on
	/// 2026-08-23 hit exactly that: a credential-less LAN speaches answered 403
	/// because the base URL had lost its `/v1` and the socket asked for
	/// `/realtime`, and the app blamed the user's credentials for it.
	enum FailureRoute {
		/// Through the Whispera backend, which does authenticate the account.
		case backend
		/// Straight at a server the user configured, with its own key or none.
		case direct
	}

	static func failure(
		for error: Error, destination: String, reachedVia route: FailureRoute = .backend
	) -> TranscriptionFailure {
		let title = "Dictation stopped"
		if let dictationError = error as? DictationError {
			switch dictationError {
			case .unauthorized, .credentialUnavailable:
				switch route {
				case .backend:
					return TranscriptionFailure(
						title: title,
						message:
							"\(destination) rejected your credentials. Sign in again under Account settings, then start dictation again."
					)
				case .direct:
					return TranscriptionFailure(
						title: title,
						message:
							"\(destination) refused the connection with an authorization error (HTTP 401 or 403). "
							+ "Whispera sends no account credential to a server you address directly, so this is that "
							+ "server's own refusal: check that the base URL ends in /v1 — the realtime socket opens "
							+ "at /v1/realtime — and that the key saved for it under Settings › Servers is the one it expects."
					)
				}
			case .connectionFailed(let why):
				// A LAN address that cannot be reached is far more often the
				// local-network grant than a stopped server, and macOS reports the
				// refusal as the same -1009 it uses for "this Mac is offline" — so
				// the ordinary message sent QA to check a server that was running
				// fine. See `LocalNetworkAccess`.
				if let advice = LocalNetworkAccess.advice(forFailure: why, destination: destination) {
					return TranscriptionFailure(title: title, message: advice)
				}
				return TranscriptionFailure(
					title: title,
					message:
						"Whispera could not reach \(destination). Check that the server is running and that this Mac can reach it on the network."
				)
			case .closedUnexpectedly:
				return TranscriptionFailure(
					title: title,
					message:
						"The connection to \(destination) dropped and reconnecting did not help. Check that the server is still running, then start dictation again."
				)
			case .protocolViolation:
				return TranscriptionFailure(
					title: title,
					message:
						"\(destination) answered with something Whispera did not understand. Check that the server URL points at an OpenAI-Realtime endpoint."
				)
			case .audioUnavailable:
				return TranscriptionFailure(
					title: title,
					message:
						"Whispera could not open the microphone. Check System Settings > Privacy & Security > Microphone."
				)
			case .server:
				return TranscriptionFailure(
					title: title,
					message:
						"\(destination) reported an error and reconnecting did not help. Its own log will say why; Whispera's log has the message it sent."
				)
			}
		}
		if let described = (error as? LocalizedError)?.errorDescription {
			return TranscriptionFailure(title: title, message: described)
		}
		return TranscriptionFailure(
			title: title,
			message:
				"Whispera could not run this dictation through \(destination). Check the server settings under Transcription."
		)
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
			closingTask = Task { await closing.cancel() }
		}
	}

	/// Waits for the previous session's close to finish, bounded: the microphone
	/// half of a close is local and quick — and it is the half the next capture
	/// needs done — while the socket half may take as long as the network wants,
	/// and a slow server must not hold the user's next dictation hostage.
	///
	/// Not a task group: awaiting a never-failing task's `value` cannot be
	/// interrupted, and a group would wait for that child anyway at its scope's
	/// end. Two independent observers race to resume one continuation instead;
	/// whichever loses resumes into nothing.
	private func awaitPreviousSessionClosed() async {
		guard let closing = closingTask else { return }
		closingTask = nil
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let handoff = ResumeOnce(continuation)
			Task.detached {
				await closing.value
				handoff.resume()
			}
			Task.detached {
				try? await Task.sleep(nanoseconds: UInt64(Self.closeHandoverTimeout * 1_000_000_000))
				handoff.resume()
			}
		}
	}

	private static let closeHandoverTimeout: Double = 2

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
			// Belt and braces with the settings probe: a server configured before
			// this build shipped, or on another Mac and synced, has never been
			// touched, and the first dictation must not be where the user meets the
			// silent -1009.
			LocalNetworkPrimer.shared.prime(for: baseURL)
			AppLogger.shared.transcriber.info(
				"Streaming direct to \(baseURL.absoluteString) (\(model)); no backend in the path")
			return .directEngine(baseURL, model: model, language: options.language)
		}
		let server = try await resolveServer()
		// The format the server advertised, not a constant. Two engines behind one
		// backend need not agree on a sample rate, and one that disagrees is not
		// rejected — speaches silently time-compresses mismatched audio, so the
		// transcript still reads plausibly while being wrong. See WHI-71.
		return .backend(
			baseURL, server: server.id, model: server.model, language: options.language,
			audio: server.audioFormat)
	}
}

/// One stopped dictation's claim on a second pass: the session whose retained
/// audio to read, the close to wait out first, and the generation that says
/// whether the dictation it belongs to is still the current one. A snapshot,
/// deliberately — the pass must never read instance fields a newer dictation
/// owns, the same rule the close epilogue follows.
private struct TwoPassContext {
	let session: DictationSession
	/// The PCM format that session streamed in — the server's, per WHI-71.
	let audioFormat: DictationAudioFormat
	let closing: Task<Void, Never>?
	let mode: TwoPassFinalizerMode
	let options: TranscriptionOptions
	let generation: Int
}

/// Resumes a continuation exactly once, whichever of two racing observers gets
/// there first. See `StreamingTranscriber.awaitPreviousSessionClosed`.
private final class ResumeOnce: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Void, Never>?

	init(_ continuation: CheckedContinuation<Void, Never>) {
		self.continuation = continuation
	}

	func resume() {
		lock.lock()
		let continuation = self.continuation
		self.continuation = nil
		lock.unlock()
		continuation?.resume()
	}
}

enum StreamingTranscriberError: LocalizedError, Equatable {
	case notSignedIn
	case invalidServerURL
	case noRealtimeServer(requested: String)
	case serverCannotStream(String)
	case captureTimedOut
	case engineUnreachable(String)
	case engineRefused(String, status: Int)
	case noModelsInstalled(String)

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
		case .engineUnreachable(let destination):
			return
				"Could not reach \(destination) to list its models. Check that the engine is running and reachable at the configured URL."
		case .engineRefused(let destination, let status):
			return
				"\(destination) refused the request with HTTP \(status). Check that the base URL ends in /v1 and that the key saved for this server is the one it expects."
		case .noModelsInstalled(let destination):
			return "\(destination) is reachable but reports no installed speech-to-text models."
		}
	}
}
