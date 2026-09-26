import Foundation
import SwiftData

enum TranscriptionHistorySource: String, CaseIterable, Sendable {
	case dictation
	case liveDictation

	var displayName: String {
		switch self {
		case .dictation: return "Dictation"
		case .liveDictation: return "Live dictation"
		}
	}

	var systemImage: String {
		switch self {
		case .dictation: return "mic"
		case .liveDictation: return "waveform"
		}
	}
}

@Model
final class TranscriptionHistoryEntry {
	@Attribute(.unique) var id: UUID
	var createdAt: Date
	var text: String
	var audioFileName: String?
	var durationSeconds: Double
	var modelName: String?
	var language: String?
	var sourceRaw: String
	var isStarred: Bool
	var errorMessage: String?
	var retranscribedAt: Date?

	init(
		id: UUID = UUID(),
		createdAt: Date,
		text: String,
		audioFileName: String?,
		durationSeconds: Double,
		modelName: String?,
		language: String?,
		source: TranscriptionHistorySource,
		isStarred: Bool = false,
		errorMessage: String? = nil
	) {
		self.id = id
		self.createdAt = createdAt
		self.text = text
		self.audioFileName = audioFileName
		self.durationSeconds = durationSeconds
		self.modelName = modelName
		self.language = language
		self.sourceRaw = source.rawValue
		self.isStarred = isStarred
		self.errorMessage = errorMessage
	}

	var source: TranscriptionHistorySource {
		TranscriptionHistorySource(rawValue: sourceRaw) ?? .dictation
	}

	var didFail: Bool {
		errorMessage != nil
	}
}
