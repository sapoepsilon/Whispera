import Foundation

#if canImport(AVFoundation)
	import AVFoundation
#endif

/// The microphone, via `AVAudioEngine`.
///
/// The tap is installed with a nil format and each buffer is normalised to the
/// engine format right in the callback. Both halves of that are load-bearing.
/// Passing any concrete format to `installTapOnBus` — even one queried from the
/// node a line earlier — reintroduces AVFoundation's format-mismatch check, which
/// raises an NSException Swift cannot catch; a default-input switch (a Continuity
/// iPhone mic joining, 2 ch 44.1 kHz) landing between the query and the install
/// took the whole app down exactly there. With nil the tap adopts whatever the bus
/// actually carries, and `buffer.format` inside the callback is the only report of
/// the hardware format that cannot be stale. Converting here rather than in the
/// session follows from that: only the callback knows the true source format, so
/// only the callback can build the right `AudioNormalizer` — which is the
/// package's own plain-Swift conversion, not an `AVAudioConverter` on the audio
/// thread. `format` is therefore constant, and a mid-session device switch never
/// changes what the session receives.
public final class MicrophoneSource: DictationAudioSource, @unchecked Sendable {
	/// How many frames per tap callback to ask for. 2048 at 48 kHz is ~43 ms —
	/// small enough that a word does not sit in a buffer waiting, large enough that
	/// the socket is not woken hundreds of times a second.
	public static let defaultBufferSize: AVAudioFrameCount = 2048

	/// How much audio `frames()` will hold for a consumer that has stopped
	/// draining.
	///
	/// Seconds, not frames, and generous — because the bound is a memory guard,
	/// not a pacing mechanism, and the two were conflated. The first version of
	/// this held about two seconds (48 tap buffers) on the reasoning that a large
	/// buffer lets a stall drain as one burst, which is what melts speaches'
	/// server VAD (WHI-70). It does — but the cure was worse than the disease:
	/// `.bufferingNewest` *discards* audio to stay inside its bound, so any stall
	/// longer than two seconds silently deleted the middle of what the user said.
	/// QA on 2026-08-23 measured it against nemo-stream: 29 of 55 words survived,
	/// with one 8.6 s hole, while a raw WebSocket probe of the same server on the
	/// same audio kept more than the app did.
	///
	/// Audio is not droppable. A word the microphone heard and the socket never
	/// carried is gone for good, and no amount of downstream cleverness gets it
	/// back — so the backlog is now *paced* on the way out
	/// (`DictationAudioPacing.delay(audioSent:elapsed:allowance:chunkDuration:)`)
	/// rather than thrown away on the way in, and this bound is set where it only
	/// bites in a genuine runaway. Thirty seconds of engine-format PCM16 is a few
	/// megabytes, which is cheap next to losing a sentence.
	public static let frameBufferSeconds: Double = 30

	/// The shortest tap callback this source can realistically be handed: the
	/// default buffer size against a 96 kHz device. Using the *shortest* is what
	/// makes `frameBufferLimit` a floor on the seconds held rather than an
	/// average — a slower device simply buffers longer than asked, which is the
	/// safe direction.
	private static let shortestFrameSeconds = Double(defaultBufferSize) / 96_000

	/// `frameBufferSeconds` as a tap-buffer count, which is the unit
	/// `AsyncStream`'s buffering policy speaks.
	public static var frameBufferLimit: Int {
		Int((frameBufferSeconds / shortestFrameSeconds).rounded(.up))
	}

	/// The buffering policy `frames()` hands to its `AsyncStream`. Exposed so the
	/// policy this source actually ships is what a test can drive, rather than a
	/// copy of it.
	///
	/// Still bounded rather than `.unbounded`: a consumer that has stopped
	/// forever must not take the process down with it. Reaching the bound is now
	/// a reportable fault instead of routine behaviour — see `droppedFrames`.
	public static var framesBufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy {
		.bufferingNewest(frameBufferLimit)
	}

	private let bufferSize: AVAudioFrameCount
	private let targetFormat: DictationAudioFormat
	private let lock = NSLock()
	private var engine: AVAudioEngine?
	private var configurationObserver: NSObjectProtocol?
	/// Retained so `stop()` can end the stream. Without it the session's audio pump
	/// would sit in `for await` forever after the tap was removed, and `finish()`
	/// would never flush.
	private var continuation: AsyncStream<Data>.Continuation?

	public enum MicrophoneError: Error, LocalizedError {
		case permissionDenied
		case noInputAvailable
		case engineFailed(String)

