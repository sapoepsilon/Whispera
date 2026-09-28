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
	/// `text` is what reached the user. When post-processing was requested these keep the
	/// speech model's own output and the LLM pass separately, so either can be copied or redone.
	var rawText: String?
	var postProcessedText: String?
	var postProcessPromptName: String?
	var postProcessPrompt: String?
	var postProcessError: String?
	var postProcessRequested: Bool = false

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

	/// The speech model's output, before any post-processing.
	var transcriptText: String {
		rawText ?? text
	}

	var wasPostProcessed: Bool {
		postProcessedText != nil
	}

	/// Replaces the text and post-processing fields from one transcription outcome.
	func apply(transcript: String, postProcessing: HistoryPostProcessing?) {
		let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let postProcessing else {
			text = raw
			rawText = nil
			postProcessedText = nil
			postProcessPromptName = nil
			postProcessPrompt = nil
			postProcessError = nil
			postProcessRequested = false
			return
		}
		let processed = postProcessing.processedText?.trimmingCharacters(in: .whitespacesAndNewlines)
		text = processed ?? raw
		rawText = raw
		postProcessedText = processed
		postProcessPromptName = postProcessing.promptName
		postProcessPrompt = postProcessing.promptTemplate
		postProcessError = postProcessing.errorMessage
		postProcessRequested = true
	}
}

/// The post-processing half of a dictation as history stores it.
struct HistoryPostProcessing: Equatable, Sendable {
	var processedText: String?
	var promptName: String
	var promptTemplate: String
	var errorMessage: String?

	init(processedText: String?, promptName: String, promptTemplate: String, errorMessage: String? = nil) {
		self.processedText = processedText
		self.promptName = promptName
		self.promptTemplate = promptTemplate
		self.errorMessage = errorMessage
	}

	init(_ run: PostProcessingRun) {
		switch run.outcome {
		case .processed(let text):
			self.init(processedText: text, promptName: run.prompt.name, promptTemplate: run.prompt.template)
		case .skipped:
			self.init(processedText: nil, promptName: run.prompt.name, promptTemplate: run.prompt.template)
		case .failed(_, let error):
			self.init(
				processedText: nil, promptName: run.prompt.name, promptTemplate: run.prompt.template,
				errorMessage: error)
		}
	}
}
