import Testing

@testable import Whispera

struct NonSpeechMarkerTests {
	private func process(_ text: String, fillerRemoval: Bool = true) -> String {
		var configuration = TextProcessingConfiguration()
		configuration.fillerWordRemovalEnabled = fillerRemoval
		return TranscriptTextProcessor(configuration: configuration).process(text, language: .userSelected("en"))
	}

	/// Pink noise that got past Skip Silence came back as "[BLANK_AUDIO]" and was pasted.
	@Test func aClipOfOnlyNoiseBecomesEmpty() {
		#expect(process("[BLANK_AUDIO]").isEmpty)
		#expect(process(" [ BLANK_AUDIO ] ").isEmpty)
		#expect(process("(silence)", fillerRemoval: false).isEmpty)
	}

	/// With custom words in the decoder prompt a silent clip decoded as "[no audio]", which
	/// was pasted and would have been saved to history.
	@Test func noAudioMarkerBecomesEmpty() {
		#expect(process("[no audio]").isEmpty)
		#expect(process("[NO_AUDIO]", fillerRemoval: false).isEmpty)
	}

	@Test func trailingMarkerIsDroppedFromSpeech() {
		#expect(process("And another sentence to be safe. [BLANK_AUDIO]") == "And another sentence to be safe.")
		#expect(process("[MUSIC] Hello there [NO_SPEECH] friend", fillerRemoval: false) == "Hello there friend")
	}

	@Test func ordinaryBracketsStay() {
		#expect(process("Call it [draft] (version two)") == "Call it [draft] (version two)")
	}
}
