import AVFoundation
import Foundation

/// Accumulates 16 kHz mono samples from the microphone tap. The tap runs on the
/// real-time audio thread while start, stop and device switches run on the main
/// actor, so every piece of shared state lives behind one lock.
final class StreamCaptureBuffer: @unchecked Sendable {
	static let targetSampleRate: Double = 16000
	static let maxMinutes = 30

	private struct State {
		var samples: [Float] = []
		let capacity: Int
		var reachedLimit = false
		var isCapturing = false
		var channelSelection = InputChannelSelection.mixAllChannels
		var converter: AVAudioConverter?
		var onLimitReached: (@Sendable () -> Void)?
	}

	private var state: State
	private let lock = NSLock()
	private let targetFormat = AVAudioFormat(
		standardFormatWithSampleRate: StreamCaptureBuffer.targetSampleRate, channels: 1)

	/// Called once per recording, from the audio thread, when the cap is hit. The beginning of the
	/// recording is kept and later audio is dropped, so the owner should stop the recording.
	var onLimitReached: (@Sendable () -> Void)? {
		get { withState { $0.onLimitReached } }
		set { withState { $0.onLimitReached = newValue } }
	}

	init(maxSamples: Int = 16000 * 60 * StreamCaptureBuffer.maxMinutes) {
		state = State(capacity: max(0, maxSamples))
	}

	private func withState<R>(_ body: (inout State) -> R) -> R {
		lock.lock()
		defer { lock.unlock() }
		return body(&state)
	}

	var isCapturing: Bool {
		withState { $0.isCapturing }
	}

	var count: Int {
		withState { $0.samples.count }
	}

	var reachedLimit: Bool {
		withState { $0.reachedLimit }
	}

	func setCapturing(_ capturing: Bool) {
		withState { $0.isCapturing = capturing }
	}

	func setChannelSelection(_ selection: Int) {
		withState { $0.channelSelection = selection }
	}

	/// Clears the samples and starts accepting audio for a new recording.
	func beginCapture(channelSelection: Int) {
		withState {
			$0.samples.removeAll(keepingCapacity: true)
			$0.reachedLimit = false
			$0.channelSelection = channelSelection
			$0.isCapturing = true
		}
	}

	/// Stops accepting audio and hands back everything captured, atomically, so no
	/// buffer can land between the copy and the clear.
	func finishCapture() -> [Float] {
		withState {
			$0.isCapturing = false
			let captured = $0.samples
			$0.samples = []
			$0.reachedLimit = false
			return captured
		}
	}

	func discard() {
		withState {
			$0.isCapturing = false
			$0.samples = []
			$0.reachedLimit = false
		}
	}

	/// Appends already-converted samples; dropped when nobody is recording.
	@discardableResult
	func append(_ newSamples: [Float]) -> Bool {
		let (kept, limitCallback): (Bool, (@Sendable () -> Void)?) = withState { state in
			guard state.isCapturing else { return (false, nil) }
			let room = state.capacity - state.samples.count
			if newSamples.count <= room {
				state.samples.append(contentsOf: newSamples)
				return (true, nil)
			}
			state.samples.append(contentsOf: newSamples.prefix(max(0, room)))
			guard !state.reachedLimit else { return (room > 0, nil) }
			state.reachedLimit = true
			return (room > 0, state.onLimitReached)
		}
		// Outside the lock: the owner may call back into the buffer to stop
		limitCallback?()
		return kept
	}

	/// Called from the tap. Returns the converted samples when they were kept, for level metering.
	func ingest(_ inputBuffer: AVAudioPCMBuffer, format inputFormat: AVAudioFormat) -> [Float]? {
		guard let targetFormat else { return nil }
		let (capturing, selection) = withState { ($0.isCapturing, $0.channelSelection) }
		// The stream can stay open between recordings; drop audio nobody asked for.
		guard capturing else { return nil }

		let buffer = InputChannelSelection.isolate(inputBuffer, selected: selection)
		let sourceFormat = buffer === inputBuffer ? inputFormat : buffer.format
		let samples: [Float]?
		if sourceFormat == targetFormat {
			samples = Self.floats(from: buffer)
		} else {
			samples = convert(buffer, from: sourceFormat, to: targetFormat)
		}
		guard let samples, !samples.isEmpty, append(samples) else { return nil }
		return samples
	}

	private func convert(_ buffer: AVAudioPCMBuffer, from source: AVAudioFormat, to target: AVAudioFormat)
		-> [Float]?
	{
		// The converter keeps resampler state between buffers, so it is reused while the format holds
		let converter: AVAudioConverter? = withState { state in
			if let existing = state.converter, existing.inputFormat == source {
				return existing
			}
			let converter = AVAudioConverter(from: source, to: target)
			// Without downmix the converter keeps only the first channel, so "All channels"
			// dropped speech that reached a stereo input on its second channel only
			converter?.downmix = true
			state.converter = converter
			return converter
		}
		guard let converter else { return nil }

		let ratio = target.sampleRate / source.sampleRate
		let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
		guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

		var delivered = false
		var error: NSError?
		let status = converter.convert(to: output, error: &error) { _, outStatus in
			if delivered {
				outStatus.pointee = .noDataNow
				return nil
			}
			delivered = true
			outStatus.pointee = .haveData
			return buffer
		}
		guard status != .error, error == nil else { return nil }
		return Self.floats(from: output)
	}

	private static func floats(from buffer: AVAudioPCMBuffer) -> [Float]? {
		guard let channelData = buffer.floatChannelData?[0] else { return nil }
		return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
	}
}
