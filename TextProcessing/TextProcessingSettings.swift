import Foundation

enum TextProcessingSettings {
	enum Keys {
		static let fillerWordRemovalEnabled = "fillerWordRemovalEnabled"
		static let customFillerWords = "customFillerWords"
	}

	static func configuration(from defaults: UserDefaults = .standard) -> TextProcessingConfiguration {
		var configuration = TextProcessingConfiguration()
		configuration.fillerWordRemovalEnabled =
			defaults.object(forKey: Keys.fillerWordRemovalEnabled) as? Bool ?? true
		configuration.customFillerWords = customFillerWords(from: defaults)
		return configuration
	}

	static func customFillerWords(from defaults: UserDefaults = .standard) -> [String] {
		defaults.stringArray(forKey: Keys.customFillerWords) ?? []
	}

	static func setCustomFillerWords(_ words: [String], in defaults: UserDefaults = .standard) {
		defaults.set(sanitizedList(words), forKey: Keys.customFillerWords)
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
}
