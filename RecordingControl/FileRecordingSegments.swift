import Foundation

/// The parts of one record-to-file recording. AVAudioRecorder stays on the input it opened, so
/// picking another microphone mid-recording finishes the current file and records the next part
/// on the new device; the parts are joined when the recording stops.
struct FileRecordingSegments {
	struct Segment: Equatable {
		let url: URL
		/// The channel picked for this part; each part can come from a device with a different layout.
		let channel: Int
	}

	private(set) var finished: [Segment] = []

	mutating func finish(_ segment: Segment) {
		finished.append(segment)
	}

	/// Every part in recording order, ending with the one still open; clears the list.
	mutating func takeAll(current: Segment?) -> [Segment] {
		let all = finished + (current.map { [$0] } ?? [])
		finished = []
		return all
	}

	struct NothingLoaded: LocalizedError {
		var errorDescription: String? {
			String(localized: "The recording could not be read.")
		}
	}

	/// Joins the parts as 16 kHz mono. A part that cannot be read (a switch right after it
	/// opened can leave an empty file) is skipped rather than losing the others.
	static func loadJoined(
		_ segments: [Segment],
		load: (Segment) throws -> [Float] = {
			try InputChannelSelection.loadSamples(fromPath: $0.url.path, selected: $0.channel)
		}
	) throws -> [Float] {
		var samples: [Float] = []
		var loadedAny = false
		for segment in segments {
			do {
				samples += try load(segment)
				loadedAny = true
			} catch {
				AppLogger.shared.audioManager.error("Skipping unreadable part of a recording: \(error)")
			}
		}
		guard loadedAny else { throw NothingLoaded() }
		return samples
	}

	static func removeFiles(of segments: [Segment]) {
		for segment in segments {
			try? FileManager.default.removeItem(at: segment.url)
		}
	}
}
