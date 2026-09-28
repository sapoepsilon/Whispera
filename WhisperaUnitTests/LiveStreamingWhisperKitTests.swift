import Foundation
import Testing
import WhisperKit

@testable import Whispera

/// A recorded clip that a replay reveals a little at a time, like the microphone buffer filling.
@MainActor
final class GrowingClip: LiveAudioSource {
	let samples: [Float]
	var end = 0

	init(_ samples: [Float]) {
		self.samples = samples
	}

	var sampleCount: Int { end }

	func samples(from start: Int) -> [Float] {
		Array(samples[min(start, end)..<end])
	}

	func reveal(seconds: Double) {
		end = min(samples.count, end + Int(seconds * Double(WhisperKit.sampleRate)))
	}
}

/// Replays a recorded clip through the production live pass (`LiveDictationPass`, the same object
/// realtimeLoop drives): the buffer grows by `step` seconds between passes and by `latency`
/// seconds while each decode runs, the live text goes through the app's live text pipeline, and
/// stopping runs the production final decode. No pass sees the last `stopGap` seconds of the clip,
/// so the words said just before the stop are heard only by the final decode.
@MainActor
enum LiveSessionReplay {
	struct Outcome {
		/// Everything the session typed, the stop included.
		var typed: String
		/// What stopping would have typed without the final decode: the newest pass's pending tail.
		var typedWithoutFinalDecode: String
		/// The options the next pass would decode with, after the session.
		var nextOptions: DecodingOptions
		var languageIsSettled: Bool
	}

	static func decoder(_ whisperKit: WhisperKit, latency: Double = 0, clip: GrowingClip? = nil) -> LiveDecoder {
		{ samples, options in
			let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
			clip?.reveal(seconds: latency)
			return LiveDecodeOutput(
				segments: results.flatMap(\.segments).map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) },
				language: results.first?.language)
		}
	}

	static func run(
		_ whisperKit: WhisperKit, samples: [Float], base: DecodingOptions, step: Double, promptWords: [String],
		voiceActivity: VoiceActivitySettings, latency: Double = 0, stopGap: Double = 0
	) async throws -> Outcome {
		let clip = GrowingClip(samples)
		let pass = LiveDictationPass()
		let settings = LivePassSettings(
			base: base, voiceActivity: voiceActivity, promptWords: promptWords, minimumNewAudioSeconds: 0.3)
		let text = liveText()
		let decode = decoder(whisperKit, latency: latency, clip: clip)
		var typed = ""
		let stopAt = samples.count - Int(stopGap * Double(WhisperKit.sampleRate))
		// Every pass sees at most `stopAt` samples, so the rest is heard only by the final decode
		while clip.end + Int(step * Double(WhisperKit.sampleRate)) <= stopAt {
			clip.reveal(seconds: step)
			let result = try await pass.step(
				audio: clip, settings: settings, decode: decode, process: { text($0, pass.language) })
			if case .decoded(let confirmation) = result, !confirmation.confirmedAddition.isEmpty {
				let updated = WhisperKitTranscriber.appendingConfirmed(confirmation.confirmedAddition, to: typed)
				#expect(updated.hasPrefix(typed), "the word tracker can only type appended text")
				typed = updated
			}
		}
		let withoutFinalDecode = WhisperKitTranscriber.committingLiveTail(text(pass.pendingTail, pass.language), to: typed)
		clip.end = samples.count
		let tail = await pass.finish(
			audio: clip, settings: settings, decode: decoder(whisperKit),
			timeLimit: WhisperKitTranscriber.liveFinalDecodeTimeLimit * 4)
		return Outcome(
			typed: WhisperKitTranscriber.committingLiveTail(text(tail, pass.language), to: typed),
			typedWithoutFinalDecode: withoutFinalDecode, nextOptions: pass.liveOptions(base, windowHasSpeech: true),
			languageIsSettled: pass.languageIsSettled)
	}

	/// The app's live text pipeline with default text-processing settings, not the test machine's.
	static func liveText() -> (String, String?) -> String {
		let transcriber = WhisperKitTranscriber.shared
		let defaults = UserDefaults(suiteName: "LiveSessionReplay.\(UUID().uuidString)")!
		return { text, language in
			let previous = transcriber.textProcessingDefaults
			transcriber.textProcessingDefaults = defaults
			defer { transcriber.textProcessingDefaults = previous }
			return transcriber.processLiveText(text, language: language)
		}
	}

	/// Deterministic low-level hiss, like an idle microphone.
	nonisolated static func hiss(seconds: Double, amplitude: Float = 0.003) -> [Float] {
		var state: UInt32 = 12345
		return (0..<Int(seconds * Double(WhisperKit.sampleRate))).map { _ in
			state = state &* 1_664_525 &+ 1_013_904_223
			return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
		}
	}
}

