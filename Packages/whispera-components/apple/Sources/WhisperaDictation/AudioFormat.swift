import Foundation

/// The shape of the PCM a `DictationAudioSource` hands over.
///
/// Sources declare what they produce; the session converts. That is what lets the
/// brief's promise hold — a host should not have to know the engine runs at
/// 24 kHz, and a host that already captures 48 kHz float audio for its own meters
/// should be able to hand those buffers over unchanged.
public struct DictationAudioFormat: Sendable, Equatable {
	public enum Encoding: Sendable, Equatable {
		/// Signed 16-bit, little-endian, interleaved. What the engine wants.
		case pcm16
		/// 32-bit float in -1…1, interleaved. What AVAudioEngine taps hand out.
		case float32
	}

	public var sampleRate: Int
	public var channels: Int
	public var encoding: Encoding

	public init(sampleRate: Int, channels: Int = 1, encoding: Encoding = .pcm16) {
		self.sampleRate = sampleRate
		self.channels = channels
		self.encoding = encoding
	}

	/// What the transcription engine consumes: 24 kHz mono PCM16 little-endian.
	///
	/// The number is here and nowhere else. It comes from `REALTIME_AUDIO_FORMAT`
	/// in the backend's registry and from `ENGINE_SAMPLE_RATE` in its realtime e2e
	/// test — 16 kHz is *not* rejected by speaches, it is silently time-compressed,
	/// which is a far worse failure than an error because the transcript still
	/// looks plausible.
	public static let engine = DictationAudioFormat(
		sampleRate: 24_000, channels: 1, encoding: .pcm16)

	/// Bytes per frame (one sample across all channels).
	public var bytesPerFrame: Int {
		channels * (encoding == .pcm16 ? 2 : 4)
	}

	/// How many bytes `seconds` of this format occupies.
	public func byteCount(forSeconds seconds: Double) -> Int {
		let frames = Int((Double(sampleRate) * seconds).rounded())
		return frames * bytesPerFrame
	}
}
