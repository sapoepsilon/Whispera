import Foundation

/// Where the audio comes from.
///
/// A protocol rather than a concrete capture class because two different hosts
/// want two different things from this package. One wants a microphone and does
/// not care how. The other already runs an `AVAudioEngine` for its own waveform,
/// its own noise suppression, or its own push-to-talk gate, and wants to hand
/// those buffers straight over rather than have this package open a second tap on
/// the same device. And a test wants neither.
public protocol DictationAudioSource: Sendable {
	/// PCM chunks, in `format`, until the source is done.
	///
	/// Finishing the stream means "the audio has ended" — the session takes that as
	/// the cue to flush and collect the final transcript.
	func frames() -> AsyncStream<Data>

	/// What `frames()` produces. Defaulted to the engine format, so a host that
	/// already hands over 24 kHz mono PCM16 need not mention it, and any other host
	/// declares its format once and the package converts.
	var format: DictationAudioFormat { get }

	/// Called when the session tears down. The default does nothing; sources
	/// holding hardware override it.
	func stop()

	/// Whether `frames()` may be called a second time and still produce the audio
	/// that has not been spoken yet.
	///
	/// This is what bounds reconnection. A microphone can be reopened and carries
	/// on capturing whatever the user says next. A file replays from the top and a
	/// drained push source hands back nothing at all, so a session that reconnected
	/// on one of those would either duplicate the recording or "succeed" while
	/// sending silence — both worse than reporting the failure. Defaulted to
	/// `false`, so a host writing its own source opts in deliberately.
	var canRestart: Bool { get }

	/// Whether this source produces audio in real time, as it is spoken.
	///
	/// What it gates is pacing. A live source cannot outrun the clock on its own,
	/// so a backlog is always the symptom of something having stalled — and
	/// draining that backlog at socket speed is what melts a server-side VAD (see
	/// `DictationConfiguration.maxAudioAheadOfRealtime`). A file is the opposite
	/// case: going faster than real time is the entire point of uploading one, and
	/// pacing it would be a bug. Defaulted to `false` so a host writing its own
	/// source opts in deliberately, the same way `canRestart` does.
	var isLive: Bool { get }
}

/// How long an outbound sender should wait so it does not run ahead of the clock.
///
/// Pulled out as a pure function of three numbers, with no clock and no socket in
/// it, because it is the part worth pinning with a test: the failure it prevents —
/// a stalled sender dumping its whole backlog into the engine at once — only shows
/// up against a live server otherwise. See WHI-70.
public enum DictationAudioPacing {
	/// - Parameters:
	///   - audioSent: seconds of audio handed to the socket so far.
	///   - elapsed: seconds of wall clock since the first frame.
	///   - allowance: how far ahead of the clock the sender may run before waiting.
	/// - Returns: seconds to wait before sending the next frame. Zero whenever the
	///   sender is at or behind real time, which is every frame of an unstalled
	///   dictation — the pacing costs nothing until there is a backlog.
	public static func delay(audioSent: Double, elapsed: Double, allowance: Double) -> Double {
		max(0, audioSent - elapsed - max(0, allowance))
	}

	/// How far behind the clock the sender may fall before its frames are spaced
	/// out rather than sent back to back.
	///
	/// Generous enough that an ordinary dictation never reaches it: with
	/// `elapsed` measured from the *first frame*, a sender that is keeping up
	/// sits within one chunk of the clock, so nothing here fires until audio has
	/// genuinely queued up behind a stall.
	public static let backlogThreshold: Double = 0.5

	/// How much faster than real time a backlog is drained.
	///
	/// Four, not unbounded. Unbounded is what WHI-70 measured melting speaches'
	/// server VAD — 18 duplicate `speech_stopped` frames, 17 `already exists`
	/// errors, an empty transcript. Four clears a ten-second backlog in a few
	/// seconds while the frames still arrive spread out, which the VAD tolerates.
	public static let catchUpRate: Double = 4

