import AVFoundation
import Accelerate
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
		guard let mode = channelMode(selected: selected, channelCount: Int(buffer.format.channelCount)) else {
			return mixActiveChannels(buffer) ?? buffer
		}
		return AudioProcessor.convertToMono(buffer, mode: mode) ?? buffer
	}

	/// A channel counts as carrying sound when it is at least this loud relative to the loudest.
	static let activeChannelLevel: Float = 0.25

	/// "All channels" as mono without lowering the level: the channels carrying sound are averaged
	/// and the quiet ones left out. A plain downmix averages every channel, so a mic on one input
	/// of a 2-channel interface came through at half its level (an eighth on 8 channels), and
	/// Skip Silence's fixed energy floor then dropped quiet speakers. Returns nil for mono or
	/// interleaved input, which the converter's downmix handles.
	static func mixActiveChannels(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
		let channels = Int(buffer.format.channelCount)
		let frames = Int(buffer.frameLength)
		guard channels > 1, !buffer.format.isInterleaved, let data = buffer.floatChannelData,
			let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
			let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
			let output = mono.floatChannelData?[0]
		else { return nil }
		mono.frameLength = AVAudioFrameCount(frames)
		guard frames > 0 else { return mono }

		let levels = (0..<channels).map { channel -> Float in
			var rms: Float = 0
			vDSP_rmsqv(data[channel], 1, &rms, vDSP_Length(frames))
			return rms
		}
		let loudest = levels.max() ?? 0
		let active = loudest > 0 ? (0..<channels).filter { levels[$0] >= loudest * activeChannelLevel } : [0]
		vDSP_vclr(output, 1, vDSP_Length(frames))
		for channel in active {
			vDSP_vadd(output, 1, data[channel], 1, output, 1, vDSP_Length(frames))
		}
		var scale = 1 / Float(active.count)
		vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frames))
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
