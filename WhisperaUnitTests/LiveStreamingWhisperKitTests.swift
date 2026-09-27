import Foundation
import Testing
import WhisperKit

@testable import Whispera

/// Replays a recorded clip through the live pass the way realtimeLoop runs it: the buffer grows
/// by `step` seconds, the VAD gate skips silent chunks, each pass decodes from the confirmation
/// point with the production options, and stopping commits the pending tail.
@MainActor
enum LiveSessionReplay {
	static func run(
		_ whisperKit: WhisperKit, samples: [Float], base: DecodingOptions, step: Double, promptWords: [String],
		voiceActivity: VoiceActivitySettings
	) async throws -> String {
		let rate = WhisperKit.sampleRate
		var confirmer = LiveSegmentConfirmer(holdBack: WhisperKitTranscriber.liveSegmentsHeldBack)
		var typed = ""
		var pending = ""
		var lastBufferSize = 0
		var length = Int(step * Double(rate))
		while true {
			let end = min(length, samples.count)
			let buffer = Array(samples[0..<end])
			let recent = Array(buffer[lastBufferSize...].suffix(WhisperKitTranscriber.liveVADWindowSamples))
			if WhisperKitTranscriber.liveChunkHasSpeech(recent, settings: voiceActivity) {
				lastBufferSize = end
				let clipStart = confirmer.confirmedThroughSeconds
				let windowStart = min(end, Int(clipStart * Float(rate)))
				let options = WhisperKitTranscriber.liveDecodingOptions(
					base, clipStart: clipStart,
					windowHasSpeech: WhisperKitTranscriber.liveWindowHasSpeech(
						Array(buffer[windowStart...]), sensitivity: voiceActivity.sensitivity))
				let results = try await whisperKit.transcribe(audioArray: buffer, decodeOptions: options)
				let segments = results.flatMap(\.segments)
				if !segments.isEmpty {
					let result = confirmer.apply(
						WhisperKitTranscriber.liveSegments(
							segments.map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) },
							promptWords: options.promptTokens == nil ? [] : promptWords),
						audioSeconds: Float(end) / Float(rate), process: { $0 })
					if !result.confirmedAddition.isEmpty {
						let updated = WhisperKitTranscriber.appendingConfirmed(result.confirmedAddition, to: typed)
						#expect(updated.hasPrefix(typed), "the word tracker can only type appended text")
						typed = updated
					}
					pending = result.pendingText
				}
			}
			if end == samples.count { break }
			length += Int(step * Double(rate))
		}
		return WhisperKitTranscriber.committingLiveTail(pending, to: typed)
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
			promptWords: Self.customWords, voiceActivity: VoiceActivitySettings(enabled: false))
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
				promptWords: Self.customWords, voiceActivity: VoiceActivitySettings(enabled: false))
			let key = LiveSegmentConfirmer.comparisonKey(typed)
			let opening = LiveSegmentConfirmer.comparisonKey(sentence).split(separator: " ").prefix(3).joined(separator: " ")
			#expect(key.hasPrefix(opening), "nothing may be typed before the sentence: \(typed)")
			for word in LiveStreamingWhisperKitTests.customWords {
				#expect(!key.contains(String(word.lowercased().prefix(5))), "prompt echo in: \(typed)")
			}
		}
	}
}