/// Real WhisperKit runs of the live pass. Needs the openai_whisper-small model downloaded by the app.
@MainActor
@Suite(.serialized, .sharedTranscriber, .enabled(if: WhisperKitTestModel.runsSmallModelTests))
struct LiveStreamingWhisperKitTests {
	static let passage =
		"This is a long dictation used to test the Cancel Transcription button. It keeps talking for a while so that the transcription takes long enough to press cancel. The weather is nice today, and the release is almost ready. We checked the history window, the settings tabs, and the menu bar popover. Now we are testing whether the transcription can be cancelled from the popover while it is still running. One more sentence to make it longer. And another sentence to be safe."
	static let sentenceMarkers = [
		"long dictation", "keeps talking", "weather is nice", "history window", "menu bar", "now we are testing",
		"one more sentence", "and another sentence",
	]
	static let customWords = ["Zyphora", "Quillmar", "Kubernetes"]

	func loadWhisperKit() async throws -> WhisperKit {
		try await WhisperKitTestModel.small()
	}

	func baseOptions(_ whisperKit: WhisperKit, prompt: Bool) -> DecodingOptions {
		let tokens =
			prompt
			? WhisperKitTranscriber.promptTokens(
				for: TextProcessingSettings.decoderPrompt(for: Self.customWords), tokenizer: whisperKit.tokenizer)
			: nil
		return DecodingOptions(
			task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 1, sampleLength: 224,
			usePrefillPrompt: true, usePrefillCache: true, skipSpecialTokens: true, withoutTimestamps: false,
			wordTimestamps: true, clipTimestamps: [0], promptTokens: tokens)
	}

	func speech(_ text: String) throws -> [Float] {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LiveReplay-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make(text, in: directory)
		return try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
	}

	/// Index-based confirmation over the re-decoded buffer dropped or retyped sentences of this
	/// passage in every one of these runs (QA saw the same on the signed app, 2 of 2).
	@Test(.timeLimit(.minutes(20)), arguments: [0.5, 1.0], [false, true])
	func longDictationTypesEverySentenceOnce(step: Double, prompt: Bool) async throws {
		let whisperKit = try await loadWhisperKit()
		let samples =
			[Float](repeating: 0, count: WhisperKit.sampleRate / 2) + (try speech(Self.passage))
			+ [Float](repeating: 0, count: WhisperKit.sampleRate * 3)
		let typed = try await LiveSessionReplay.run(
			whisperKit, samples: samples, base: baseOptions(whisperKit, prompt: prompt), step: step,
			promptWords: Self.customWords, voiceActivity: VoiceActivitySettings(enabled: false)
		).typed
		let lowered = typed.lowercased()
		for marker in Self.sentenceMarkers {
			#expect(lowered.components(separatedBy: marker).count == 2, "'\(marker)' once in: \(typed)")
		}
		#expect(!lowered.contains("zyphora") && !lowered.contains("quill"), "prompt echo in: \(typed)")
	}

	enum Lead: String, CaseIterable, Sendable {
		case zeros300ms, hiss1s, hiss2500ms

		var samples: [Float] {
			switch self {
			case .zeros300ms: return [Float](repeating: 0, count: WhisperKit.sampleRate * 3 / 10)
			case .hiss1s: return LiveSessionReplay.hiss(seconds: 1)
			case .hiss2500ms: return LiveSessionReplay.hiss(seconds: 2.5)
			}
		}
	}

	/// QA: with custom words set and Skip Silence off, the silent start of a live session typed
	/// "The Quills of the Quillmar". The pre-fix pass typed "Birds chirping", "The Quicksilve." or
	/// "...and the quick..." before the sentence for some of these leads. Whether the decoder
	/// hears the whole sentence with the prompt is the model's business, so only what comes
	/// before it is checked.
	@Test(.timeLimit(.minutes(20)), arguments: Lead.allCases, [0.3, 0.4, 0.5])
	func silentStartWithCustomWordsTypesOnlyTheSentence(lead: Lead, step: Double) async throws {
		let whisperKit = try await loadWhisperKit()
		for sentence in ["The quick brown fox jumps over the lazy dog.", "Hello world, this is a dictation test."] {
			let samples = lead.samples + (try speech(sentence)) + LiveSessionReplay.hiss(seconds: 1.5)
			let typed = try await LiveSessionReplay.run(
				whisperKit, samples: samples, base: baseOptions(whisperKit, prompt: true), step: step,
				promptWords: Self.customWords, voiceActivity: VoiceActivitySettings(enabled: false)
			).typed
			let key = LiveSegmentConfirmer.comparisonKey(typed)
			let opening = LiveSegmentConfirmer.comparisonKey(sentence).split(separator: " ").prefix(3).joined(separator: " ")
			#expect(key.hasPrefix(opening), "nothing may be typed before the sentence: \(typed)")
			for word in LiveStreamingWhisperKitTests.customWords {
				#expect(!key.contains(String(word.lowercased().prefix(5))), "prompt echo in: \(typed)")
			}
		}
	}

