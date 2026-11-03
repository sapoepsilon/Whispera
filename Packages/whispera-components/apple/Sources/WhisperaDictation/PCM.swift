import Foundation

/// Format conversion for raw PCM, in plain Swift.
///
/// Deliberately not built on `AVAudioConverter`. This code runs on every frame of
/// every session, including the ones a test drives from a file with no audio
/// hardware and no run loop, so it is written so that `swift test` can measure it
/// directly rather than only observing it through a microphone.
public enum PCM {
	// MARK: - Interpretation

	/// Little-endian Int16 → normalised Float, tolerating a trailing odd byte.
	///
	/// The odd byte is real: an `AsyncStream<Data>` carries whatever chunk sizes the
	/// producer felt like, and a chunk boundary is under no obligation to land on a
	/// sample boundary. Callers that care about the remainder use
	/// `FrameAligner`; callers that do not would rather drop one byte than trap.
	public static func floats(fromPCM16 data: Data) -> [Float] {
		let sampleCount = data.count / 2
		guard sampleCount > 0 else { return [] }
		var out = [Float](repeating: 0, count: sampleCount)
		data.withUnsafeBytes { raw in
			for i in 0..<sampleCount {
				// loadUnaligned, because Data's base pointer carries no alignment
				// guarantee once it has been sliced.
				let bits = raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
				out[i] = Float(Int16(bitPattern: UInt16(littleEndian: bits))) / 32768
			}
		}
		return out
	}

	/// Normalised Float → little-endian Int16, clipped rather than wrapped.
	///
	/// Wrapping is what you get for free from a truncating conversion and it is
	/// audibly catastrophic — a sample just past full scale becomes full-scale
	/// *negative*, which is a click on every peak.
	public static func pcm16(fromFloats samples: [Float]) -> Data {
		var out = Data(capacity: samples.count * 2)
		for sample in samples {
			let clamped = min(max(sample, -1), 1)
			// 32767 rather than 32768 on the way out, so +1.0 maps to Int16.max
			// instead of overflowing it.
			let value = Int16(clamped * 32767)
			withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
		}
		return out
	}

	/// Float32 bytes → Float samples.
	public static func floats(fromFloat32 data: Data) -> [Float] {
		let sampleCount = data.count / 4
		guard sampleCount > 0 else { return [] }
		var out = [Float](repeating: 0, count: sampleCount)
		data.withUnsafeBytes { raw in
			for i in 0..<sampleCount {
				let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
				out[i] = Float(bitPattern: UInt32(littleEndian: bits))
			}
		}
		return out
	}

	/// Average the channels down to one.
	///
	/// Mixing rather than taking channel 0: on a stereo interface with a single mic
	/// wired to the right input, taking the left channel yields silence, and the
	/// resulting "the engine is broken" bug report is expensive.
	public static func downmixToMono(_ samples: [Float], channels: Int) -> [Float] {
		guard channels > 1 else { return samples }
		let frames = samples.count / channels
		var out = [Float](repeating: 0, count: frames)
		for frame in 0..<frames {
			var sum: Float = 0
			for channel in 0..<channels { sum += samples[frame * channels + channel] }
			out[frame] = sum / Float(channels)
		}
		return out
	}

	// MARK: - Level

	/// Root mean square of a buffer, in 0…1. What the meters are driven from.
	public static func rms(_ samples: [Float]) -> Float {
		guard !samples.isEmpty else { return 0 }
		var sum: Float = 0
		for sample in samples { sum += sample * sample }
		return (sum / Float(samples.count)).squareRoot()
	}
}

/// Holds back the bytes that did not complete a frame.
///
/// Public because a host that normalises its own audio needs exactly this, and
/// because getting it wrong is silent: the audio still plays, it is just noise.
///
/// A stream of `Data` chunks says nothing about where sample boundaries fall. Split
/// an Int16 across two chunks and interpret each half independently, and every
/// subsequent sample in that chunk is byte-swapped noise. This carries the
/// remainder forward, which is the whole fix.
public struct FrameAligner {
	private var carry = Data()
	private let bytesPerFrame: Int

	public init(bytesPerFrame: Int) {
		self.bytesPerFrame = max(1, bytesPerFrame)
	}

	/// Returns as many whole frames as are now available, retaining the rest.
	public mutating func take(_ chunk: Data) -> Data {
		carry.append(chunk)
		let usable = (carry.count / bytesPerFrame) * bytesPerFrame
		guard usable > 0 else { return Data() }
		let whole = carry.prefix(usable)
		carry = Data(carry.dropFirst(usable))
		return Data(whole)
	}

	/// Whatever never completed a frame, for a caller that wants to assert it is
	/// empty at end of stream.
	public var pending: Data { carry }
}

/// Sample-rate conversion.
///
/// Linear interpolation, with a box filter ahead of it when decimating. Linear
/// interpolation alone is fine going up — the engine is a speech model that
/// resamples to 16 kHz internally, and imaging above 8 kHz never reaches it. Going
/// *down* it is not fine: 48 kHz hardware carries real energy above 12 kHz, and
/// resampling to 24 kHz without a filter folds that energy back into the speech
/// band as noise the model then has to hear through.
///
/// A windowed-sinc kernel would be the textbook answer. It is not worth it here:
/// the box filter puts the alias floor well below the noise floor of any real
/// microphone, and this way the whole thing is forty lines that a test can pin.
public struct Resampler {
	public let inputRate: Int
	public let outputRate: Int

