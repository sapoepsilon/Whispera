import Foundation

enum ChineseScriptPreference: String, CaseIterable, Identifiable {
	case automatic
	case unchanged
	case simplified
	case traditional

	static let defaultValue = ChineseScriptPreference.automatic

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .automatic: return String(localized: "Match My Languages")
		case .unchanged: return String(localized: "As Transcribed")
		case .simplified: return String(localized: "Simplified")
		case .traditional: return String(localized: "Traditional")
		}
	}

	/// The script a Chinese reader of this Mac expects, taken from the first Chinese entry in
	/// the preferred languages (zh-Hant, zh-TW, zh-HK read Traditional; zh-Hans, zh-CN read
	/// Simplified). Without a Chinese entry the transcript is left as Whisper wrote it.
	static func automaticScript(preferredLanguages: [String]) -> ChineseScriptPreference {
		for identifier in preferredLanguages {
			let language = Locale.Language(identifier: identifier)
			guard let code = language.languageCode?.identifier, code == "zh" || code == "yue" else { continue }
			switch language.script?.identifier {
			case "Hant": return .traditional
			case "Hans": return .simplified
			default: break
			}
			switch language.region?.identifier {
			case "TW", "HK", "MO": return .traditional
			case "CN", "SG": return .simplified
			default: return code == "yue" ? .traditional : .simplified
			}
		}
		return .unchanged
	}
}

extension TranscriptTextProcessor {
	/// Whisper writes Cantonese ("yue") in Chinese characters too.
	static let chineseLanguageCodes: Set<String> = ["zh", "yue"]

	static func convertChineseScript(
		_ text: String, to preference: ChineseScriptPreference, language: OutputLanguageEvidence,
		preferredLanguages: [String] = Locale.preferredLanguages
	) -> String {
		// Gate on the output language so Japanese kanji are never rewritten.
		guard let code = language.baseLanguageCode, chineseLanguageCodes.contains(code) else { return text }
		let target =
			preference == .automatic
			? ChineseScriptPreference.automaticScript(preferredLanguages: preferredLanguages) : preference
		switch target {
		case .automatic, .unchanged:
			return text
		case .simplified:
			return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
		case .traditional:
			return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
		}
	}
}
