import CoreML
import Foundation
import Testing
import WhisperKit

@testable import Whispera

/// The token layout of the multilingual Whisper vocabulary.
private let multilingualTokens = SpecialTokens(
	endToken: 50257, englishToken: 50259, noSpeechToken: 50362, noTimestampsToken: 50363,
	specialTokenBegin: 50257, startOfPreviousToken: 50361, startOfTranscriptToken: 50258,
	timeTokenBegin: 50364, transcribeToken: 50359, translateToken: 50358, whitespaceToken: 220)
private let multilingualLogitsCount = 51865

struct PromptTimestampRulesFilterTests {
	let special = multilingualTokens
	let prompt = [1057, 88, 1471, 11, 2326]

	func timestamp(_ seconds: Double) -> Int { special.timeTokenBegin + Int(seconds / 0.02) }

	/// [<|startofprev|>, prompt..., <|sot|>, <|en|>, <|transcribe|>, <|0.00|>]
	var promptedPrefill: [Int] {
		[special.startOfPreviousToken] + prompt
			+ [special.startOfTranscriptToken, special.englishToken, special.transcribeToken, special.timeTokenBegin]
	}

	func zeroLogits() throws -> MLMultiArray {
		let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: multilingualLogitsCount)], dataType: .float16)
		logits.withUnsafeMutableBufferPointer(ofType: Float16.self) { pointer, _ in
			for index in pointer.indices { pointer[index] = 0 }
		}
		return logits
	}

	func value(_ logits: MLMultiArray, at index: Int) -> Float {
		logits.withUnsafeBufferPointer(ofType: Float16.self) { Float($0[index]) }
	}

	@Test func findsTheTaskTokenBehindThePrompt() {
		#expect(PromptTimestampRulesFilter.sampleBegin(in: promptedPrefill, specialTokens: special) == promptedPrefill.count)
		#expect(
			PromptTimestampRulesFilter.sampleBegin(in: promptedPrefill + [11, 22], specialTokens: special)
				== promptedPrefill.count)
		var predictedStart = promptedPrefill
		predictedStart[predictedStart.count - 1] = timestamp(0.4)
		#expect(PromptTimestampRulesFilter.sampleBegin(in: predictedStart, specialTokens: special) == promptedPrefill.count)
	}

	/// WhisperKit's own filter already handles these, or timestamps are off.
	@Test func leavesOtherDecodesToWhisperKit() {
		let unprompted = [special.startOfTranscriptToken, special.englishToken, special.transcribeToken, special.timeTokenBegin]
		#expect(PromptTimestampRulesFilter.sampleBegin(in: unprompted, specialTokens: special) == nil)

		let englishOnly = [special.startOfPreviousToken] + prompt + [special.startOfTranscriptToken, special.timeTokenBegin]
		#expect(PromptTimestampRulesFilter.sampleBegin(in: englishOnly, specialTokens: special) == nil)

		var withoutTimestamps = promptedPrefill
		withoutTimestamps[withoutTimestamps.count - 1] = special.noTimestampsToken
		#expect(PromptTimestampRulesFilter.sampleBegin(in: withoutTimestamps, specialTokens: special) == nil)
	}

	/// The root cause, token level: after "<|0.00|> text <|1.00|>" only a timestamp (closing the
	/// pair) or a later one may follow. WhisperKit's filter applies nothing once a prompt is sent.
	@Test func enforcesTimestampPairsWhereWhisperKitDoesNot() throws {
		let tokens = promptedPrefill + [440, 2068, timestamp(1)]

		let builtIn = TimestampRulesFilter(
			specialTokens: special, sampleBegin: promptedPrefill.count, maxInitialTimestampIndex: nil,
			isModelMultilingual: true)
		let untouched = builtIn.filterLogits(try zeroLogits(), withTokens: tokens)
		#expect(value(untouched, at: 440) == 0, "WhisperKit's filter skips prompted multilingual decodes")
		#expect(value(untouched, at: timestamp(0.5)) == 0)

		let filter = PromptTimestampRulesFilter { multilingualTokens }
		let filtered = filter.filterLogits(try zeroLogits(), withTokens: tokens)
		#expect(value(filtered, at: 440) == -.infinity, "text cannot follow an unpaired timestamp")
		#expect(value(filtered, at: special.noTimestampsToken) == -.infinity)
		#expect(value(filtered, at: timestamp(0.5)) == -.infinity, "timestamps cannot go back")
		#expect(value(filtered, at: timestamp(1)) == 0, "the pair can close")
		#expect(value(filtered, at: timestamp(2)) == 0)
	}

	@Test func unpromptedDecodesAreNotTouched() throws {
		let tokens = [special.startOfTranscriptToken, special.englishToken, special.transcribeToken, special.timeTokenBegin, 440, timestamp(1)]
		let filtered = PromptTimestampRulesFilter { multilingualTokens }.filterLogits(try zeroLogits(), withTokens: tokens)
		#expect(value(filtered, at: 440) == 0)
		#expect(value(filtered, at: special.noTimestampsToken) == 0)
	}
}

