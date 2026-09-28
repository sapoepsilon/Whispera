import AVFoundation
import Foundation
import Testing

@testable import Whispera

struct InputChannelSelectionTests {
	private func stereoBuffer(left: Float, right: Float, frames: AVAudioFrameCount = 256) throws
		-> AVAudioPCMBuffer
	{
		let format = try #require(
			AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
		let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
		buffer.frameLength = frames
		let data = try #require(buffer.floatChannelData)
		for frame in 0..<Int(frames) {
			data[0][frame] = left
			data[1][frame] = right
		}
		return buffer
	}

	@Test func mixingAveragesTheChannelsCarryingSound() throws {
		let buffer = try stereoBuffer(left: 0.5, right: -0.25)
		let mono = InputChannelSelection.isolate(buffer, selected: 0)
		#expect(mono.format.channelCount == 1)
		let samples = try #require(mono.floatChannelData)[0]
		#expect((0..<Int(mono.frameLength)).allSatisfy { samples[$0] == 0.125 })
	}

	@Test(arguments: [(1, Float(0.5)), (2, Float(-0.25))])
	func selectingAChannelKeepsOnlyThatChannel(channel: Int, expected: Float) throws {
		let buffer = try stereoBuffer(left: 0.5, right: -0.25)
		let mono = InputChannelSelection.isolate(buffer, selected: channel)

		#expect(mono.format.channelCount == 1)
		#expect(mono.frameLength == buffer.frameLength)
		let samples = try #require(mono.floatChannelData)[0]
		#expect((0..<Int(mono.frameLength)).allSatisfy { samples[$0] == expected })
	}

	@Test func channelTheDeviceDoesNotHaveFallsBackToMixing() throws {
		let buffer = try stereoBuffer(left: 0.5, right: -0.25)
		#expect(InputChannelSelection.isolate(buffer, selected: 5).format.channelCount == 1)
		#expect(InputChannelSelection.channelMode(selected: 3, channelCount: 2) == nil)
	}

	@Test func monoInputIsNeverRemapped() {
		#expect(InputChannelSelection.channelMode(selected: 1, channelCount: 1) == nil)
	}

	@Test func storedSelectionDefaultsToMixing() throws {
		let suite = "InputChannelSelectionTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(InputChannelSelection.stored(in: defaults) == InputChannelSelection.mixAllChannels)
		defaults.set(2, forKey: InputChannelSelection.key)
		#expect(InputChannelSelection.stored(in: defaults) == 2)
		defaults.set(-4, forKey: InputChannelSelection.key)
		#expect(InputChannelSelection.stored(in: defaults) == InputChannelSelection.mixAllChannels)
	}

	@Test @MainActor func defaultInputReportsItsChannels() {
		let manager = AudioDeviceManager(forTesting: true)
		let count = manager.inputChannelCount(forUID: AudioDeviceManager.systemDefaultUID)
		if !manager.availableDevices.isEmpty {
			#expect(count >= 1)
		}
	}
}
