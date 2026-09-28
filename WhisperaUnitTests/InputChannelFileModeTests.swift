import AVFoundation
import Foundation
import Testing

@testable import Whispera

struct InputChannelFileModeTests {
	/// A 16 kHz file whose first channel is silent and whose second carries a 440 Hz tone,
	/// like a one-mic interface with the mic plugged into input 2.
	private func makeTwoChannelRecording() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("InputChannelFileModeTests-\(UUID().uuidString).wav")
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: 2,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
		]
		let file = try AVAudioFile(
			forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
		let frames: AVAudioFrameCount = 16000
		let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
		buffer.frameLength = frames
		let channels = try #require(buffer.floatChannelData)
		for frame in 0..<Int(frames) {
			channels[0][frame] = 0
			channels[1][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 16000)
		}
		try file.write(from: buffer)
		return url
	}

	private func rms(_ samples: [Float]) -> Float {
		guard !samples.isEmpty else { return 0 }
		return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
	}

	@Test func selectedChannelIsPulledOutOfAFileRecording() throws {
		let url = try makeTwoChannelRecording()
		defer { try? FileManager.default.removeItem(at: url) }

		let second = try InputChannelSelection.loadSamples(fromPath: url.path, selected: 2)
		let first = try InputChannelSelection.loadSamples(fromPath: url.path, selected: 1)

		#expect(second.count > 15000)
		#expect(rms(second) > 0.2)
		#expect(rms(first) < 0.01)
	}

	@Test func mixingKeepsTheSignalFromEveryChannel() throws {
		let url = try makeTwoChannelRecording()
		defer { try? FileManager.default.removeItem(at: url) }

		let mixed = try InputChannelSelection.loadSamples(
			fromPath: url.path, selected: InputChannelSelection.mixAllChannels)
		#expect(rms(mixed) > 0.1)
	}

	@Test func aChannelTheFileDoesNotHaveFallsBackToTheMix() throws {
		let url = try makeTwoChannelRecording()
		defer { try? FileManager.default.removeItem(at: url) }

		let samples = try InputChannelSelection.loadSamples(fromPath: url.path, selected: 5)
		#expect(rms(samples) > 0.1)
	}

	@Test func fileRecordingsOnlyKeepExtraChannelsWhenOneIsSelected() {
		#expect(InputChannelSelection.fileRecordingChannelCount(selected: 0, deviceChannels: 4) == 1)
		#expect(InputChannelSelection.fileRecordingChannelCount(selected: 2, deviceChannels: 4) == 4)
		// The clamshell mic has fewer channels than the saved interface: record mono
		#expect(InputChannelSelection.fileRecordingChannelCount(selected: 3, deviceChannels: 2) == 1)
		#expect(InputChannelSelection.fileRecordingChannelCount(selected: 1, deviceChannels: 1) == 1)
	}

	@Test func descriptionMatchesWhatEachRouteDoes() {
		let live = InputChannelSelection.settingsDescription(on: .live)
		#expect(live.contains("Live Transcription Mode"))
		#expect(InputChannelSelection.settingsDescription(on: .file) == InputChannelSelection.settingsDescription(on: .stream))
		#expect(InputChannelSelection.settingsDescription(on: .file) != live)
	}
}
