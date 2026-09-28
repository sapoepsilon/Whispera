import Foundation
import NaturalLanguage

/// Spots segments that repeat the custom-word decoder prompt instead of transcribing speech.
/// Fed near-silence, Whisper tends to echo its prompt back ("[Zyphora]", "The Quills of the
/// Quillmar"), and in Live Transcription Mode that echo would be typed.
///
/// Text alone cannot tell the echo from the user saying their custom words: "Kentra Health." on
/// its own reads exactly like the echo of that custom word, and "Deploy to production." shares
/// its words' openings with "Deployment" and "Production". So a segment is only an echo when its
/// text looks like the prompt and its own stretch of audio holds no speech.
enum PromptEchoFilter {
	/// Whether a decoded segment is a prompt echo. `audio` is the segment's own samples, from its
	/// start to its end timestamp; timestamps past the decoded audio leave it empty, which counts
	/// as silence.
	static func isEcho(
		_ text: String, customWords: [String], audio: ArraySlice<Float>, sensitivity: VADSensitivity
	) -> Bool {
		looksLikePrompt(text, customWords: customWords)
			&& !VoiceActivityTrimmer(sensitivity: sensitivity).hasSpeech(audio)
	}

	/// The text half of the test: the segment's content words (four letters or more, so
	/// "the"/"of"/"and" do not count, or two characters in scripts written without spaces) all
	/// look like custom words, and either there are at least two of them or the whole segment is
	/// a bracketed sound label.
	static func looksLikePrompt(_ text: String, customWords: [String]) -> Bool {
		let vocabulary = Set(customWords.flatMap(words(in:)).filter { $0.count >= 2 })
		guard !vocabulary.isEmpty else { return false }
		let content = words(in: text).filter(isContentWord)
		guard !content.isEmpty else { return false }
		let matches = content.filter { word in vocabulary.contains { resembles(word, $0) } }.count
		guard matches == content.count else { return false }
		return matches >= 2 || isBracketed(text)
	}

	/// Chinese and Japanese have no spaces, so the tokenizer's dictionary finds the words.
	private static func words(in text: String) -> [String] {
		let lowered = text.lowercased()
		let tokenizer = NLTokenizer(unit: .word)
		tokenizer.string = lowered
		return tokenizer.tokens(for: lowered.startIndex..<lowered.endIndex).map { String(lowered[$0]) }
	}

	private static func isContentWord(_ word: String) -> Bool {
		word.count >= (word.unicodeScalars.contains(where: isUnspacedScript) ? 2 : 4)
	}

	private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
		default: return false
		}
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
