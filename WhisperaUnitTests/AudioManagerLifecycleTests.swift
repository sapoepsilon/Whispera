import AVFoundation
import Foundation
import Testing

@testable import Whispera

/// Routing matrix for a device selection. Exercised through the extracted pure
/// function rather than a live AudioManager, which would drag in the shared
/// WhisperKit transcriber.
struct DeviceSwitchRouteTests {

	private static let flags = [true, false]
	private static let modes: [RecordingMode] = [.text, .liveTranscription]

	@Test func startupInFlightOutranksEveryOtherSignal() {
		for isRecording in Self.flags {
			for isInitializing in Self.flags {
				for useStreaming in Self.flags {
					for mode in Self.modes {
						#expect(
							AudioManager.deviceSwitchRoute(
								isStartingCapture: true,
								isRecording: isRecording,
								isMicrophoneInitializing: isInitializing,
								mode: mode,
								useStreaming: useStreaming
							) == .startupInFlight,
							"Switching during startup must never take a path that cancels the task bringing capture up"
						)
					}
				}
			}
		}
	}

	@Test func idleDefersActivationToTheNextRecording() {
		for useStreaming in Self.flags {
			for mode in Self.modes {
				#expect(
					AudioManager.deviceSwitchRoute(
						isStartingCapture: false,
						isRecording: false,
						isMicrophoneInitializing: false,
						mode: mode,
						useStreaming: useStreaming
					) == .nextRecording
				)
			}
		}
	}

	@Test func establishedLiveSessionRestartsTheLiveStream() {
		for useStreaming in Self.flags {
			#expect(
				AudioManager.deviceSwitchRoute(
					isStartingCapture: false,
					isRecording: true,
					isMicrophoneInitializing: false,
					mode: .liveTranscription,
					useStreaming: useStreaming
				) == .liveRestart,
				"Live capture is owned by the transcriber, so the streaming preference is irrelevant"
			)
		}
	}

	@Test func establishedStreamingTextSessionRestartsTheEngine() {
		#expect(
			AudioManager.deviceSwitchRoute(
				isStartingCapture: false,
				isRecording: true,
				isMicrophoneInitializing: false,
				mode: .text,
				useStreaming: true
			) == .engineRestart
		)
	}

	@Test func establishedFileTextSessionRestartsTheRecorder() {
		#expect(
			AudioManager.deviceSwitchRoute(
				isStartingCapture: false,
				isRecording: true,
				isMicrophoneInitializing: false,
				mode: .text,
				useStreaming: false
			) == .fileRecorderRestart,
			"AVAudioRecorder pins its device at record(), so the recorder itself has to be reopened"
		)
	}

	@Test func initializingFromAPreviousSwitchRoutesLikeAnEstablishedSession() {
		#expect(
			AudioManager.deviceSwitchRoute(
				isStartingCapture: false,
				isRecording: false,
				isMicrophoneInitializing: true,
				mode: .text,
				useStreaming: true
			) == .engineRestart
		)
		#expect(
			AudioManager.deviceSwitchRoute(
				isStartingCapture: false,
				isRecording: false,
				isMicrophoneInitializing: true,
				mode: .text,
				useStreaming: false
			) == .fileRecorderRestart
		)
		#expect(
			AudioManager.deviceSwitchRoute(
				isStartingCapture: false,
				isRecording: false,
				isMicrophoneInitializing: true,
				mode: .liveTranscription,
				useStreaming: true
			) == .liveRestart
		)
	}
}

private enum SegmentFixtureError: Error {
	case bufferAllocationFailed
	case missingChannelData
}

/// Reassembly of the segments a mid-recording device switch leaves behind.
struct RecordingSegmentLoadingTests {

	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("AudioManagerLifecycleTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	/// Writes a 16 kHz mono segment whose every sample carries `value`, so the
	/// concatenation order is readable straight off the returned array.
	private func writeSegment(at url: URL, value: Float, frames: AVAudioFrameCount) throws {
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
		]

		let file = try AVAudioFile(forWriting: url, settings: settings)
		guard
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
		else {
			throw SegmentFixtureError.bufferAllocationFailed
		}
		buffer.frameLength = frames

		guard let channelData = buffer.floatChannelData?[0] else {
			throw SegmentFixtureError.missingChannelData
		}
		for index in 0..<Int(frames) {
			channelData[index] = value
		}

		try file.write(from: buffer)
	}

	@Test func segmentsConcatenateInTheOrderGiven() throws {
		try withTemporaryDirectory { directory in
			let first = directory.appendingPathComponent("first.wav")
			let second = directory.appendingPathComponent("second.wav")
			try writeSegment(at: first, value: 0.25, frames: 100)
			try writeSegment(at: second, value: -0.5, frames: 50)

			let samples = try AudioManager.loadSamples(from: [first, second])

			#expect(samples.count == 150)
			#expect(samples[0] == 0.25)
			#expect(samples[99] == 0.25)
			#expect(samples[100] == -0.5)
			#expect(samples[149] == -0.5)
		}
	}

	@Test func noSegmentsYieldsNoSamples() throws {
		let samples = try AudioManager.loadSamples(from: [])

		#expect(samples.isEmpty)
	}

	@Test func unreadableSegmentIsSkippedRatherThanLosingTheDictation() throws {
		try withTemporaryDirectory { directory in
			let missing = directory.appendingPathComponent("never-written.wav")
			let readable = directory.appendingPathComponent("readable.wav")
			try writeSegment(at: readable, value: 0.25, frames: 80)

			let samples = try AudioManager.loadSamples(from: [missing, readable])

			#expect(
				samples.count == 80,
				"One broken segment must cost only its own audio, not the whole recording")
			#expect(samples.allSatisfy { $0 == 0.25 })
		}
	}
}
