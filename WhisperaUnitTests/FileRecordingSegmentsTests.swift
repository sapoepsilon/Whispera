import AVFoundation
import Foundation
import Testing

@testable import Whispera

/// A record-to-file dictation that changes microphones is recorded as several files, one per
/// device, and must come back as one recording with nothing lost.
struct FileRecordingSegmentsTests {
	private func writeWAV(channels: [[Float]]) throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("segment-\(UUID().uuidString).wav")
		let format = AVAudioFormat(
			commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: AVAudioChannelCount(channels.count),
			interleaved: false)!
		let frames = AVAudioFrameCount(channels[0].count)
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
		buffer.frameLength = frames
		for (index, samples) in channels.enumerated() {
			for (frame, value) in samples.enumerated() {
				buffer.floatChannelData![index][frame] = value
			}
		}
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: channels.count,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
		]
		let file = try AVAudioFile(
			forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
		try file.write(from: buffer)
		return url
	}

	@Test func partsComeBackInOrderWithTheOpenOneLast() {
		var segments = FileRecordingSegments()
		let first = FileRecordingSegments.Segment(url: URL(fileURLWithPath: "/tmp/a.wav"), channel: 0)
		let second = FileRecordingSegments.Segment(url: URL(fileURLWithPath: "/tmp/b.wav"), channel: 2)
		let open = FileRecordingSegments.Segment(url: URL(fileURLWithPath: "/tmp/c.wav"), channel: 0)
		segments.finish(first)
		segments.finish(second)
		#expect(segments.takeAll(current: open) == [first, second, open])
		#expect(segments.finished.isEmpty)
		#expect(segments.takeAll(current: nil).isEmpty)
	}

	/// The first part came from a mono mic, the second from a two-channel interface with input 2
	/// selected: both are kept, each with its own channel choice.
	@Test func joinsPartsFromDevicesWithDifferentLayouts() throws {
		let mono = try writeWAV(channels: [Array(repeating: 0.25, count: 8000)])
		let stereo = try writeWAV(channels: [Array(repeating: 0.1, count: 4000), Array(repeating: 0.6, count: 4000)])
		defer { FileRecordingSegments.removeFiles(of: [.init(url: mono, channel: 0), .init(url: stereo, channel: 0)]) }

		let joined = try FileRecordingSegments.loadJoined([
			.init(url: mono, channel: InputChannelSelection.mixAllChannels),
			.init(url: stereo, channel: 2),
		])
		#expect(abs(joined.count - 12000) <= 32, "Audio was lost or duplicated across the switch: \(joined.count)")
		#expect(abs(joined[4000] - 0.25) < 0.01)
		#expect(abs(joined[joined.count - 2000] - 0.6) < 0.01, "The second part ignored its channel choice")
	}

	@Test func anUnreadablePartIsSkippedAndTheRestKept() throws {
		let good = try writeWAV(channels: [Array(repeating: 0.5, count: 1600)])
		let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).wav")
		FileManager.default.createFile(atPath: empty.path, contents: Data())
		defer { FileRecordingSegments.removeFiles(of: [.init(url: good, channel: 0), .init(url: empty, channel: 0)]) }

		let joined = try FileRecordingSegments.loadJoined([.init(url: empty, channel: 0), .init(url: good, channel: 0)])
		#expect(abs(joined.count - 1600) <= 16)
	}

	@Test func nothingReadableFailsInsteadOfTranscribingSilence() {
		struct Unreadable: Error {}
		let segment = FileRecordingSegments.Segment(url: URL(fileURLWithPath: "/nonexistent.wav"), channel: 0)
		#expect(throws: FileRecordingSegments.NothingLoaded.self) {
			try FileRecordingSegments.loadJoined([segment, segment]) { _ in throw Unreadable() }
		}
	}

	@Test func removeFilesDeletesEveryPart() throws {
		let a = try writeWAV(channels: [[0.1, 0.2]])
		let b = try writeWAV(channels: [[0.1, 0.2]])
		FileRecordingSegments.removeFiles(of: [.init(url: a, channel: 0), .init(url: b, channel: 0)])
		#expect(!FileManager.default.fileExists(atPath: a.path))
		#expect(!FileManager.default.fileExists(atPath: b.path))
	}
}