	private let decimationWidth: Int
	/// Fractional read position, carried between calls so that chunk boundaries do
	/// not each round to a sample and drift the clock.
	private var position: Double = 0
	/// The tail of the previous chunk, so interpolation can span a chunk boundary
	/// instead of restarting at zero and clicking once per chunk.
	private var history: [Float] = []
	/// The previous chunk's tail, so the anti-alias window spans chunk boundaries.
	private var filterHistory: [Float] = []

	public init(from inputRate: Int, to outputRate: Int) {
		self.inputRate = max(1, inputRate)
		self.outputRate = max(1, outputRate)
		// Width 1 is a no-op filter, which is what upsampling wants.
		self.decimationWidth = max(1, Int((Double(inputRate) / Double(outputRate)).rounded()))
	}

	public var isPassthrough: Bool { inputRate == outputRate }

	/// Resample one chunk, carrying state into the next call.
	public mutating func resample(_ input: [Float]) -> [Float] {
		guard !input.isEmpty else { return [] }
		guard !isPassthrough else { return input }

		let filtered = decimationWidth > 1 ? boxFiltered(input) : input

		// One sample of history is all linear interpolation needs to bridge the gap.
		var buffer = history
		buffer.append(contentsOf: filtered)

		let step = Double(inputRate) / Double(outputRate)
		var out: [Float] = []
		out.reserveCapacity(Int(Double(filtered.count) / step) + 2)

		// Stop at count - 1: the last sample has no successor to interpolate
		// towards yet, and it becomes the next call's history.
		while position < Double(buffer.count - 1) {
			let index = Int(position)
			let fraction = Float(position - Double(index))
			let a = buffer[index]
			let b = buffer[index + 1]
			out.append(a + (b - a) * fraction)
			position += step
		}

		// Retain the unconsumed tail and rebase the position onto it.
		let consumed = min(Int(position), buffer.count)
		history = Array(buffer[consumed...])
		position -= Double(consumed)
		return out
	}

	/// Moving average of `decimationWidth`, carrying its window across calls.
	///
	/// The carry is not bookkeeping for its own sake. Restarting the average at
	/// every chunk head means the first `width - 1` samples of every chunk are
	/// averaged over a shorter window, which passes exactly the high-frequency
	/// energy this filter exists to remove — one full-scale impulse per chunk. At a
	/// 2048-frame tap that is a periodic click at about 23 Hz, proportional to the
	/// input's HF content. Measured before the carry: alternating ±1 at 48k→8k came
	/// out as 1.0 at every chunk boundary and 0 everywhere else.
	private mutating func boxFiltered(_ input: [Float]) -> [Float] {
		let width = decimationWidth
		// Prepend the tail of the previous chunk so sample 0 has a full window.
		// Short chunks are filtered too — skipping them, as this used to, let a
		// caller with small buffers bypass anti-aliasing entirely.
		var padded = filterHistory
		padded.append(contentsOf: input)

		var out = [Float](repeating: 0, count: input.count)
		var running: Float = 0
		let offset = padded.count - input.count
		for i in 0..<padded.count {
			running += padded[i]
			if i >= width { running -= padded[i - width] }
			if i >= offset { out[i - offset] = running / Float(min(i + 1, width)) }
		}

		filterHistory = Array(padded.suffix(width - 1))
		return out
	}
}

/// Everything between "whatever the host gave us" and "what the engine eats".
///
/// Public so a host driving its own socket can reuse the conversion rather than
/// reimplement resampling and framing against the same engine.
///
/// One object so the session has a single call site and a single place where the
/// engine's format is asserted.
public struct AudioNormalizer {
	private let source: DictationAudioFormat
	private let target: DictationAudioFormat
	private var aligner: FrameAligner
	private var resampler: Resampler

	public init(from source: DictationAudioFormat, to target: DictationAudioFormat = .engine) {
		self.source = source
		self.target = target
		self.aligner = FrameAligner(bytesPerFrame: source.bytesPerFrame)
		self.resampler = Resampler(from: source.sampleRate, to: target.sampleRate)
	}

	/// Returns engine-format bytes, plus the level of the chunk so the caller does
	/// not have to decode the samples a second time to drive a meter.
	public mutating func normalize(_ chunk: Data) -> (pcm: Data, level: Float) {
		let aligned = aligner.take(chunk)
		guard !aligned.isEmpty else { return (Data(), 0) }

		let interleaved: [Float] =
			source.encoding == .pcm16
			? PCM.floats(fromPCM16: aligned)
			: PCM.floats(fromFloat32: aligned)

		let mono = PCM.downmixToMono(interleaved, channels: source.channels)
		let level = PCM.rms(mono)
		let resampled = resampler.resample(mono)
		return (PCM.pcm16(fromFloats: resampled), level)
	}
}
