import Foundation

enum ChineseScriptPreference: String, CaseIterable, Identifiable {
	case unchanged
	case simplified
	case traditional

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .unchanged: return "As Transcribed"
		case .simplified: return "Simplified"
		case .traditional: return "Traditional"
		}
	}
}

extension TranscriptTextProcessor {
	static func convertChineseScript(
		_ text: String, to preference: ChineseScriptPreference, language: OutputLanguageEvidence
	) -> String {
		// Gate on the output language so Japanese kanji are never rewritten.
		guard language.baseLanguageCode == "zh" else { return text }
		switch preference {
		case .unchanged:
			return text
		case .simplified:
			return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
		case .traditional:
			return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
		}
	}
}
