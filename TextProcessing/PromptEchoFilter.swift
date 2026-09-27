import Foundation

/// Spots segments that repeat the custom-word decoder prompt instead of transcribing speech.
/// Fed near-silence, Whisper tends to echo its prompt back ("[Zyphora]", "The Quills of the
/// Quillmar"), and in Live Transcription Mode that echo would be typed.
///
/// A segment is an echo when its content words (four letters or more, so "the"/"of"/"and" do not
/// count in any language) all look like custom words and either there are at least two of them or
/// the whole segment is a bracketed sound label. A single custom word dictated on its own
/// ("Quillmar.") is kept; two custom words and nothing else ("Zyphora and Quillmar.") are
/// dropped, which is the price of catching the echo.
enum PromptEchoFilter {
	static func isEcho(_ text: String, customWords: [String]) -> Bool {
		let vocabulary = Set(customWords.flatMap(words(in:)).filter { $0.count >= 3 })
		guard !vocabulary.isEmpty else { return false }
		let content = words(in: text).filter { $0.count >= 4 }
		guard !content.isEmpty else { return false }
		let matches = content.filter { word in vocabulary.contains { resembles(word, $0) } }.count
		guard matches == content.count else { return false }
		return matches >= 2 || isBracketed(text)
	}

	private static func words(in text: String) -> [String] {
		text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
	}

	/// Echoes bend the word ("Quills" for Quillmar), so a shared start counts as a match.
	private static func resembles(_ word: String, _ customWord: String) -> Bool {
		guard word != customWord else { return true }
		let shared = zip(word, customWord).prefix { $0 == $1 }.count
		return shared >= min(5, customWord.count, word.count) && shared >= 4
	}

	private static func isBracketed(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "[]()"))))
		return (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
	}
}
