import Foundation
import Testing

@testable import Whispera

/// QA of the signed app: in Live mode sentences decoded on their own from the clip point came
/// back wrapped in quote marks, and the preview pill showed raw [BLANK_AUDIO] and [no audio].
struct LiveTextCleanupTests {
	@Test(arguments: [
		("\"Latency matters more than raw accuracy for lived dictation.\"", "Latency matters more than raw accuracy for lived dictation."),
		(" \"Whisper a should type every sentence exactly once.", "Whisper a should type every sentence exactly once."),
		("Please verify this transcript.\"", "Please verify this transcript."),
		("\u{201C}Curly quotes too.\u{201D}", "Curly quotes too."),
	])
	func removesQuotesWrappingASegment(raw: String, expected: String) {
		#expect(WhisperKitTranscriber.withoutStrayQuotes(raw) == expected)
	}

	@Test(arguments: [
		" He said \"hello\" and left.",
		"\"Hello,\" she said.",
		"The sign read \"open",
		"\"One\" and \"two\"",
		" The quick brown fox.",
	])
	func keepsQuotationsInsideASentence(text: String) {
		#expect(WhisperKitTranscriber.withoutStrayQuotes(text) == text)
	}

	@Test func liveSegmentsKeepTheirTimesAndDropPromptEchoes() {
		let segments = [
			LiveSegment(text: " \"Latency matters.\"", start: 3.9, end: 6.2),
			LiveSegment(text: " Zyphora, Quillmar", start: 6.2, end: 7),
		]
		let cleaned = WhisperKitTranscriber.liveSegments(segments, promptWords: ["Zyphora", "Quillmar"])
		#expect(cleaned == [LiveSegment(text: "Latency matters.", start: 3.9, end: 6.2)])
	}

	@Test(arguments: [
		("[BLANK_AUDIO]", ""),
		("[no audio]", ""),
		("The quick brown fox [BLANK_AUDIO]", "The quick brown fox"),
		("[no audio] Latency matters", "Latency matters"),
		("Plain words", "Plain words"),
	])
	func previewHidesNonSpeechMarkers(pending: String, expected: String) {
		#expect(WhisperKitTranscriber.livePreviewText(pending) == expected)
	}
}
