import CoreML
import Foundation
import WhisperKit

/// Applies Whisper's timestamp rules (paired, non-decreasing timestamps) to decodes that carry a
/// custom-word prompt on a multilingual model.
///
/// WhisperKit's own TimestampRulesFilter looks for the task token only among the first three
/// tokens of a multilingual decode. A prompt puts `<|startofprev|>` and the prompt words in front
/// of `<|startoftranscript|>`, so the task token sits further in, the built-in filter returns
/// early on every step. Segments then come back merged or cut in the wrong place (the first two
/// sentences of the QA passage as one 0-9 s segment), which is what the live confirmer trusts
/// when it moves its decode start. This filter finds the task token wherever the prompt puts it
/// and leaves every other decode to the built-in filter, which already handles it.
final class PromptTimestampRulesFilter: LogitsFiltering, @unchecked Sendable {
	private let specialTokens: () -> SpecialTokens?

	/// The special tokens come from the tokenizer, which a prewarmed model only loads inside the
	/// first transcribe call, after the filter is installed.
	init(specialTokens: @escaping () -> SpecialTokens?) {
		self.specialTokens = specialTokens
	}

	func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
		guard let special = specialTokens(), let begin = Self.sampleBegin(in: tokens, specialTokens: special)
		else { return logits }
		// isModelMultilingual false makes the WhisperKit filter trust sampleBegin as given
		return TimestampRulesFilter(
			specialTokens: special, sampleBegin: begin, maxInitialTimestampIndex: nil, isModelMultilingual: false
		).filterLogits(logits, withTokens: tokens)
	}

	/// Where the sampled tokens start in a prompted multilingual decode with timestamps, or nil
	/// when the built-in filter is already right (no prompt, an English-only model) or not in
	/// use (no timestamps).
	static func sampleBegin(in tokens: [Int], specialTokens: SpecialTokens) -> Int? {
		guard tokens.first == specialTokens.startOfPreviousToken,
			let transcriptStart = tokens.firstIndex(of: specialTokens.startOfTranscriptToken)
		else { return nil }
		// <|startoftranscript|> <|language|> <|task|> <|0.00|>, where WhisperKit may swap the
		// forced <|0.00|> for the initial timestamp the model predicted
		let taskIndex = transcriptStart + 2
		let timestampIndex = taskIndex + 1
		guard timestampIndex < tokens.count,
			tokens[taskIndex] == specialTokens.transcribeToken || tokens[taskIndex] == specialTokens.translateToken,
			tokens[timestampIndex] >= specialTokens.timeTokenBegin
		else { return nil }
		return timestampIndex + 1
	}
}

extension WhisperKitTranscriber {
	/// Every WhisperKit instance the app decodes with goes through here, so prompted decodes keep
	/// their timestamps in live mode, timestamped file transcription and the CLI alike.
	nonisolated static func makeWhisperKit(_ config: WhisperKitConfig) async throws -> WhisperKit {
		let whisperKit = try await WhisperKit(config)
		installPromptTimestampRules(on: whisperKit)
		return whisperKit
	}

	nonisolated static func installPromptTimestampRules(on whisperKit: WhisperKit) {
		var filters = whisperKit.textDecoder.logitsFilters ?? []
		guard !filters.contains(where: { $0 is PromptTimestampRulesFilter }) else { return }
		filters.append(PromptTimestampRulesFilter { [weak whisperKit] in whisperKit?.tokenizer?.specialTokens })
		whisperKit.textDecoder.logitsFilters = filters
	}

	/// WhisperKit's word alignment reads the attention rows of a decode from its first position,
	/// but it only keeps the tokens from <|startoftranscript|> on, so with a prompt every word is
	/// timed against the prompt's rows instead of its own. Word timings then replace the segment
	/// times: the first sentence of the QA passage ended at 1.84 s instead of 4.36 s and a
	/// segment landed at 54 s of a 28 s clip. Nothing here reads word timings, so a prompted
	/// decode takes its segment times from the timestamp tokens alone.
	nonisolated static func promptSafeDecodingOptions(_ options: DecodingOptions) -> DecodingOptions {
		guard options.promptTokens != nil, options.wordTimestamps else { return options }
		var options = options
		options.wordTimestamps = false
		return options
	}
}
