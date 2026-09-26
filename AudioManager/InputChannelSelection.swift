import AVFoundation
import Foundation
import WhisperKit

/// Which channel of a multi-channel input to record. 0 mixes every channel
/// (the default); 1...n records only that channel, e.g. the one mic plugged into
/// input 2 of an audio interface.
enum InputChannelSelection {
	static let key = "selectedInputChannel"
	static let mixAllChannels = 0

	static func stored(in defaults: UserDefaults) -> Int {
		max(mixAllChannels, defaults.integer(forKey: key))
	}

	/// The WhisperKit channel mode for a selection, or nil when the buffer should be
	/// left to the normal downmix (mixing selected, mono input, or a channel the
	/// current device does not have).
	static func channelMode(selected: Int, channelCount: Int) -> AudioInputConfig.ChannelMode? {
		guard selected > mixAllChannels, channelCount > 1, selected <= channelCount else { return nil }
		return .specificChannel(selected - 1)
	}

	static func isolate(_ buffer: AVAudioPCMBuffer, selected: Int) -> AVAudioPCMBuffer {
		guard
			let mode = channelMode(selected: selected, channelCount: Int(buffer.format.channelCount)),
			let mono = AudioProcessor.convertToMono(buffer, mode: mode)
		else { return buffer }
		return mono
	}

	/// File recordings keep every channel only when one is selected, so the chosen
	/// channel can be pulled out when the file is loaded for transcription.
	static func fileRecordingChannelCount(selected: Int, deviceChannels: Int) -> Int {
		channelMode(selected: selected, channelCount: deviceChannels) == nil ? 1 : deviceChannels
	}

	/// Loads a recording as 16 kHz mono, keeping only the selected channel when the file has it.
	static func loadSamples(fromPath path: String, selected: Int) throws -> [Float] {
		let fileChannels = (try? AVAudioFile(forReading: URL(fileURLWithPath: path)))
			.map { Int($0.fileFormat.channelCount) } ?? 1
		let mode = channelMode(selected: selected, channelCount: fileChannels) ?? .sumChannels(nil)
		return try AudioProcessor.loadAudioAsFloatArray(fromPath: path, channelMode: mode)
	}

	static func settingsDescription(on route: CaptureRoute) -> String {
		switch route {
		case .live:
			return String(
				localized:
					"Live Transcription Mode records every channel mixed together; turn it off to record a single channel")
		case .stream, .file:
			return String(localized: "Record a single channel of a multi-channel interface")
		}
	}
}