/// Real WhisperKit runs of the QA passage that typed part of sentence 1 twice and dropped
/// sentence 2 in Live mode whenever custom words were set (4 of 4 runs, 0 of 5 without).
/// Needs the multilingual openai_whisper-small model downloaded by the app.
@MainActor
@Suite(.serialized, .enabled(if: WhisperKitTestModel.smallModelFolder != nil))
struct PromptTimestampRulesWhisperKitTests {
	static let passage =
		"The quick brown fox jumps over the lazy dog near the riverbank. Latency matters more than raw accuracy for live dictation. [[slnc 4200]] The seventh experiment concluded at four fifteen in the afternoon. Whispera should type every sentence exactly once. Please verify that no phrase appears twice in this transcript."
	static let markers = ["quick brown", "latency matters", "seventh experiment", "every sentence", "verify that no phrase"]
	static let customWords = ["Zyphora", "Quillmar"]

	static let turboModelFolder: URL? = {
		let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
			"Library/Application Support/Whispera/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo_954MB")
		return FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
			? folder : nil
	}()

	func loadWhisperKit(_ modelFolder: URL? = WhisperKitTestModel.smallModelFolder) async throws -> WhisperKit {
		let folder = try #require(modelFolder)
		let whisperKit = try await WhisperKitTranscriber.makeWhisperKit(
			WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false))
		try await whisperKit.loadTokenizerIfNeeded()
		return whisperKit
	}

	func options(_ whisperKit: WhisperKit, prompt: Bool) -> DecodingOptions {
		let tokens =
			prompt
			? WhisperKitTranscriber.promptTokens(
				for: TextProcessingSettings.decoderPrompt(for: Self.customWords), tokenizer: whisperKit.tokenizer)
			: nil
		// Word timestamps on, as timestamped file transcription asks for them
		return WhisperKitTranscriber.promptSafeDecodingOptions(DecodingOptions(
			task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 1, sampleLength: 224,
			usePrefillPrompt: true, usePrefillCache: true, skipSpecialTokens: true, withoutTimestamps: false,
			wordTimestamps: true, clipTimestamps: [0], promptTokens: tokens))
	}

	func passageAudio(in directory: URL) throws -> URL {
		try SpeechFixture.make(Self.passage, in: directory)
	}

	func samples() throws -> [Float] {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("PromptTimestamps-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let speech = try AudioProcessor.loadAudioAsFloatArray(fromPath: try passageAudio(in: directory).path)
		return [Float](repeating: 0, count: WhisperKit.sampleRate / 2) + speech
			+ [Float](repeating: 0, count: WhisperKit.sampleRate * 5 / 2)
	}

	func expectOrderedTimestamps(_ segments: [LiveSegment], _ label: String) {
		for (index, segment) in segments.enumerated() {
			#expect(segment.end > segment.start, "\(label): empty segment \(segment.start)-\(segment.end) '\(segment.text)'")
			if index > 0 {
				#expect(
					segment.start >= segments[index - 1].end - 0.05,
					"\(label): segment goes back in time at '\(segment.text)'")
			}
		}
	}

	func firstSentenceEnd(_ segments: [LiveSegment]) -> Float? {
		segments.first { LiveSegmentConfirmer.comparisonKey($0.text).contains("river") }?.end
	}

	/// Where the first sentence's speech ends in `samples()`: the lead silence plus the length of
	/// the sentence spoken on its own.
	func firstSentenceSpeechEnd() throws -> Float {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("PromptTimestampsS1-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = try SpeechFixture.make("The quick brown fox jumps over the lazy dog near the riverbank.", in: directory)
		let speech = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
		return 0.5 + Float(speech.count) / Float(WhisperKit.sampleRate)
	}

	/// With the prompt the first sentence ended about 2.5 s early (1.84 s instead of about 4.4 s)
	/// and a segment landed at 54 s of a 28 s clip; the live pass then decoded the same audio again.
	@Test(.timeLimit(.minutes(10)))
	func promptKeepsSegmentTimestamps() async throws {
		let whisperKit = try await loadWhisperKit()
		let audio = try samples()
		let speechEnd = try firstSentenceSpeechEnd()
		let prompted = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options(whisperKit, prompt: true))
			.flatMap(\.segments).map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) }
		let description = prompted.map { "[\($0.start)-\($0.end)] \($0.text)" }.joined(separator: " | ")
		expectOrderedTimestamps(prompted, "prompt")
		let audioSeconds = Float(audio.count) / Float(WhisperKit.sampleRate)
		for segment in prompted {
			#expect(segment.end <= audioSeconds + 0.5, "segment past the end of \(audioSeconds)s audio: \(description)")
		}
		let promptedEnd = try #require(firstSentenceEnd(prompted), "prompt: \(description)")
		#expect(
			promptedEnd >= speechEnd - 0.6 && promptedEnd <= speechEnd + 1.0,
			"first sentence ends at \(promptedEnd)s with the prompt, its speech ends at \(speechEnd)s: \(description)")
	}

	@Test(.timeLimit(.minutes(20)), arguments: [0.5, 1.0])
	func liveModeWithCustomWordsTypesEverySentenceOnce(step: Double) async throws {
		try await expectEverySentenceOnce(try await loadWhisperKit(), step: step)
	}

	/// The model QA ran the signed app with.
	@Test(.timeLimit(.minutes(30)), .enabled(if: Self.turboModelFolder != nil))
	func liveModeWithCustomWordsOnLargeV3Turbo() async throws {
		try await expectEverySentenceOnce(try await loadWhisperKit(Self.turboModelFolder), step: 1.0)
	}

	func expectEverySentenceOnce(_ whisperKit: WhisperKit, step: Double) async throws {
		let typed = try await LiveSessionReplay.run(
			whisperKit, samples: try samples(), base: options(whisperKit, prompt: true), step: step,
			promptWords: Self.customWords, voiceActivity: VoiceActivitySettings(enabled: false))
		let lowered = LiveSegmentConfirmer.comparisonKey(typed)
		for marker in Self.markers {
			#expect(lowered.components(separatedBy: marker).count == 2, "'\(marker)' once in: \(typed)")
		}
		#expect(!typed.contains("\""), "stray quotes in: \(typed)")
	}

	/// Timestamped file transcription sends the same prompt with timestamps on.
	@Test(.timeLimit(.minutes(10)))
	func timestampedFileTranscriptionWithCustomWords() async throws {
		let whisperKit = try await loadWhisperKit()
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("PromptTimestampsFile-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try passageAudio(in: directory)
		let segments = try await whisperKit.transcribe(audioPath: audio.path, decodeOptions: options(whisperKit, prompt: true))
			.flatMap(\.segments).map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) }
		expectOrderedTimestamps(segments, "file")
		let text = LiveSegmentConfirmer.comparisonKey(segments.map(\.text).joined(separator: " "))
		for marker in Self.markers {
			#expect(text.components(separatedBy: marker).count == 2, "'\(marker)' once in: \(text)")
		}
		let firstEnd = try #require(firstSentenceEnd(segments))
		#expect(firstEnd > 3, "the first sentence runs past 3 s of audio, it ended at \(firstEnd)s")
	}
}