	/// Stopping committed only the newest finished pass's tail: speech after that pass's snapshot
	/// was never decoded, the pass in flight was thrown away and there was no final decode, so the
	/// last words before the stop were lost. Here decodes take 1.5 s of audio each and the stop
	/// comes 2.5 s after the newest pass started.
	@Test(.timeLimit(.minutes(10)), arguments: [false, true])
	func stoppingTypesTheWordsSaidAfterTheNewestPass(skipSilence: Bool) async throws {
		let whisperKit = try await loadWhisperKit()
		let samples =
			[Float](repeating: 0, count: WhisperKit.sampleRate / 2)
			+ (try speech("The weather is nice today. We checked the history window. Please send the final report tonight."))
			+ [Float](repeating: 0, count: WhisperKit.sampleRate * 3 / 10)
		let outcome = try await LiveSessionReplay.run(
			whisperKit, samples: samples, base: baseOptions(whisperKit, prompt: false), step: 1.0,
			promptWords: [], voiceActivity: VoiceActivitySettings(enabled: skipSilence), latency: 1.5, stopGap: 2.5)
		let typed = LiveSegmentConfirmer.comparisonKey(outcome.typed)
		for marker in ["weather is nice", "history window", "final report tonight"] {
			#expect(typed.components(separatedBy: marker).count == 2, "'\(marker)' once in: \(outcome.typed)")
		}
		#expect(
			!LiveSegmentConfirmer.comparisonKey(outcome.typedWithoutFinalDecode).contains("report tonight"),
			"the newest pass must not have heard the last words, or this test proves nothing: \(outcome.typedWithoutFinalDecode)")
	}

	/// With Skip Silence on, the gate looked only at the newest 3 s of new audio. When a decode ran
	/// longer than that and the speech ended early in it, every later check saw silence and the
	/// final words were never decoded, even while the session kept running.
	@Test(.timeLimit(.minutes(10)))
	func speechEndingEarlyInALongDecodeIsStillDecoded() async throws {
		let whisperKit = try await loadWhisperKit()
		let sentence = try speech("Please send the final report tonight.")
		let clip = GrowingClip(sentence + [Float](repeating: 0, count: WhisperKit.sampleRate * 6))
		let pass = LiveDictationPass()
		let settings = LivePassSettings(
			base: baseOptions(whisperKit, prompt: false), voiceActivity: VoiceActivitySettings(enabled: true),
			promptWords: [])
		// The first pass sees the opening of the sentence, then 6 s arrive while it decodes
		clip.end = WhisperKit.sampleRate
		let first = try await pass.step(
			audio: clip, settings: settings, decode: LiveSessionReplay.decoder(whisperKit, latency: 6, clip: clip),
			process: { $0 })
		try #require(first != .silence && first != .waitingForAudio, "the opening was not decoded: \(first)")
		let newAudio = clip.samples(from: WhisperKit.sampleRate)
		#expect(
			!VoiceActivityTrimmer().hasSpeech(newAudio.suffix(WhisperKit.sampleRate * 3)),
			"the newest 3 s, all the old gate looked at, must be silent or this test proves nothing")
		let next = try await pass.step(
			audio: clip, settings: settings, decode: LiveSessionReplay.decoder(whisperKit), process: { $0 })
		guard case .decoded = next else {
			Issue.record("speech in the new audio was treated as \(next)")
			return
		}
		#expect(LiveSegmentConfirmer.comparisonKey(pass.pendingTail).contains("report tonight"), "\(pass.pendingTail)")
	}

	/// Automatic detection ran on every pass, over the 1-3 s after the confirmation point, and a
	/// flip decoded (or translated) that pass in the wrong language. The language is now settled
	/// by the first confirmation, which is decoded from the session start.
	@Test(.timeLimit(.minutes(10)))
	func autoDetectedLanguageIsSettledForTheSession() async throws {
		let whisperKit = try await loadWhisperKit()
		var base = baseOptions(whisperKit, prompt: false)
		base.language = nil
		base.detectLanguage = true
		let samples = [Float](repeating: 0, count: WhisperKit.sampleRate / 2) + (try speech(Self.passage))
		let outcome = try await LiveSessionReplay.run(
			whisperKit, samples: samples, base: base, step: 1.0, promptWords: [],
			voiceActivity: VoiceActivitySettings(enabled: false))
		#expect(outcome.languageIsSettled)
		#expect(outcome.nextOptions.language == "en")
		#expect(outcome.nextOptions.detectLanguage == false)
		#expect(LiveSegmentConfirmer.comparisonKey(outcome.typed).contains("history window"), "\(outcome.typed)")
	}
}
