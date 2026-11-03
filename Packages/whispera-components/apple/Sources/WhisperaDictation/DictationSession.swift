import Foundation

/// One dictation: a socket, an audio source, and the events that come out.
///
/// An actor because three things run concurrently against the same state — the
/// receive loop, the audio pump, and the host calling `finish()` — and the
/// alternative is a lock around every field plus the ordering bugs that follow.
public actor DictationSession {
	private let configuration: DictationConfiguration
	private let credentials: DictationCredentialProvider
	private let audio: DictationAudioSource
	private let makeTransport: DictationTransportFactory

	/// The events. One stream, one consumer — a host wanting to fan out should do
	/// so on its own side, where it knows whether it wants replay, buffering, or
	/// back-pressure.
	public nonisolated let events: AsyncStream<DictationEvent>
	private nonisolated let emit: AsyncStream<DictationEvent>.Continuation

	private var transport: DictationTransport?
	private var runTask: Task<Void, Never>?
	private var settleTask: Task<Void, Never>?
	private var handshakeTask: Task<Void, Never>?
	private var closeTimeoutTask: Task<Void, Never>?
	private var state: DictationConnectionState = .idle

	/// Utterances the engine has committed, in order.
	private var committed: [String] = []
	/// Resumed by the receive loop when the engine acknowledges the session.
	private var sessionReady: [CheckedContinuation<Void, Never>] = []
	private var isSessionReady = false
	/// Resumed when it is time to close: a final arrived and settled, or we waited
	/// long enough.
	private var closeReady: [CheckedContinuation<Void, Never>] = []
	private var hasFlushed = false
	/// Set when the engine closes a turn. Stops the trailing-silence loop, which
	/// must not keep pushing once the utterance is already committed.
	private var hasCommittedSinceFlush = false
	/// The engine's own VAD threshold, learned from `session.created` and echoed
	/// back in `session.update` so that overriding turn detection does not silently
	/// change it.
	private var engineSilenceDurationMs: Int?
	private var engineSilenceDuration: Double? {
		engineSilenceDurationMs.map { Double($0) / 1000 }
	}
	/// The engine's own VAD threshold and padding, learned the same way. Never
	/// overridden — only echoed — but the echo is not optional: see
	/// `RealtimeProtocol.sessionUpdate` for why leaving either out silently drops
	/// the whole `turn_detection` block speaches receives, `create_response: false`
	/// included.
	private var engineThreshold: Double?
	private var enginePrefixPaddingMs: Int?
	/// The item id and text of the last utterance actually committed, so a
	/// re-emitted `transcriptCompleted` can be told apart from a genuinely new one.
	///
	/// speaches 0.9.0-rc.3 can send `conversation.item.input_audio_transcription.completed`
	/// more than once for the same item — observed whenever the engine's VAD
	/// re-fires a turn it already closed (see `RealtimeProtocol.decode`'s handling
	/// of the "already exists" error, which is the other symptom of the same
	/// re-fire). Without this, a doubled event pastes the utterance twice.
	private var lastCompletedItemId: String?
	private var lastCompletedText: String?
	private var isFinished = false
	/// Set the moment the host asks to stop, before any of the waiting begins. A
	/// reconnect must never reopen the microphone after the user has let go of the
	/// key.
	private var stopRequested = false

	public init(
		configuration: DictationConfiguration,
		credentials: DictationCredentialProvider,
		audio: DictationAudioSource,
		transport: DictationTransportFactory = .urlSession
	) {
		self.configuration = configuration
		self.credentials = credentials
		self.audio = audio
		self.makeTransport = transport

		// Unbounded: dropping an event would mean dropping a transcript. The volume
		// is a handful of events per utterance plus one level per audio chunk.
		let (stream, continuation) = AsyncStream<DictationEvent>.makeStream(
			bufferingPolicy: .unbounded)
		self.events = stream
		self.emit = continuation
	}

	// MARK: - Lifecycle

	/// Connects and begins streaming. Returns immediately; everything is reported
	/// through `events`.
	public func start() {
		guard runTask == nil else { return }
		runTask = Task { await self.run() }
	}

	/// Ends the audio, waits for the engine to commit what it heard, and closes.
	///
	/// Returns the full transcript. Separate from `cancel()` because the last
	/// utterance is usually the one the user cares about, and it does not exist yet
	/// at the moment they stop speaking.
	@discardableResult
	public func finish() async -> String {
		guard !isFinished else { return transcript }
		stopRequested = true
		// A session that was never started has nothing to wait for, and waiting
		// anyway would hang until the timeout for no reason.
		guard runTask != nil else {
			await teardown(reason: .finished)
			return transcript
		}
		// Ends the frames() stream, which is what the pump treats as "flush now".
		audio.stop()
		await waitForClose()
		await teardown(reason: .finished)
		return transcript
	}

	/// Stops everything now, without waiting for a final transcript.
	public func cancel() async {
		stopRequested = true
		await teardown(reason: .cancelled)
	}

	/// Everything committed so far.
	public var transcript: String {
		committed.joined(separator: " ")
	}

	// MARK: - Captured audio

	/// The audio this session has sent, when `configuration.retainAudio` asked for
	/// it. Empty otherwise.
	///
	/// Engine-format PCM16 — 24 kHz mono little-endian — and specifically the
	/// *normalized* bytes, captured at the moment the pump sends them: after
	/// resampling and downmixing, before the synthetic trailing silence the flush
	/// appends. A second, slower transcription pass run over these bytes hears
	/// exactly what the streaming engine heard.
	///
	/// Callable mid-session and after `finish()`/`cancel()` alike — teardown
	/// deliberately leaves the buffer alone, so a host can close the session first
	/// and re-transcribe afterwards. The copy lives as long as the session object
	/// does.
	public func capturedAudio() -> Data {
		retainedAudio
	}

	/// Whether the ten-minute retention cap ever forced the oldest audio out.
	///
	/// When it did, `capturedAudio()` holds the most recent ten minutes — the tail,
	/// not the head — and a host showing the second-pass transcript should say so
	/// rather than present it as the whole session.
	public var capturedAudioWasTruncated: Bool {
		retainedTruncated
	}

	/// Engine-format bytes retained for `capturedAudio()`.
	private var retainedAudio = Data()
	private var retainedTruncated = false
	/// Ten minutes of engine audio — at the default 24 000 Hz × 2 bytes × 600 s ≈
	/// 28.8 MB. A cap because "retain the session" must not quietly mean "grow
	/// without bound" for a host that leaves a session running. Measured in the
	/// server's own format, not a constant, so a 16 kHz engine retains ten minutes
	/// rather than fifteen.
	private var retentionCap: Int { configuration.audioFormat.byteCount(forSeconds: 600) }

	/// Keeps a copy of one outgoing frame, dropping the oldest audio once the cap
	/// is reached.
	private func retain(_ pcm: Data) {
		guard configuration.retainAudio else { return }
		retainedAudio.append(pcm)
		let overflow = retainedAudio.count - retentionCap
		guard overflow > 0 else { return }
		// Rounded up to a whole frame, so a drop can never split a sample and turn
		// the rest of the buffer into byte-swapped noise.
		let bytesPerFrame = configuration.audioFormat.bytesPerFrame
		let wholeFrames = (overflow + bytesPerFrame - 1) / bytesPerFrame
		let drop = min(retainedAudio.count, wholeFrames * bytesPerFrame)
		retainedAudio.removeFirst(drop)
		retainedTruncated = true
	}

	// MARK: - The run loop

	private func run() async {
		await connectLoop()
		// The single exit. Every way the loop can end — a clean close, a failure, a
		// spent retry budget — lands here, and teardown is what closes the socket,
		// stops the audio source, and finishes the event stream.
		//
		// Releasing the `finish()` waiter without tearing down, which is what this
		// used to do, is not enough: a session whose socket closes on its own leaves
		// `isFinished` false and `runTask` non-nil, so a `finish()` arriving after
		// that moment waits on a continuation nobody will ever resume. The transport
		// and the audio tap leak with it. `teardown` picks the reason from any
		// recorded failure, so a session that failed cannot report `.finished`.
		await teardown(reason: .finished)
	}

	private func connectLoop() async {
		// Exactly one extra attempt, and the budget is spent on the *first*
		// rejection rather than reset per connect: a genuinely bad credential must
		// fail fast instead of hammering the auth provider in a loop.
		var mayRetry = true

		while !isFinished {
			setState(.connecting)

			let credential: DictationCredential
			do {
				// On every connect, not once at construction. This is the whole
				// reason 60-second tokens survive: by the time a reconnect happens
				// the token minted at setup is long dead.
				credential = try await credentials.credential()
			} catch {
				fail(.credentialUnavailable(error.localizedDescription))
				return
			}

			let transport = makeTransport()
			self.transport = transport

			do {
				try await transport.connect(to: try configuration.request(with: credential))
			} catch let error as DictationError {
				await transport.close()
				if case .unauthorized = error, mayRetry {
					// The one retry: ask the provider again — which is what mints a
					// fresh token — and reconnect.
					mayRetry = false
					continue
				}
				fail(error)
				if await reconnect() { continue }
				return
			} catch {
				await transport.close()
				// A first connect that fails on the transport is worth another go
				// before it is shown to anyone: the measured failure here was an
				// instant "The Internet connection appears to be offline." followed by
				// an immediate retry that worked. `fail` holds it back if it is
				// recoverable; if it is not, it has already been reported.
				fail(.connectionFailed(error.localizedDescription))
				if await reconnect() { continue }
				return
			}

			let outcome = await converse(over: transport)
			switch outcome {
			case .unauthorized where mayRetry && !hasStartedAudio:
				// A 4401 arrives as a close frame rather than a refused upgrade when
				// the server accepts the socket before validating. Same budget.
				mayRetry = false
				await transport.close()
				resetForRetry()
				continue
			case .unauthorized:
				// Not retried once the audio has already been drained. A second
				// attempt would re-subscribe to a source that has nothing left —
				// `PushAudioSource` hands back an empty stream and `AudioFileSource`
				// replays from the top — so the retry would "succeed" while sending
				// nothing but silence, and the host would get an empty transcript
				// with no error at all. Failing honestly is better.
				fail(.unauthorized)
				return
			case .ended:
				// Closed only on the way to a replacement. A session that ended
				// cleanly is closed exactly once, by teardown.
				if lostConnection != nil { await transport.close() }
				if await reconnect() { continue }
				return
			}
		}
	}

	private enum Outcome { case unauthorized, ended }

	/// A recoverable failure that has been held back rather than reported, waiting
	/// for `connectLoop` to decide whether another socket is worth opening.
	private var lostConnection: DictationError?
	private var reconnectsUsed = 0

	/// Whether this failure should be held for a reconnect instead of ending the
	/// dictation.
	private func canRecover(from error: DictationError) -> Bool {
		guard error.isRecoverable else { return false }
		guard !isFinished, !stopRequested else { return false }
		guard reconnectsUsed < configuration.reconnectLimit else { return false }
		// Past the flush there is no audio left to send, so a new socket would only
		// wait out its own timeout before reporting the same thing later.
		guard !hasFlushed else { return false }
		return audio.canRestart || !hasStartedAudio
	}

	/// Consumes a held failure and prepares another attempt. `false` means there
	/// was nothing to recover from, or that recovering is no longer wanted.
	private func reconnect() async -> Bool {
		guard lostConnection != nil, !isFinished, !stopRequested else { return false }
		reconnectsUsed += 1
		setState(.reconnecting(attempt: reconnectsUsed))
		resetForRetry()

		// Backed off so that a server which is down for a moment is given a moment,
		// and doubled per attempt so that raising the limit does not turn into a
		// tight loop against something that is simply gone.
		let delay = configuration.reconnectBackoff * pow(2, Double(reconnectsUsed - 1))
		try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		// The host may have stopped during the backoff. Returning false drops the
		// loop out into `run`'s teardown, which is what releases its waiter.
		return !isFinished && !stopRequested
	}

	/// One connected session, from `session.created` to close.
	private func converse(over transport: DictationTransport) async -> Outcome {
		let receiver = Task { await self.receiveLoop(transport) }
		defer { receiver.cancel() }

		// The engine speaks first. Sending `session.update` before `session.created`
		// works against this proxy — it queues — but that is a property of the relay,
		// not of the protocol.
		//
		// Bounded, because "connected" and "there is a session" are not the same
		// thing: the transport deliberately returns before the handshake completes,
		// so this wait is where a refused upgrade or an engine that never answers
		// actually gets noticed.
		startHandshakeTimeout()
		await waitForSessionReady()
		// Disarmed the moment it is no longer guarding anything, so it cannot fire
		// into the next attempt.
		handshakeTask?.cancel()
		handshakeTask = nil
		guard !isFinished else { return .ended }
		if unauthorizedSeen { return .unauthorized }
		guard isSessionReady else {
			fail(handshakeFailure ?? .connectionFailed(
				"the server did not start a session within "
					+ String(format: "%g", configuration.handshakeTimeout) + "s"))
			return .ended
		}

		do {
			try await transport.send(
				RealtimeProtocol.sessionUpdate(
					model: configuration.model, language: configuration.language,
					// The configured override wins when set; otherwise the engine's own
					// value is echoed back unchanged, which is what happened before this
					// knob existed.
					silenceDurationMs: configuration.vadSilenceDurationMs ?? engineSilenceDurationMs,
					threshold: engineThreshold,
					prefixPaddingMs: enginePrefixPaddingMs))
		} catch {
			fail(.connectionFailed(error.localizedDescription))
			return .ended
		}

		setState(.listening)
		await pumpAudio(into: transport)
		// A held failure means this socket is being abandoned. Closing it here is
		// what unblocks the receive loop — if the failure came from the send side it
		// is still parked in `receive()`, and waiting for it would hang the reconnect
		// behind the socket it is replacing.
		if lostConnection != nil {
			await transport.close()
			return .ended
		}
		await receiver.value
		return unauthorizedSeen ? .unauthorized : .ended
	}

	private var unauthorizedSeen = false
	/// A failure seen before the session existed, held back until `converse`
	/// decides whether it is worth a retry.
	private var handshakeFailure: DictationError?

	// MARK: - Audio

	/// Set once the audio source has been subscribed to, because a source can only
	/// be consumed once — which bounds when a reconnect is still safe.
	private var hasStartedAudio = false

	private func pumpAudio(into transport: DictationTransport) async {
		hasStartedAudio = true
		let engineFormat = configuration.audioFormat
		var normalizer = AudioNormalizer(from: audio.format, to: engineFormat)
		// Floored at one frame. `chunkDuration` is a public var, and a value small
		// enough to round to zero bytes turns both the re-chunking loop below and
		// the silence loop in `flush` into infinite loops emitting empty frames.
		let targetChunk = max(
			engineFormat.bytesPerFrame,
			engineFormat.byteCount(forSeconds: configuration.chunkDuration))
		var outbound = Data()

		// Only a live source is paced, and only when the host asked for it. See
		// `DictationConfiguration.maxAudioAheadOfRealtime` for why a file is not.
		let allowance = audio.isLive ? configuration.maxAudioAheadOfRealtime : nil
		// Set on the *first* frame, not here. `DictationAudioPacing.delay` is
		// documented as taking "wall clock since the first frame", and starting
		// the clock at subscription instead charged the pacer for everything
		// between opening the stream and the microphone's first callback — a
		// permanent head start that read as "the sender is behind" for the whole
		// dictation, which is precisely the state the catch-up cadence below has
		// to be able to distinguish from a real backlog.
		var startedAt: Date?
		var secondsSent = 0.0

		for await chunk in audio.frames() {
			// `lostConnection` as well as `isFinished`: a held failure leaves the
			// session alive on purpose, and without this the pump would keep feeding a
			// dead socket until the user stopped talking.
			if isFinished || lostConnection != nil { break }
			let (pcm, level) = normalizer.normalize(chunk)
			emit.yield(.audioLevel(level))
			guard !pcm.isEmpty else { continue }
			if startedAt == nil { startedAt = Date() }

			// Re-chunked on the way out rather than forwarded one tap buffer per
			// frame: the input chunk size belongs to whoever is producing audio, and
			// the frame size belongs to this package.
			outbound.append(pcm)
			while outbound.count >= targetChunk {
				let frame = Data(outbound.prefix(targetChunk))
				outbound = Data(outbound.dropFirst(targetChunk))
				// Retained here, at the send, and not in `flush` — so the copy is
				// exactly the audio that went to the wire, and never the synthetic
				// trailing silence, which a second pass has no use for.
				retain(frame)
				if let allowance, let startedAt {
					// Waited *before* the send, not after: the point is to keep a
					// backlog from reaching the engine as a burst, and a delay applied
					// afterwards has already let the burst through. A dictation that is
					// keeping up never waits at all — `delay` is zero both when audio
					// is at the clock and when it is only a chunk or two behind it.
					//
					// The four-argument form is what covers the backlog *behind* the
					// clock, which the three-argument one let through at socket speed.
					// It has to, now that the microphone no longer discards a backlog
					// to keep itself small: unpaced, that drain is WHI-70's burst; at
					// `catchUpRate` it is a fast but ordinary stream of frames.
					let wait = DictationAudioPacing.delay(
						audioSent: secondsSent,
						elapsed: Date().timeIntervalSince(startedAt),
						allowance: allowance,
						chunkDuration: configuration.chunkDuration)
					if wait > 0 {
						try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
					}
				}
				secondsSent +=
					Double(frame.count / max(1, engineFormat.bytesPerFrame))
					/ Double(max(1, engineFormat.sampleRate))
				await sendAudio(frame, over: transport)
			}
		}

		// Neither the tail nor the flush belongs on a socket that is about to be
		// replaced; the reconnected session flushes its own audio when it ends.
		if isFinished || lostConnection != nil { return }
		if !outbound.isEmpty {
			retain(outbound)
			await sendAudio(outbound, over: transport)
		}

		// The microphone reports a failure to open through the source rather than
		// the stream, which has no channel for one; without this, a denied
		// permission looks identical to a zero-length recording.
		if let source = audio as? MicrophoneSource, let error = source.startError {
			fail(.audioUnavailable(error.localizedDescription))
			return
		}

		await flush(over: transport)
	}

	private func sendAudio(_ pcm: Data, over transport: DictationTransport) async {
		do {
			try await transport.send(RealtimeProtocol.audioAppend(pcm: pcm))
		} catch {
			fail((error as? DictationError) ?? .connectionFailed(error.localizedDescription))
		}
	}

	/// Ends the utterance so the engine will commit it.
	private func flush(over transport: DictationTransport) async {
		guard !hasFlushed, !isFinished else { return }
		hasFlushed = true
		// Commits from earlier utterances must not satisfy the loop below — the
		// flag answers "did the VAD close the turn we are flushing right now", so
		// a multi-utterance dictation has to start the flush with a clean slate or
		// the silence loop exits immediately, the in-flight utterance never
		// commits, and finish() sits out the whole finalTranscriptTimeout.
		hasCommittedSinceFlush = false
		setState(.finishing)

		// Silence is what server-side VAD needs in order to decide the turn is over.
		// End the stream on the last syllable and the VAD never fires, so the final
		// utterance — often the only one — is never transcribed.
		//
		// Sending *too much* is equally fatal, which is the part that is not
		// obvious. Once the VAD has closed a turn, every further chunk of silence
		// makes speaches close it again, and each re-close tries to add the same
		// conversation item; after the first duplicate the engine answers
		// `Error adding item: the item with id '…' already exists` and abandons the
		// transcript entirely. Measured against speaches at 24 kHz with this exact
		// fixture: 0.6 s of trailing silence produced one commit and a correct
		// transcript, 0.8 s produced five commits and no transcript at all, and
		// 2.0 s produced twenty-five.
		//
		// So the amount is derived rather than guessed. `session.created` advertises
		// the engine's own `silence_duration_ms`; one extra chunk past it is enough
		// to trip the VAD exactly once. `trailingSilence` remains the ceiling for an
		// engine that does not advertise one.
		let budget = configuration.trailingSilence
		let target = engineSilenceDuration.map { min(budget, $0 + configuration.chunkDuration) } ?? budget
		let silence = Data(count: configuration.audioFormat.byteCount(forSeconds: target))
		let chunk = max(
			configuration.audioFormat.bytesPerFrame,
			configuration.audioFormat.byteCount(forSeconds: configuration.chunkDuration))
		let chunkNanoseconds = UInt64(configuration.chunkDuration * 1_000_000_000)

		var offset = 0
		while offset < silence.count, !isFinished, !hasCommittedSinceFlush {
			let end = min(offset + chunk, silence.count)
			await sendAudio(silence.subdata(in: offset..<end), over: transport)
			offset = end
			// Paced, not blasted. Firing the whole tail into the socket at once
			// means the engine's "turn closed" reply cannot arrive until long after
			// the damage is done, which makes the check above useless; at playback
			// rate the reply lands within a chunk or two of the VAD firing.
			try? await Task.sleep(nanoseconds: chunkNanoseconds)
		}
		if configuration.sendsExplicitCommit {
			try? await transport.send(RealtimeProtocol.audioCommit())
		}

		// Nothing may arrive at all — a silent recording produces no transcript and
		// no error — so the wait is bounded.
		startCloseTimeout()
	}

	// MARK: - Receive

	private func receiveLoop(_ transport: DictationTransport) async {
		while !Task.isCancelled {
			let frame: DictationTransportFrame?
			do {
				frame = try await transport.receive()
			} catch {
				let dictationError =
					(error as? DictationError) ?? .connectionFailed(error.localizedDescription)
				if case .unauthorized = dictationError {
					// The refused upgrade only becomes visible here, because the
					// transport returns before the handshake completes. Recorded
					// rather than reported, so `run` can spend its one retry on a
					// freshly-minted credential.
					unauthorizedSeen = true
				} else if !isFinished {
					// Held rather than emitted when the session never started: the
					// same failure may be about to be retried, and reporting it now
					// would show the host an error for an attempt that then succeeds.
					if isSessionReady {
						fail(dictationError)
					} else {
						handshakeFailure = dictationError
					}
				}
				releaseSessionWaiters()
				return
			}

			guard let frame else { releaseSessionWaiters(); return }

			switch frame {
			case .text(let text):
				handle(text)
			case .closed(let code, let reason):
				// 4401 is the documented unauthorized close. It is handled alongside
				// the refused upgrade because which of the two a deployment produces
				// depends on whether it validates before or after accepting.
				if code == 4401 {
					unauthorizedSeen = true
				} else if !hasFlushed, !isFinished, code != 1000 {
					fail(.closedUnexpectedly(code: code, reason: reason))
				}
				releaseSessionWaiters()
				return
			}
		}
	}

	private func handle(_ text: String) {
		let inbound: RealtimeProtocol.Inbound
		do {
			inbound = try RealtimeProtocol.decode(text)
		} catch {
			fail((error as? DictationError) ?? .protocolViolation(error.localizedDescription))
			return
		}

		switch inbound {
		case .sessionCreated(_, let silenceDurationMs, let threshold, let prefixPaddingMs):
			if let silenceDurationMs { engineSilenceDurationMs = silenceDurationMs }
			if let threshold { engineThreshold = threshold }
			if let prefixPaddingMs { enginePrefixPaddingMs = prefixPaddingMs }
			markSessionReady()
		case .transcriptDelta(let text) where !text.isEmpty:
			emit.yield(.partialTranscript(text))
		case .transcriptHypothesis(let text) where !text.isEmpty:
			emit.yield(.revisedTranscript(text))
		case .transcriptCompleted(let text, let itemId):
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { break }
			// A re-fired item id is the reliable signal — text alone would falsely
			// dedupe two different utterances that happen to say the same thing
			// ("okay", "okay"). Only fall back to comparing text when the engine
			// omits the id, so this still protects hosts against an engine that
			// doubles a completed event without one.
			let isDuplicate: Bool =
				if let itemId, let lastCompletedItemId { itemId == lastCompletedItemId } else {
					itemId == nil && trimmed == lastCompletedText
				}
			guard !isDuplicate else { break }
			lastCompletedItemId = itemId
			lastCompletedText = trimmed
			committed.append(trimmed)
			emit.yield(.finalTranscript(trimmed))
			emit.yield(.transcript(transcript))
			// A second utterance can still be in flight, so closing on the first
			// final would truncate. Settle instead: close once nothing new has
			// arrived for a beat.
			if hasFlushed { startSettle() }
		case .failed(let message, let code):
			fail(.server(message: message, code: code))
		case .committed, .speechStopped:
			// Either is the engine saying the turn is closed, which is the signal to
			// stop feeding silence.
			hasCommittedSinceFlush = true
		case .sessionUpdated, .speechStarted, .other, .transcriptDelta, .transcriptHypothesis:
			break
		}
	}

	// MARK: - Coordination

	/// The engine acknowledged the session. Distinct from merely unblocking the
	/// waiters — a socket that died during the handshake also has to unblock them,
	/// and the difference between the two is exactly what `converse` checks.
	private func markSessionReady() {
		guard !isSessionReady else { return }
		isSessionReady = true
		releaseSessionWaiters()
	}

	private func releaseSessionWaiters() {
		let waiters = sessionReady
		sessionReady = []
		for waiter in waiters { waiter.resume() }
	}

	/// Retained so it can be cancelled, which is the point.
	///
	/// An unstored timer outlives the attempt that armed it. After a 4401 the retry
	/// arms a second one while the first is still counting against the *old*
	/// deadline, so a healthy second attempt gets released early and reported as a
	/// server that never answered. The `Task.isCancelled` check inside is dead code
	/// unless somebody holds the handle.
	private func startHandshakeTimeout() {
		handshakeTask?.cancel()
		handshakeTask = Task { [configuration] in
			try? await Task.sleep(nanoseconds: UInt64(configuration.handshakeTimeout * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self.releaseSessionWaiters()
		}
	}

	private func waitForSessionReady() async {
		guard !isSessionReady, !isFinished else { return }
		await withCheckedContinuation { continuation in
			if isSessionReady || isFinished {
				continuation.resume()
			} else {
				sessionReady.append(continuation)
			}
		}
	}

	private func waitForClose() async {
		guard !isFinished else { return }
		await withCheckedContinuation { continuation in
			if isFinished {
				continuation.resume()
			} else {
				closeReady.append(continuation)
			}
		}
	}

	/// Close once the transcript has stopped growing for a beat.
	private func startSettle() {
		settleTask?.cancel()
		settleTask = Task { [configuration] in
			// Short relative to the timeout: this only has to outlast the gap
			// between two consecutive committed utterances.
			try? await Task.sleep(nanoseconds: UInt64(min(1.0, configuration.finalTranscriptTimeout) * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self.releaseClose()
		}
	}

	private func startCloseTimeout() {
		closeTimeoutTask?.cancel()
		closeTimeoutTask = Task { [configuration] in
			try? await Task.sleep(
				nanoseconds: UInt64(configuration.finalTranscriptTimeout * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self.releaseClose()
		}
	}

	private func releaseClose() {
		let waiters = closeReady
		closeReady = []
		for waiter in waiters { waiter.resume() }
	}

	/// Unblocks everything waiting, for when the socket has gone away. Does *not*
	/// claim the session was ready — a handshake that died still has to release
	/// its waiter, and calling it ready would send audio into a dead socket.
	private func releaseAll() {
		releaseSessionWaiters()
		releaseClose()
	}

	private func resetForRetry() {
		lostConnection = nil
		handshakeTask?.cancel()
		handshakeTask = nil
		closeTimeoutTask?.cancel()
		closeTimeoutTask = nil
		isSessionReady = false
		unauthorizedSeen = false
		handshakeFailure = nil
		hasFlushed = false
		hasCommittedSinceFlush = false
		engineSilenceDurationMs = nil
		engineThreshold = nil
		enginePrefixPaddingMs = nil
		// Not reset: a reconnect opens a brand-new session, so the engine hands out
		// fresh item ids that cannot collide with the old ones anyway, and the text
		// fallback should still catch an engine that repeats itself across the
		// reconnect boundary rather than only within one socket.
	}

	// MARK: - State

	private func setState(_ new: DictationConnectionState) {
		guard state != new else { return }
		state = new
		emit.yield(.connectionState(new))
	}

	private func fail(_ error: DictationError) {
		guard !isFinished else { return }
		if canRecover(from: error) {
			// Held, not reported. A host shown an error for a socket that is about to
			// be replaced would be shown an error for a dictation that then worked —
			// and the whole point of the reconnect is that the user keeps talking.
			// `connectLoop` promotes it to a real failure if the budget runs out.
			if lostConnection == nil { lostConnection = error }
			releaseAll()
			return
		}
		// Recorded synchronously, before the teardown is scheduled. Teardown can
		// otherwise be reached first by `finish()` resuming on the run loop's exit,
		// and a session that failed would report `closed(.finished)`.
		if failure == nil { failure = error }
		emit.yield(.failed(error))
		Task { await self.teardown(reason: .failed(error)) }
	}

	/// The first failure, if there was one. Decides the close reason.
	private var failure: DictationError?

	/// The one place the socket and the audio tap are released.
	///
	/// Both, always, and idempotently. A session that closed its socket but left an
	/// `AVAudioEngine` tap installed leaves the microphone indicator lit, which is
	/// the kind of bug a user notices before any test does.
	private func teardown(reason: DictationCloseReason) async {
		guard !isFinished else { return }
		isFinished = true

		settleTask?.cancel()
		settleTask = nil
		// Cancelled rather than left to expire: an armed timer retains the actor for
		// up to finalTranscriptTimeout after the session is over.
		handshakeTask?.cancel()
		handshakeTask = nil
		closeTimeoutTask?.cancel()
		closeTimeoutTask = nil
		runTask?.cancel()
		runTask = nil

		audio.stop()
		let transport = self.transport
		self.transport = nil
		await transport?.close()

		releaseAll()
		// A recorded failure always wins over the caller's optimistic reason.
		setState(.closed(failure.map { .failed($0) } ?? reason))
		emit.finish()
	}
}

// MARK: - The one-line case

extension DictationSession {
	/// Start a session and receive its events in a closure.
	///
	/// The protocols are still there for a host that needs them; this exists so
	/// that the common case does not have to mention them. Returns the session so
	/// the caller can `finish()` or `cancel()` it.
	@discardableResult
	public static func start(
		configuration: DictationConfiguration,
		credentials: DictationCredentialProvider = .none,
		audio: DictationAudioSource = MicrophoneSource(),
		transport: DictationTransportFactory = .urlSession,
		onEvent: @escaping @Sendable (DictationEvent) -> Void
	) async -> DictationSession {
		let session = DictationSession(
			configuration: configuration, credentials: credentials, audio: audio,
			transport: transport)
		let events = session.events
		Task {
			for await event in events { onEvent(event) }
		}
		await session.start()
		return session
	}

	/// Transcribe a finite audio source and return the text.
	///
	/// For the batch case — a file, a recording already on disk — where a host does
	/// not want a stream at all.
	public static func transcribe(
		configuration: DictationConfiguration,
		credentials: DictationCredentialProvider = .none,
		audio: DictationAudioSource,
		transport: DictationTransportFactory = .urlSession
	) async throws -> String {
		let session = DictationSession(
			configuration: configuration, credentials: credentials, audio: audio,
			transport: transport)

		let failure = Failure()
		let events = session.events
		let watcher = Task {
			for await event in events {
				if case .failed(let error) = event { await failure.record(error) }
			}
		}
		defer { watcher.cancel() }

		await session.start()
		let text = await session.finish()
		// Wait for the watcher to drain what is left of the stream before reading
		// its verdict. `finish()` has already torn the session down, which is what
		// ends the stream and bounds this wait — but the watcher consumes events on
		// its own task, and reading `failure` before that task has caught up is a
		// race: under load a `.failed` event could be recorded just after the check,
		// and transcribe returned an empty transcript instead of throwing.
		await watcher.value
		if let error = await failure.value { throw error }
		return text
	}

	/// Holds the first error seen, so `transcribe` can throw rather than return an
	/// empty string that looks like silence.
	private actor Failure {
		var value: DictationError?
		func record(_ error: DictationError) { if value == nil { value = error } }
	}
}
