import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct CustomWordCorrectionTests {
	private func apply(_ text: String, _ words: [String], threshold: Double = 0.5) -> String {
		TranscriptTextProcessor.applyCustomWords(text, customWords: words, threshold: threshold)
	}

	@Test func exactMatchTakesCustomSpelling() {
		#expect(apply("hello world", ["Hello", "World"]) == "Hello World")
	}

	@Test func fuzzyMatchCorrectsMishearing() {
		#expect(apply("helo wrold", ["hello", "world"]) == "hello world")
	}

	@Test func emptyListLeavesTextAlone() {
		#expect(apply("hello world", []) == "hello world")
		#expect(apply("hello world", ["   "]) == "hello world")
	}

	@Test func twoWordNgramMergesAndKeepsPunctuation() {
		let result = apply("il cui nome è Charge B, che permette", ["ChargeBee"])
		#expect(result == "il cui nome è ChargeBee, che permette")
	}

	@Test func fourWordSpelledOutAcronym() {
		#expect(apply("use Chat G P T for this", ["ChatGPT"], threshold: 0.18) == "use ChatGPT for this")
	}

	@Test func prefersClosestNgram() {
		#expect(apply("Open AI GPT model", ["OpenAI", "GPT"]) == "OpenAI GPT model")
	}

	@Test func tieKeepsShorterNgramSoFollowingWordSurvives() {
		#expect(apply("CHARGE B is great", ["ChargeBee"]) == "CHARGEBEE is great")
	}

	@Test func customWordWithSpaceMatchesSplitWords() {
		#expect(apply("using Mac Book Pro", ["MacBook Pro"]) == "using MacBook Pro")
	}

	@Test func trailingDigitIsNotDoubled() {
		#expect(apply("use GPT4 for this", ["GPT-4"]) == "use GPT-4 for this")
	}

	@Test(arguments: [
		"send it to RD for review", "send it to R and D for review", "send it to R&D for review",
	])
	func ampersandWord(input: String) {
		#expect(apply(input, ["R&D"], threshold: 0.18) == "send it to R&D for review")
	}

	@Test func unicodePunctuationIsPreserved() {
		#expect(apply("「Handee。」", ["Handy"]) == "「Handy。」")
	}

	@Test func cjkIsNotFuzzyMatched() {
		#expect(apply("你好。", ["你号"], threshold: 1.0) == "你好。")
	}

	@Test func defaultThresholdLeavesUnrelatedWordsAlone() {
		let text = "Please send the quarterly report to the team today."
		#expect(apply(text, ["Whispera", "WhisperKit", "Kubernetes"], threshold: 0.18) == text)
	}

	@Test func defaultThresholdFixesCloseProductName() {
		#expect(apply("I use whisper a daily", ["Whispera"], threshold: 0.18) == "I use Whispera daily")
	}

	/// The G05 QA sentence: the custom word must not touch its neighbours.
	@Test(arguments: [
		"Please forward the Zyntrax invoice to Corvin tomorrow.",
		"Please forward the Zyntrak's invoice to Quorvyn tomorrow.",
	])
	func neighbouringWordsAreLeftAlone(text: String) {
		#expect(apply(text, ["Quorvyn"], threshold: 0.18) == text)
	}

	@Test func possessiveIsKeptOnTheCorrectedWord() {
		#expect(apply("Send it to Corvin's desk", ["Quorvyn"]) == "Send it to Quorvyn's desk")
		#expect(apply("Charge Bee's plan", ["ChargeBee"], threshold: 0.18) == "ChargeBee's plan")
		#expect(apply("CHARGE BEE\u{2019}S plan", ["ChargeBee"], threshold: 0.18) == "CHARGEBEE\u{2019}S plan")
		#expect(apply("ask Corvin's team.", ["Quorvyn"]) == "ask Quorvyn's team.")
	}

	@Test func possessiveIsNeverInvented() {
		#expect(apply("Corvin sent it", ["Quorvyn"]) == "Quorvyn sent it")
		#expect(apply("lunch at McDonald's", ["McDonald's"], threshold: 0.18) == "lunch at McDonald's")
	}

	/// Every one of these used to be rewritten at the default threshold: the phonetic discount let
	/// "motion" become "Notion", "slick" become "Slack", "whisper" become "Whispera".
	@Test func ordinaryWordsAreNotTurnedIntoCustomWords() {
		let words = ["Notion", "Slack", "Linear", "Whispera", "Handy", "ChargeBee"]
		let text = "The motion passed, a slick liner, I whisper by hand, the fee is chargeable."
		#expect(apply(text, words, threshold: 0.18) == text)
		// Only exact merges of ordinary words count; a near miss made of real words is left as heard.
		#expect(apply("Charge Bees plan", ["ChargeBee"], threshold: 0.18) == "Charge Bees plan")
	}

	@Test func commonWordGuardKeepsExactAndMultiWordMatches() {
		let words = ["Notion", "Whispera", "ChargeBee"]
		#expect(apply("open notion now", words, threshold: 0.18) == "open Notion now")
		#expect(apply("I use whisper a daily", words, threshold: 0.18) == "I use Whispera daily")
		#expect(apply("pay with Charge B today", words, threshold: 0.18) == "pay with ChargeBee today")
	}

	@Test func exactWordOfAnotherEntryIsKept() {
		#expect(
			apply("the zyntrax invoice for Quorvyn", ["Quorvyn", "Zyntrax"], threshold: 0.18)
				== "the Zyntrax invoice for Quorvyn")
	}

	@Test func ambiguousMatchBetweenTwoCustomWordsIsLeftAlone() {
		#expect(apply("ask Corvan", ["Corvin", "Corvon"], threshold: 0.18) == "ask Corvan")
		#expect(apply("ask corvin", ["Corvin", "Corvon"], threshold: 0.18) == "ask Corvin")
		#expect(apply("ask Corvan", ["Corvin", "Quorvyn"], threshold: 0.18) == "ask Corvin")
	}

	@Test func systemWordListIsAvailable() {
		#expect(CommonWords.contains("motion"))
		#expect(CommonWords.contains("whisper"))
		#expect(!CommonWords.contains("zyntrax"))
		#expect(!CommonWords.contains("corvin"))
		#expect(!CommonWords.contains("Motion"))
	}

	@Test func preserveCasePattern() {
		#expect(TranscriptTextProcessor.preserveCasePattern(original: "HELLO", replacement: "world") == "WORLD")
		#expect(TranscriptTextProcessor.preserveCasePattern(original: "Hello", replacement: "world") == "World")
		#expect(TranscriptTextProcessor.preserveCasePattern(original: "hello", replacement: "WORLD") == "WORLD")
	}

	private func punctuation(_ word: String) -> [String] {
		let parts = TranscriptTextProcessor.extractPunctuation(word)
		return [parts.prefix, parts.suffix]
	}

	@Test func extractPunctuationUsesCharacterBoundaries() {
		#expect(punctuation("hello") == ["", ""])
		#expect(punctuation("!hello?") == ["!", "?"])
		#expect(punctuation("...hello...") == ["...", "..."])
		#expect(punctuation("你好。") == ["", "。"])
		#expect(punctuation("「你好」") == ["「", "」"])
	}

	@Test func soundexCodes() {
		#expect(TranscriptTextProcessor.soundex("Robert") == "R163")
		#expect(TranscriptTextProcessor.soundex("Rupert") == "R163")
		#expect(TranscriptTextProcessor.soundex("Ashcraft") == "A261")
		#expect(TranscriptTextProcessor.soundex("Tymczak") == "T522")
		#expect(TranscriptTextProcessor.soundex("Pfister") == "P236")
		#expect(TranscriptTextProcessor.soundex("") == nil)
	}

	@Test func levenshteinDistance() {
		#expect(TranscriptTextProcessor.levenshtein("kitten", "sitting") == 3)
		#expect(TranscriptTextProcessor.levenshtein("", "abc") == 3)
		#expect(TranscriptTextProcessor.levenshtein("same", "same") == 0)
	}
}

