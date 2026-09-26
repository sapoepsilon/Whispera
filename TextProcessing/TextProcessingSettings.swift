import Foundation

enum TextProcessingSettings {
	enum Keys {
		static let customWords = "customWords"
		static let biasDecodingWithCustomWords = "biasDecodingWithCustomWords"
		static let wordCorrectionThreshold = "wordCorrectionThreshold"
		static let fillerWordRemovalEnabled = "fillerWordRemovalEnabled"
		static let customFillerWords = "customFillerWords"
		static let chineseScriptConversion = "chineseScriptConversion"
	}

	static let biasDecodingDefault = true
	static let wordCorrectionThresholdRange: ClosedRange<Double> = 0.05...0.5

	static func configuration(from defaults: UserDefaults = .standard) -> TextProcessingConfiguration {
		var configuration = TextProcessingConfiguration()
		configuration.customWords = customWords(from: defaults)
		if let threshold = defaults.object(forKey: Keys.wordCorrectionThreshold) as? Double {
			configuration.wordCorrectionThreshold = min(
				max(threshold, wordCorrectionThresholdRange.lowerBound), wordCorrectionThresholdRange.upperBound
			)
		}
		configuration.fillerWordRemovalEnabled =
			defaults.object(forKey: Keys.fillerWordRemovalEnabled) as? Bool ?? true
		configuration.customFillerWords = customFillerWords(from: defaults)
		configuration.chineseScript =
			defaults.string(forKey: Keys.chineseScriptConversion).flatMap(ChineseScriptPreference.init(rawValue:))
			?? .defaultValue
		return configuration
	}

	static func customWords(from defaults: UserDefaults = .standard) -> [String] {
		defaults.stringArray(forKey: Keys.customWords) ?? []
	}

	static func setCustomWords(_ words: [String], in defaults: UserDefaults = .standard) {
		defaults.set(sanitizedList(words), forKey: Keys.customWords)
	}

	/// Adds to whatever is stored right now rather than to a cached copy, so words added
	/// meanwhile from a link, the CLI, Raycast or an intent survive. Returns the words that
	/// were new.
	@discardableResult
	static func addCustomWords(_ words: [String], in defaults: UserDefaults = .standard) -> [String] {
		let existing = customWords(from: defaults)
		let known = Set(existing.map { $0.lowercased() })
		let added = sanitizedList(words).filter { !known.contains($0.lowercased()) }
		if !added.isEmpty {
			setCustomWords(existing + added, in: defaults)
		}
		return added
	}

	static func removeCustomWord(_ word: String, in defaults: UserDefaults = .standard) {
		setCustomWords(customWords(from: defaults).filter { $0 != word }, in: defaults)
	}

	static func customFillerWords(from defaults: UserDefaults = .standard) -> [String] {
		defaults.stringArray(forKey: Keys.customFillerWords) ?? []
	}

	static func setCustomFillerWords(_ words: [String], in defaults: UserDefaults = .standard) {
		defaults.set(sanitizedList(words), forKey: Keys.customFillerWords)
	}

	static func biasDecodingWithCustomWords(from defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: Keys.biasDecodingWithCustomWords) as? Bool ?? biasDecodingDefault
	}

	/// Trims, drops empties and case-insensitive duplicates, keeping first-seen order and spelling.
	static func sanitizedList(_ words: [String]) -> [String] {
		var seen = Set<String>()
		var result: [String] = []
		for word in words {
			let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
			result.append(trimmed)
		}
		return result
	}

	/// Splits user input on commas and newlines.
	static func parseList(_ text: String) -> [String] {
		sanitizedList(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
	}

	/// Whisper's decoder prompt biases spelling toward these words.
	static func decoderPrompt(for customWords: [String]) -> String? {
		let words = sanitizedList(customWords)
		guard !words.isEmpty else { return nil }
		return " " + words.joined(separator: ", ")
	}
}