		public var errorDescription: String? {
			switch self {
			case .permissionDenied:
				return
					"microphone access was not granted. On macOS the grant belongs to the process "
					+ "that launched this one — for a terminal binary that is the terminal app, "
					+ "under System Settings > Privacy & Security > Microphone."
			case .noInputAvailable:
				return "no audio input device is available"
			case .engineFailed(let message):
				return "AVAudioEngine could not start: \(message)"
			}
		}
	}

	/// - Parameter format: what the tap should convert to — the format the engine
	///   on the other end asked for, via `DictationServer.audioFormat`. Defaulted
	///   to `.engine` so a host that never discovered a server keeps the 24 kHz
	///   behaviour this source always had. See WHI-71.
	public init(
		bufferSize: AVAudioFrameCount = MicrophoneSource.defaultBufferSize,
		format: DictationAudioFormat = .engine
	) {
		self.bufferSize = bufferSize
		self.targetFormat = format
	}

	/// Constant on purpose. The session builds its normaliser from `format` before
	/// it iterates `frames()`, so a format that only became true once the tap was
	/// installed arrived too late to be believed — the tap converts instead, and
	/// what leaves this source is always engine-format PCM.
	public var format: DictationAudioFormat { targetFormat }

	/// The device can be reopened, and what it captures next is whatever the user
	/// says next — so a session that loses its socket mid-dictation can pick the
	/// microphone back up rather than ending the dictation.
	public var canRestart: Bool { true }

	/// A microphone hands over audio as fast as it is spoken and no faster, so a
	/// backlog here always means something downstream stalled — exactly the case
	/// `DictationConfiguration.maxAudioAheadOfRealtime` exists to pace.
	public var isLive: Bool { true }