	/// The same pacing, plus the catch-up half of it.
	///
	/// The three-argument form above only ever *holds back* a sender that is
	/// ahead; a sender that is behind it lets through at socket speed, which is
	/// the WHI-70 burst by another route. That was survivable only because the
	/// microphone threw the backlog away before it could form. It no longer does
	/// (audio is never discarded mid-utterance — QA 2026-08-23 lost 26 of 55
	/// words and an 8.6 s hole to exactly that), so the drain has to be paced
	/// here instead: a real backlog goes out at `catchUpRate` times real time,
	/// which is fast enough to catch up and slow enough not to be a burst.
	///
	/// - Parameter chunkDuration: seconds of audio in one outbound frame. The
	///   catch-up cadence is a fraction of it, so the spacing scales with the
	///   frame size rather than being a magic constant.
	public static func delay(
		audioSent: Double,
		elapsed: Double,
		allowance: Double,
		chunkDuration: Double,
		backlogThreshold: Double = backlogThreshold,
		catchUpRate: Double = catchUpRate
	) -> Double {
		let ahead = delay(audioSent: audioSent, elapsed: elapsed, allowance: allowance)
		if ahead > 0 { return ahead }
		let behind = elapsed - audioSent
		guard behind > max(0, backlogThreshold), chunkDuration > 0, catchUpRate > 0 else { return 0 }
		return chunkDuration / catchUpRate
	}
}

extension DictationAudioSource {
	public var format: DictationAudioFormat { .engine }
	public func stop() {}
	public var canRestart: Bool { false }
	public var isLive: Bool { false }
}

/// Audio from a WAV file on disk.
///
/// The point of shipping this is not file transcription — it is that the whole
/// pipeline, resampling included, can be driven end to end with no microphone,
/// no TCC prompt, and a known-correct expected transcript. That is what made the
/// development loop on this machine possible at all.
public struct AudioFileSource: DictationAudioSource {
	public let format: DictationAudioFormat
	private let pcm: Data
	private let chunkBytes: Int
	private let pacing: Pacing

	/// How fast to hand the file over.
	public enum Pacing: Sendable, Equatable {
		/// As fast as the socket accepts it. Correct for a file, and what the
		/// backend's own e2e test does.
		case immediate
		/// At the rate the audio would actually play, for demonstrating what live
		/// streaming looks and feels like.
		case realtime
	}

	public init(url: URL, chunkDuration: Double = 0.05, pacing: Pacing = .immediate) throws {
		let wav = try WAVFile(contentsOf: url)
		self.format = wav.format
		self.pcm = wav.pcm
		self.pacing = pacing
		// Rounded to a whole frame: handing over a chunk that ends mid-sample works
		// (FrameAligner carries the remainder) but there is no reason to make it.
		let frames = max(1, Int(Double(wav.format.sampleRate) * chunkDuration))
		self.chunkBytes = frames * wav.format.bytesPerFrame
	}

	public func frames() -> AsyncStream<Data> {
		let pcm = self.pcm
		let chunkBytes = self.chunkBytes
		let pacing = self.pacing
		let secondsPerChunk = Double(chunkBytes / format.bytesPerFrame) / Double(format.sampleRate)

		return AsyncStream { continuation in
			let task = Task {
				var offset = 0
				while offset < pcm.count {
					if Task.isCancelled { break }
					let end = min(offset + chunkBytes, pcm.count)
					continuation.yield(pcm.subdata(in: offset..<end))
					offset = end
					if pacing == .realtime {
						try? await Task.sleep(nanoseconds: UInt64(secondsPerChunk * 1_000_000_000))
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

/// A source a host drives by hand.
///
/// For the case the protocol exists for: a host that already has audio and wants
/// to push it in. Also what the tests use to feed a session synthetic frames.
public final class PushAudioSource: DictationAudioSource, @unchecked Sendable {
	public let format: DictationAudioFormat

	private let lock = NSLock()
	private var continuation: AsyncStream<Data>.Continuation?
	private var finished = false
	/// Audio pushed before anything subscribed.
	///
	/// Buffered rather than dropped. A host that starts capturing and then hands
	/// the source to a session has a real window in which nobody is listening yet,
	/// and silently discarding those frames costs the first word of the first
	/// sentence — the one failure a user is guaranteed to notice.
	private var pending: [Data] = []

	public init(format: DictationAudioFormat = .engine) {
		self.format = format
	}

	public func frames() -> AsyncStream<Data> {
		AsyncStream { continuation in
			let (buffered, wasFinished) = lock.withLock {
				let buffered = pending
				pending = []
				if !finished { self.continuation = continuation }
				return (buffered, finished)
			}
			for chunk in buffered { continuation.yield(chunk) }
			// A source that was already finished must not hand out a stream that
			// never completes — but it still owes the buffered audio first.
			if wasFinished { continuation.finish() }
		}
	}

	public func push(_ data: Data) {
		let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
			guard let continuation = self.continuation else {
				if !finished { pending.append(data) }
				return nil
			}
			return continuation
		}
		continuation?.yield(data)
	}

	/// Signals end of audio, which is what makes the session flush.
	public func finish() {
		let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
			finished = true
			let continuation = self.continuation
			self.continuation = nil
			return continuation
		}
		continuation?.finish()
	}

	public func stop() { finish() }
}
