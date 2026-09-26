import AVFoundation
import Foundation

/// Accumulates 16 kHz mono samples from the microphone tap. The tap runs on the
/// real-time audio thread while start, stop and device switches run on the main
/// actor, so every piece of shared state lives behind one lock.
final class StreamCaptureBuffer: @unchecked Sendable {
	static let targetSampleRate: Double = 16000

	private struct State {
		var samples: [Float] = []
		var isCapturing = false
		var channelSelection = InputChannelSelection.mixAllChannels
		var converter: AVAudioConverter?
	}

	private var state = State()
	private let lock = NSLock()
	private let maxSamples: Int
	private let targetFormat = AVAudioFormat(
		standardFormatWithSampleRate: StreamCaptureBuffer.targetSampleRate, channels: 1)

	init(maxSamples: Int = 16000 * 1800) {
		self.maxSamples = maxSamples
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

	func setCapturing(_ capturing: Bool) {
		withState { $0.isCapturing = capturing }
	}

	func setChannelSelection(_ selection: Int) {
		withState { $0.channelSelection = selection }
	}

	/// Clears the samples and starts accepting audio for a new recording.
	func beginCapture(channelSelection: Int) {
		withState {
			$0.samples.removeAll()
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
			$0.samples.removeAll()
			return captured
		}
	}

	func discard() {
		withState {
			$0.isCapturing = false
			$0.samples.removeAll()
		}
	}

	/// Appends already-converted samples; dropped when nobody is recording.
	@discardableResult
	func append(_ newSamples: [Float]) -> Bool {
		withState { state in
			guard state.isCapturing else { return false }
			state.samples.append(contentsOf: newSamples)
			if state.samples.count > maxSamples {
				state.samples.removeFirst(state.samples.count - maxSamples)
			}
			return true
		}
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
			state.converter = AVAudioConverter(from: source, to: target)
			return state.converter
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
