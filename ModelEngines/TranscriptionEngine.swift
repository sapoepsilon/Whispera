import Foundation

struct EngineTranscript {
	let text: String
	let segments: [TranscriptionSegment]
}

/// A speech-to-text backend other than the built-in WhisperKit path.
@MainActor
protocol TranscriptionEngine: AnyObject {
	var modelID: String { get }
	func transcribe(samples: [Float]) async throws -> EngineTranscript
	func transcribe(fileURL: URL) async throws -> EngineTranscript
	func unload()
}

enum ParakeetModel: String, CaseIterable, Identifiable, Sendable {
	case v3 = "parakeet-tdt-0.6b-v3"
	case v2 = "parakeet-tdt-0.6b-v2"

	var id: String { rawValue }

	static func isParakeetID(_ id: String) -> Bool {
		ParakeetModel(rawValue: id) != nil
	}

	var displayName: String {
		switch self {
		case .v3: return "Parakeet TDT v3 (25 languages, auto-detect) - 460MB"
		case .v2: return "Parakeet TDT v2 (English) - 460MB"
		}
	}

	var languageSummary: String {
		switch self {
		case .v3:
			return
				"Detects the spoken language automatically across 25 European languages; the Source Language setting is ignored."
		case .v2:
			return "English only; the Source Language setting is ignored."
		}
	}
}

struct TimedToken: Equatable, Sendable {
	let text: String
	let start: Double
	let end: Double
}

enum TranscriptSegmenter {
	/// Tokens are SentencePiece pieces where a leading space marks the start of a new word.
	static func segments(
		from tokens: [TimedToken],
		pauseThreshold: Double = 0.8,
		maxSegmentDuration: Double = 12
	) -> [TranscriptionSegment] {
		var segments: [TranscriptionSegment] = []
		var text = ""
		var start: Double?
		var end: Double = 0

		func flush() {
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if let segmentStart = start, !trimmed.isEmpty {
				segments.append(TranscriptionSegment(text: trimmed, startTime: segmentStart, endTime: end))
			}
			text = ""
			start = nil
		}

		for token in tokens {
			let startsWord = token.text.hasPrefix(" ")
			if let segmentStart = start, startsWord {
				let lastChar = text.trimmingCharacters(in: .whitespaces).last
				let endsSentence = lastChar.map { ".?!".contains($0) } ?? false
				let paused = token.start - end >= pauseThreshold
				let tooLong = token.start - segmentStart >= maxSegmentDuration
				if endsSentence || paused || tooLong {
					flush()
				}
			}
			if start == nil { start = token.start }
			text += token.text
			end = max(end, token.end)
		}
		flush()
		return segments
	}
}