struct CustomWordPipelineTests {
	@Test func correctionRunsAfterFillerCleanup() {
		var configuration = TextProcessingConfiguration()
		configuration.customWords = ["Whispera"]
		let processor = TranscriptTextProcessor(configuration: configuration)
		let result = processor.process("um so I I I use whisper a daily", language: .userSelected("en"))
		#expect(result == "so I use Whispera daily")
	}
}

struct CustomWordSettingsTests {
	private func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "CustomWordSettingsTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsWhenUnset() {
		let defaults = makeDefaults()
		let configuration = TextProcessingSettings.configuration(from: defaults)
		#expect(configuration.customWords.isEmpty)
		#expect(configuration.wordCorrectionThreshold == 0.18)
		#expect(TextProcessingSettings.biasDecodingWithCustomWords(from: defaults))
	}

	@Test func roundTrips() {
		let defaults = makeDefaults()
		TextProcessingSettings.setCustomWords([" Whispera ", "whispera", "", "ChargeBee"], in: defaults)
		defaults.set(0.3, forKey: TextProcessingSettings.Keys.wordCorrectionThreshold)
		defaults.set(false, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)

		let configuration = TextProcessingSettings.configuration(from: defaults)
		#expect(configuration.customWords == ["Whispera", "ChargeBee"])
		#expect(configuration.wordCorrectionThreshold == 0.3)
		#expect(!TextProcessingSettings.biasDecodingWithCustomWords(from: defaults))
	}

	@Test func thresholdIsClamped() {
		let defaults = makeDefaults()
		defaults.set(5.0, forKey: TextProcessingSettings.Keys.wordCorrectionThreshold)
		#expect(TextProcessingSettings.configuration(from: defaults).wordCorrectionThreshold == 0.5)
	}

	@Test func decoderPrompt() {
		#expect(TextProcessingSettings.decoderPrompt(for: []) == nil)
		#expect(TextProcessingSettings.decoderPrompt(for: ["Whispera", " WhisperKit "]) == " Whispera, WhisperKit")
	}
}

