import Foundation
import Testing

@testable import Whispera

struct FillerWordRemovalTests {
	private func clean(_ text: String, _ language: String, extra: [String] = []) -> String {
		clean(text, .userSelected(language), extra: extra)
	}

	private func clean(_ text: String, _ evidence: OutputLanguageEvidence, extra: [String] = []) -> String {
		TranscriptTextProcessor.normalize(
			TranscriptTextProcessor.removeFillerWords(text, language: evidence, additionalFillerWords: extra),
			preservingLineBreaks: false)
	}

	@Test func removesFillers() {
		#expect(clean("So uhm I was thinking uh about this", "en") == "So I was thinking about this")
	}

	@Test func caseInsensitive() {
		#expect(clean("UHM this is UH a test", "en") == "this is a test")
	}

	@Test func consumesAttachedPunctuation() {
		#expect(clean("Well, uhm, I think, uh. that's right", "en") == "Well, I think, that's right")
		#expect(clean("  Uhm, so I was, uh, thinking about this  ", "en") == "so I was, thinking about this")
	}

	@Test func normalizesWhitespace() {
		#expect(clean("Hello    world   test", "en") == "Hello world test")
		#expect(clean("  Hello world  ", "en") == "Hello world")
	}

	@Test func preservesNormalText() {
		let text = "This is a completely normal sentence."
		#expect(clean(text, "en") == text)
	}

	@Test func collapsesStutters() {
		#expect(clean("w wh wh wh wh wh wh wh wh wh why", "en") == "w wh why")
		#expect(clean("I I I I think so so so so", "en") == "I think so")
		#expect(clean("Check data doc doc doc doc documentation.", "en") == "Check data doc documentation.")
		#expect(clean("No NO no NO no", "en") == "No")
		#expect(clean("no no is fine", "en") == "no no is fine")
	}

	@Test func englishRemovesUm() {
		#expect(clean("um I think um this is good", "en") == "I think this is good")
	}

	@Test func portugueseKeepsUm() {
		#expect(clean("um gato bonito", "pt") == "um gato bonito")
		#expect(clean("um gato bonito", "pt-BR") == "um gato bonito")
	}

	@Test func spanishKeepsHa() {
		#expect(clean("ha sido un buen día", "es") == "ha sido un buen día")
	}

	@Test func unknownLanguageOnlyRemovesUniversalFillers() {
		#expect(clean("uh I think uhm this works", .unknown) == "I think this works")
		#expect(clean("um I think this works", .unknown) == "um I think this works")
		#expect(clean("uhh bueno hmm creo que um ha llegado", .unknown) == "bueno creo que um ha llegado")
		#expect(clean("хм я думаю ммм это работает", .unknown) == "я думаю это работает")
	}

	@Test func germanGatedFillersNeedEvidence() {
		let text = "äh ich glaube ähm das passt"
		#expect(clean(text, .unknown) == text)
		#expect(clean(text, "de") == "ich glaube das passt")
	}

	@Test func keepsMillimetres() {
		#expect(clean("the screw is 5 mm long", "en") == "the screw is 5 mm long")
	}

	@Test func detectedEvidenceUnlocksGatedFillers() {
		#expect(clean("um I think this works", .modelDetected("en")) == "I think this works")
		#expect(clean("euh je pense que ça marche", .textDetected("fr")) == "je pense que ça marche")
		#expect(clean("um so it works", .translatedToEnglish) == "so it works")
	}

	@Test func customFillersApplyWithoutLanguageEvidence() {
		let result = clean("like so basically I think", .unknown, extra: ["like", "basically"])
		#expect(result == "so I think")
	}

	@Test func customFillerIsNotRegexInjection() {
		#expect(clean("a.b stays and x removed", .unknown, extra: ["x", ".*"]) == "a.b stays and removed")
	}
}

struct LanguageEvidenceTests {
	@Test func translationMeansEnglish() {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: "de", translating: true, modelDetectedLanguage: "de", text: "")
		#expect(evidence == .translatedToEnglish)
	}

	@Test func explicitSelectionWins() {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: "pt", translating: false, modelDetectedLanguage: "en", text: "um gato")
		#expect(evidence == .userSelected("pt"))
	}

	@Test func autoUsesModelDetection() {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: nil, translating: false, modelDetectedLanguage: "fr", text: "")
		#expect(evidence == .modelDetected("fr"))
	}

	@Test func autoFallsBackToConfidentTextDetection() {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: nil, translating: false, modelDetectedLanguage: nil,
			text: "The weather forecast said it would probably rain throughout the whole weekend.")
		#expect(evidence == .textDetected("en"))
	}

	@Test func ambiguousTextIsUnknown() {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: nil, translating: false, modelDetectedLanguage: nil, text: "um ok")
		#expect(evidence == .unknown)
	}
}

struct FillerPipelineTests {
	@Test func pipelineRemovesFillersAndStutters() {
		let processor = TranscriptTextProcessor(configuration: TextProcessingConfiguration())
		#expect(processor.process("um so I I I think uh it works", language: .userSelected("en")) == "so I think it works")
	}

	@Test func disabledFillerRemovalKeepsTextVerbatim() {
		var configuration = TextProcessingConfiguration()
		configuration.fillerWordRemovalEnabled = false
		let processor = TranscriptTextProcessor(configuration: configuration)
		let text = "um  I I I think"
		#expect(processor.process(text, language: .userSelected("en")) == text)
	}

	@Test func fileTranscriptsKeepTheirLineBreaks() {
		var configuration = TextProcessingConfiguration()
		configuration.preservesLineBreaks = true
		let processor = TranscriptTextProcessor(configuration: configuration)
		let text = "  First   paragraph, um, here.\n\nSecond I I I paragraph uh.\nThird line  "
		#expect(
			processor.process(text, language: .userSelected("en"))
				== "First paragraph, here.\n\nSecond I paragraph\nThird line")
	}

	@Test func dictationStillFoldsLineBreaksIntoSpaces() {
		let processor = TranscriptTextProcessor(configuration: TextProcessingConfiguration())
		#expect(processor.process("one\ntwo\n\nthree", language: .userSelected("en")) == "one two three")
	}
}

struct FillerSettingsTests {
	private func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "FillerSettingsTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsWhenUnset() {
		let configuration = TextProcessingSettings.configuration(from: makeDefaults())
		#expect(configuration == TextProcessingConfiguration())
		#expect(configuration.fillerWordRemovalEnabled)
		#expect(configuration.customFillerWords.isEmpty)
	}

	@Test func roundTrips() {
		let defaults = makeDefaults()
		TextProcessingSettings.setCustomFillerWords(
			TextProcessingSettings.parseList("like, you know\nbasically, Like"), in: defaults)
		defaults.set(false, forKey: TextProcessingSettings.Keys.fillerWordRemovalEnabled)

		let configuration = TextProcessingSettings.configuration(from: defaults)
		#expect(configuration.customFillerWords == ["like", "you know", "basically"])
		#expect(!configuration.fillerWordRemovalEnabled)
	}
}
