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
	/// The app the dictation went to and the style Clean up formatted it with, when known.
	var appBundleID: String?
	var appName: String?
	var appCategory: String?
	var appStyle: String?

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
			appCategory = nil
			appStyle = nil
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
		if let bundleID = postProcessing.appBundleID {
			appBundleID = bundleID
			appName = postProcessing.appName
		}
		appCategory = postProcessing.style?.category.rawValue
		appStyle = postProcessing.style?.style.rawValue
	}

	/// The app the original dictation went to, for "Clean Up Again".
	var appContext: DictationAppContext? {
		appBundleID.map { DictationAppContext(bundleID: $0, appName: appName, platform: .mac) }
	}

	/// "Formatted for Messages (casual)", when a style was applied.
	var styleSummary: String? {
		guard let style = appStyle.flatMap(DictationStyle.init(rawValue:)), style != .verbatim else { return nil }
		let target = appName ?? appCategory.flatMap(AppCategory.init(rawValue:))?.displayName ?? ""
		return String(localized: "Formatted for \(target) (\(style.displayName.lowercased()))")
	}
}

/// The post-processing half of a dictation as history stores it.
struct HistoryPostProcessing: Equatable, Sendable {
	var processedText: String?
	var promptName: String
	var promptTemplate: String
	var errorMessage: String?
	var appBundleID: String?
	var appName: String?
	var style: AppStyleApplication?

	init(
		processedText: String?, promptName: String, promptTemplate: String, errorMessage: String? = nil,
		appBundleID: String? = nil, appName: String? = nil, style: AppStyleApplication? = nil
	) {
		self.processedText = processedText
		self.promptName = promptName
		self.promptTemplate = promptTemplate
		self.errorMessage = errorMessage
		self.appBundleID = appBundleID
		self.appName = appName
		self.style = style
	}

	/// `outcome` is nil when nothing was sent (an empty transcript, a cancelled run).
	init(
		recipe: Recipe, outcome: RecipeRunOutcome?, context: DictationAppContext? = nil,
		style: AppStyleApplication? = nil
	) {
		let template = recipe.steps.first?.config.prompt ?? ""
		var error: String?
		var processed: String?
		switch outcome {
		case .processed(let text): processed = text
		case .failed(let reason): error = reason
		case nil: break
		}
		self.init(
			processedText: processed, promptName: recipe.name, promptTemplate: template, errorMessage: error,
			appBundleID: context?.bundleID, appName: context?.appName, style: style)
	}
}
