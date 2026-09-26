import Foundation
import NaturalLanguage

/// What we know about the language of the text being cleaned. Language-specific
/// rules only run when there is evidence; unknown output fails closed.
enum OutputLanguageEvidence: Equatable {
	case userSelected(String)
	case modelDetected(String)
	case textDetected(String)
	case translatedToEnglish
	case unknown

	var languageCode: String? {
		switch self {
		case .userSelected(let code), .modelDetected(let code), .textDetected(let code):
			return code.isEmpty ? nil : code
		case .translatedToEnglish:
			return "en"
		case .unknown:
			return nil
		}
	}

	var baseLanguageCode: String? {
		guard let code = languageCode else { return nil }
		return code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
	}
}

struct TextProcessingConfiguration: Equatable {
	static let defaultWordCorrectionThreshold = 0.18

	var customWords: [String] = []
	var wordCorrectionThreshold: Double = defaultWordCorrectionThreshold
	var fillerWordRemovalEnabled = true
	var customFillerWords: [String] = []
	var chineseScript: ChineseScriptPreference = .defaultValue
	var preferredLanguages: [String] = Locale.preferredLanguages
	/// File transcripts keep their paragraph structure; dictation is typed into one field, so
	/// its line breaks are folded into spaces as before.
	var preservesLineBreaks = false
}

/// Post-transcription text pipeline: filler removal, stutter and whitespace cleanup,
/// custom-word correction, and Chinese script conversion. Pure and synchronous so it
/// can be unit tested without WhisperKit.
struct TranscriptTextProcessor {
	let configuration: TextProcessingConfiguration

	init(configuration: TextProcessingConfiguration) {
		self.configuration = configuration
	}

	func process(_ text: String, language: OutputLanguageEvidence) -> String {
		var result = Self.removeNonSpeechMarkers(text)
		if configuration.fillerWordRemovalEnabled {
			result = Self.removeFillerWords(
				result, language: language, additionalFillerWords: configuration.customFillerWords)
			result = Self.normalize(result, preservingLineBreaks: configuration.preservesLineBreaks)
		}
		if !configuration.customWords.isEmpty {
			result = Self.applyCustomWords(
				result, customWords: configuration.customWords,
				threshold: configuration.wordCorrectionThreshold,
				preservingLineBreaks: configuration.preservesLineBreaks)
		}
		result = Self.convertChineseScript(
			result, to: configuration.chineseScript, language: language,
			preferredLanguages: configuration.preferredLanguages)
		return result
	}
}

extension TranscriptTextProcessor {
	/// Whisper labels silence, noise and music with bracketed markers such as [BLANK_AUDIO].
	/// They are not speech, and pasted into a document they read as garbage.
	static func removeNonSpeechMarkers(_ text: String) -> String {
		let pattern = #"\[\s*(BLANK[_ ]AUDIO|NO[_ ]SPEECH|SILENCE|MUSIC|INAUDIBLE)\s*\]|\(\s*(silence|music|inaudible)\s*\)"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
		let range = NSRange(text.startIndex..., in: text)
		guard regex.firstMatch(in: text, range: range) != nil else { return text }
		let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
		let lines = stripped.components(separatedBy: "\n").map { line in
			line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
		}
		return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Correction re-joins words with single spaces, so a transcript that keeps its line
	/// breaks is corrected one line at a time. A custom word never spans a line break.
	static func applyCustomWords(
		_ text: String, customWords: [String], threshold: Double, preservingLineBreaks: Bool
	) -> String {
		guard preservingLineBreaks, text.contains(where: \.isNewline) else {
			return applyCustomWords(text, customWords: customWords, threshold: threshold)
		}
		return text.split(separator: "\n", omittingEmptySubsequences: false)
			.map { applyCustomWords(String($0), customWords: customWords, threshold: threshold) }
			.joined(separator: "\n")
	}
}

// MARK: - Filler words

extension TranscriptTextProcessor {
	/// Tokens that are not real words in any language Whisper outputs, safe to drop
	/// without knowing the language. Anything that is a word somewhere belongs in the gated lists.
	static let universalFillerWords = [
		"uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "хм", "ммм",
	]

	/// Only removed with language evidence, because the same token is a real word elsewhere
	/// (Portuguese "um" = "a", German "um" = "around", Spanish "ha" = "has").
	static func gatedFillerWords(forLanguage baseCode: String) -> [String] {
		switch baseCode {
		case "en": return ["um", "ah", "eh", "ha"]
		case "de": return ["äh", "ähm"]
		case "fr": return ["euh"]
		default: return []
		}
	}

	static func fillerWords(for language: OutputLanguageEvidence, additional: [String]) -> [String] {
		let gated = language.baseLanguageCode.map(gatedFillerWords(forLanguage:)) ?? []
		let custom = additional.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
			!$0.isEmpty
		}
		return universalFillerWords + gated + custom
	}

	static func removeFillerWords(
		_ text: String, language: OutputLanguageEvidence, additionalFillerWords: [String] = []
	) -> String {
		var result = text
		for word in fillerWords(for: language, additional: additionalFillerWords) {
			let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b[,.]?"
			guard
				let regex = try? NSRegularExpression(
					pattern: pattern, options: [.caseInsensitive, .useUnicodeWordBoundaries])
			else { continue }
			result = regex.stringByReplacingMatches(
				in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
		}
		return result
	}

	/// Collapses 3+ consecutive repeats of a word ("I I I I" -> "I"), squeezes whitespace, trims.
	/// With `preservingLineBreaks`, each line is cleaned on its own and the breaks stay.
	static func normalize(_ text: String, preservingLineBreaks: Bool) -> String {
		guard preservingLineBreaks else { return normalizeLine(text) }
		return text.split(separator: "\n", omittingEmptySubsequences: false)
			.map { normalizeLine(String($0)) }
			.joined(separator: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func normalizeLine(_ text: String) -> String {
		let words = text.split(whereSeparator: { $0.isWhitespace })
		var output: [Substring] = []
		var i = 0
		while i < words.count {
			let word = words[i]
			let lowered = word.lowercased()
			var count = 1
			if lowered.allSatisfy({ $0.isLetter }) {
				while i + count < words.count && words[i + count].lowercased() == lowered {
					count += 1
				}
			}
			if count >= 3 {
				output.append(word)
				i += count
			} else {
				output.append(word)
				i += 1
			}
		}
		return output.joined(separator: " ")
	}
}

// MARK: - Language evidence

extension TranscriptTextProcessor {
	static let minimumTextDetectionConfidence = 0.9

	/// Last-resort language identification from the transcript itself; nil unless confident.
	static func detectLanguage(of text: String) -> String? {
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(text)
		guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
			hypothesis.value >= minimumTextDetectionConfidence
		else { return nil }
		return hypothesis.key.rawValue
	}

	/// - Parameters:
	///   - selectedLanguageCode: nil when the user chose automatic detection.
	///   - modelDetectedLanguage: the language WhisperKit reported for the result.
	static func languageEvidence(
		selectedLanguageCode: String?, translating: Bool, modelDetectedLanguage: String?, text: String
	) -> OutputLanguageEvidence {
		if translating { return .translatedToEnglish }
		if let selectedLanguageCode, !selectedLanguageCode.isEmpty {
			return .userSelected(selectedLanguageCode)
		}
		if let modelDetectedLanguage, !modelDetectedLanguage.isEmpty {
			return .modelDetected(modelDetectedLanguage)
		}
		if let detected = detectLanguage(of: text) {
			return .textDetected(detected)
		}
		return .unknown
	}
}