	/// Ask for microphone permission, returning whether it was granted.
	///
	/// Exposed rather than folded into `frames()` because a host wants to ask at a
	/// moment of its choosing — on a settings screen, not the instant the user first
	/// taps a mic button and gets an unexplained system prompt.
	/// - Parameter timeout: how long to wait for the user to answer the system
	///   prompt before giving up.
	///
	///   Bounded on purpose. `AVCaptureDevice.requestAccess` returns only when the
	///   prompt is answered, and a process that cannot raise one — a command-line
	///   binary with no bundle and therefore no `NSMicrophoneUsageDescription`, or
	///   anything running without a GUI session — waits forever rather than being
	///   denied. An unbounded call there is indistinguishable from a hang, which is
	///   the worst of the available failures because it looks like a bug in the
	///   audio pipeline instead of a missing grant.
	public static func requestPermission(timeout: Double = 30) async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized: return true
		case .denied, .restricted: return false
		case .notDetermined: break
		@unknown default: return false
		}

		// Deliberately not a task group. A group awaits every child before it
		// returns, and `requestAccess` does not observe cancellation — so
		// `cancelAll()` does not free it and the group waits for the prompt anyway,
		// which is exactly the hang the timeout was added to prevent. A one-shot
		// continuation lets whichever finishes first win and leaves the stray
		// request to complete whenever the user eventually answers.
		let outcome = FirstAnswer()
		Task {
			let granted = await AVCaptureDevice.requestAccess(for: .audio)
			await outcome.resume(with: granted)
		}
		Task {
			try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
			await outcome.resume(with: false)
		}
		return await outcome.value
	}

	/// Whichever of two racing answers arrives first.
	private actor FirstAnswer {
		private var answer: Bool?
		private var waiters: [CheckedContinuation<Bool, Never>] = []

		func resume(with value: Bool) {
			guard answer == nil else { return }
			answer = value
			let resumable = waiters
			waiters = []
			for waiter in resumable { waiter.resume(returning: value) }
		}

		var value: Bool {
			get async {
				if let answer { return answer }
				return await withCheckedContinuation { waiters.append($0) }
			}
		}
	}

	public static var permissionStatus: AVAuthorizationStatus {
		AVCaptureDevice.authorizationStatus(for: .audio)
	}

	public func frames() -> AsyncStream<Data> {
		// Any previous run is torn down *before* the new continuation is published,
		// and this ordering is the whole point. A session that reconnects — the one
		// permitted auth retry does exactly that — calls `frames()` twice, so the
		// old tap has to go. Doing it from inside `start()` instead meant `stop()`
		// picked up the continuation belonging to the stream being handed out one
		// line earlier and finished it: the tap was then installed against a dead
		// stream, `startError` stayed nil, and the session saw a recording that
		// ended immediately with no frames and no error to explain it.
		stop()

		// Bounded, not `AsyncStream`'s default `.unbounded`. See `frameBufferLimit`.
		return AsyncStream(bufferingPolicy: Self.framesBufferingPolicy) { continuation in
			lock.withLock {
				self.continuation = continuation
				// Cleared per attempt, or a failed first attempt would poison a
				// retry that actually worked.
				self.unsafeStartError = nil
				self.unsafeDroppedFrames = 0
			}
			do {
				try start(yield: yielding(into: continuation))
			} catch {
				// The session sees an empty stream that finishes immediately. The
				// error itself surfaces through `startError`, which the session
				// reports — an AsyncStream has no channel for failure.
				lock.withLock { unsafeStartError = error }
				continuation.finish()
				return
			}
			continuation.onTermination = { [weak self] _ in self?.stop() }
		}
	}

	/// Why `frames()` could not open the device — or why it died mid-run, when a
	/// device change left nothing usable behind.
	///
	/// The session reads it after the stream finishes, so a device that refused to
	/// open is reported rather than looking like a zero-length recording. Read
	/// under the lock: it is written from `frames()` and read from the session's
	/// actor, which is a data race on an `@unchecked Sendable` class otherwise.
	public var startError: Error? { lock.withLock { unsafeStartError } }
	private var unsafeStartError: Error?

	/// How many tap buffers this run had to throw away because the consumer had
	/// not drained the stream in `frameBufferSeconds`.
	///
	/// Zero is the contract, not the happy path: a non-zero value means the user
	/// said words this source captured and the socket never carried, which is
	/// unrecoverable and previously happened silently. Reset per `frames()` call,
	/// so a host can read it at the end of a dictation and say so.
	public var droppedFrames: Int { lock.withLock { unsafeDroppedFrames } }
	private var unsafeDroppedFrames = 0

	/// The yield closure the tap is handed: the same `continuation.yield`, with
	/// the discard the buffering policy performs counted rather than ignored.
	private func yielding(into continuation: AsyncStream<Data>.Continuation) -> @Sendable (Data) ->
		Void
	{
		{ [weak self] data in
			if case .dropped = continuation.yield(data) {
				self?.lock.withLock { self?.unsafeDroppedFrames += 1 }
			}
		}
	}

	/// What the hardware's report becomes for the normaliser, or nil when the report
	/// is degenerate. A default-input switch leaves a transient window where the
	/// node claims 0 Hz or 0 channels; building a normaliser from that divides by
	/// zero downstream, so the decision to refuse lives in one pure function the
	/// self-test can pin without hardware.
	package static func sourceFormat(sampleRate: Double, channelCount: Int) -> DictationAudioFormat? {
		guard sampleRate > 0, sampleRate.isFinite, channelCount > 0 else { return nil }
		return DictationAudioFormat(
			sampleRate: Int(sampleRate), channels: channelCount, encoding: .float32)
	}

	private func start(yield: @escaping @Sendable (Data) -> Void) throws {
		#if os(iOS) || os(tvOS) || os(visionOS)
			// macOS has no AVAudioSession; iOS refuses to route input without one.
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
			try session.setActive(true, options: [])
		#endif

		let engine = AVAudioEngine()
		let input = engine.inputNode
		let hardwareFormat = input.outputFormat(forBus: 0)

		// Checked before the tap, not because the tap needs this format — it does
		// not, see below — but because a node with no real device behind it raises
		// from `installTapOnBus` too, and that exception is not catchable.
		guard Self.sourceFormat(
			sampleRate: hardwareFormat.sampleRate,
			channelCount: Int(hardwareFormat.channelCount)) != nil
		else {
			throw MicrophoneError.noInputAvailable
		}

		lock.withLock { self.engine = engine }

		Self.installConvertingTap(
			on: input, bufferSize: bufferSize, target: targetFormat, yield: yield)

		// If the default input changes while the engine runs, the engine stops
		// itself and posts this. Restarting with a freshly queried format is what
		// keeps a dictation alive when a Continuity mic joins mid-sentence.
		let observer = NotificationCenter.default.addObserver(
			forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
		) { [weak self] _ in
			self?.restartAfterConfigurationChange(engine)
		}
		lock.withLock { self.configurationObserver = observer }

		engine.prepare()
		do {
			try engine.start()
		} catch {
			input.removeTap(onBus: 0)
			throw MicrophoneError.engineFailed(error.localizedDescription)
		}
	}

	/// Installs the tap with `format: nil` and converts inside the callback.
	///
	/// nil is the crash fix: any concrete format re-arms AVFoundation's mismatch
	/// check, an uncatchable NSException, and the format queried a line earlier is
	/// exactly what goes stale when the default input switches. The normaliser is
	/// built from `buffer.format` on the first callback — the one format report
	/// that is true by construction — and rebuilt if it ever changes.
	private static func installConvertingTap(
		on input: AVAudioNode,
		bufferSize: AVAudioFrameCount,
		target: DictationAudioFormat,
		yield: @escaping @Sendable (Data) -> Void
	) {
		// Boxed per tap and touched only from the tap's serial callbacks; a fresh
		// install after a configuration change gets a fresh box, so resampler state
		// from the old device never bleeds into the new one.
		final class TapConversion {
			var source: DictationAudioFormat?
			var normalizer: AudioNormalizer?
		}
		let conversion = TapConversion()

		input.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, _ in
			guard
				let source = sourceFormat(
					sampleRate: buffer.format.sampleRate,
					channelCount: Int(buffer.format.channelCount))
			else { return }

			if conversion.source != source {
				conversion.source = source
				conversion.normalizer = AudioNormalizer(from: source, to: target)
			}

			guard let data = interleavedFloat32(from: buffer) else { return }
			let (pcm, _) = conversion.normalizer!.normalize(data)
			guard !pcm.isEmpty else { return }
			yield(pcm)
		}
	}

	/// Reopens the tap against whatever device the engine now has.
	///
	/// The engine already stopped itself before posting the notification, so there
	/// is nothing to interrupt — either this brings audio back on the new device,
	/// or the failure is recorded and the stream ends so the session reports a
	/// dead microphone instead of an inexplicably silent recording.
	private func restartAfterConfigurationChange(_ changed: AVAudioEngine) {
		let (current, continuation) = lock.withLock { (self.engine, self.continuation) }
		// A notification racing `stop()` or a later `frames()` refers to an engine
		// this source no longer owns; touching it would fight the new run.
		guard current === changed, let continuation else { return }

		let input = changed.inputNode
		input.removeTap(onBus: 0)

		let fresh = input.outputFormat(forBus: 0)
		guard Self.sourceFormat(
			sampleRate: fresh.sampleRate, channelCount: Int(fresh.channelCount)) != nil
		else {
			lock.withLock {
				unsafeStartError = MicrophoneError.noInputAvailable
			}
			continuation.finish()
			return
		}

		Self.installConvertingTap(
			on: input, bufferSize: bufferSize, target: targetFormat,
			yield: yielding(into: continuation))
		changed.prepare()
		do {
			try changed.start()
		} catch {
			lock.withLock {
				unsafeStartError = MicrophoneError.engineFailed(error.localizedDescription)
			}
			continuation.finish()
		}
	}

	/// AVAudioEngine taps hand out non-interleaved float channels; the rest of this
	/// package speaks interleaved bytes. Flattening here keeps that assumption in
	/// exactly one place.
	private static func interleavedFloat32(from buffer: AVAudioPCMBuffer) -> Data? {
		guard let channels = buffer.floatChannelData else { return nil }
		let frameCount = Int(buffer.frameLength)
		let channelCount = Int(buffer.format.channelCount)
		guard frameCount > 0, channelCount > 0 else { return nil }

		var out = Data(capacity: frameCount * channelCount * 4)
		if channelCount == 1 {
			channels[0].withMemoryRebound(to: UInt8.self, capacity: frameCount * 4) { bytes in
				out.append(bytes, count: frameCount * 4)
			}
		} else {
			for frame in 0..<frameCount {
				for channel in 0..<channelCount {
					withUnsafeBytes(of: channels[channel][frame].bitPattern.littleEndian) {
						out.append(contentsOf: $0)
					}
				}
			}
		}
		return out
	}

	public func stop() {
		let (engine, continuation, observer) = lock.withLock {
			let triple = (self.engine, self.continuation, self.configurationObserver)
			self.engine = nil
			self.continuation = nil
			self.configurationObserver = nil
			return triple
		}
		// Removed before the engine is torn down, or a configuration change racing
		// this teardown would try to restart an engine that is going away.
		if let observer { NotificationCenter.default.removeObserver(observer) }
		// Ends the stream the session is iterating, which is what turns "the user
		// pressed stop" into "flush and collect the final transcript".
		continuation?.finish()

		guard let engine else { return }
		// Order matters: removing the tap before stopping means no callback can be
		// in flight against a torn-down engine.
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()

		#if os(iOS) || os(tvOS) || os(visionOS)
			try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
		#endif
	}

	deinit { stop() }
}