extension TextProcessingWhisperKitTests {
	@Test(.timeLimit(.minutes(10)))
	func customWordsBiasAndCorrectEnglish() async throws {
		let whisperKit = try await loadWhisperKit()
		let tokenizer = try #require(whisperKit.tokenizer)
		let prompt = try #require(TextProcessingSettings.decoderPrompt(for: ["Whispera"]))
		let promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
		#expect(!promptTokens.isEmpty)

		let audio = try speak("I dictate every email with Whispera on my Mac.", voice: "Samantha")
		defer { try? FileManager.default.removeItem(at: audio) }

		let results = try await whisperKit.transcribe(
			audioPath: audio.path, decodeOptions: autoOptions(promptTokens: promptTokens))
		let result = try #require(results.first)

		var configuration = TextProcessingConfiguration()
		configuration.customWords = ["Whispera"]
		let processed = TranscriptTextProcessor(configuration: configuration).process(
			result.text, language: .modelDetected(result.language))
		#expect(processed.contains("Whispera"), "raw: \(result.text) processed: \(processed)")
		#expect(processed.localizedCaseInsensitiveContains("email"))
	}
}

@MainActor
struct CustomWordsModelTests {
	private func makeDefaults(_ name: String = #function) -> (UserDefaults, String) {
		let suite = "CustomWordsModelTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return (defaults, suite)
	}

	@Test func wordsAddedElsewhereWhileSettingsIsOpenSurviveALocalAdd() {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		TextProcessingSettings.setCustomWords(["Grafana"], in: defaults)
		let model = CustomWordsModel(defaults: defaults)

		TextProcessingSettings.addCustomWords(["Kubernetes"], in: defaults)
		#expect(model.words == ["Grafana", "Kubernetes"])

		model.add("Whispera, grafana")
		#expect(TextProcessingSettings.customWords(from: defaults) == ["Grafana", "Kubernetes", "Whispera"])
		#expect(model.words == ["Grafana", "Kubernetes", "Whispera"])
	}

	@Test func removingAWordKeepsWordsAddedElsewhere() {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		TextProcessingSettings.setCustomWords(["Grafana", "Loki"], in: defaults)
		let model = CustomWordsModel(defaults: defaults)

		TextProcessingSettings.addCustomWords(["Kubernetes"], in: defaults)
		model.remove("Loki")
		#expect(TextProcessingSettings.customWords(from: defaults) == ["Grafana", "Kubernetes"])
		#expect(model.words == ["Grafana", "Kubernetes"])
	}

	@Test func addReportsOnlyNewWords() {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		TextProcessingSettings.setCustomWords(["Grafana"], in: defaults)
		#expect(TextProcessingSettings.addCustomWords(["grafana", " Loki ", "loki"], in: defaults) == ["Loki"])
		#expect(TextProcessingSettings.addCustomWords(["GRAFANA"], in: defaults).isEmpty)
		#expect(TextProcessingSettings.customWords(from: defaults) == ["Grafana", "Loki"])
	}
}
