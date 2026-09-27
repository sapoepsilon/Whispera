import Foundation
import Testing
import WhisperKit

@testable import Whispera

private func isolatedDefaults(_ name: String = #function) -> (UserDefaults, String) {
	let suite = "EnginePipelineTests.\(name).\(UUID().uuidString)"
	return (UserDefaults(suiteName: suite)!, suite)
}

private func fillerProcessor(_ words: [String]) -> (String) -> String {
	var configuration = TextProcessingConfiguration()
	configuration.customFillerWords = words
	let processor = TranscriptTextProcessor(configuration: configuration)
	return { processor.process($0, language: .userSelected("en")) }
}

private func seg(_ text: String, _ start: Float, _ end: Float) -> LiveSegment {
	LiveSegment(text: text, start: start, end: end)
}

struct LiveSegmentConfirmationTests {
	/// Runs one pass twice, the way consecutive live passes agree on stable segments.
	private func confirmTwice(
		_ confirmer: inout LiveSegmentConfirmer, _ segments: [LiveSegment], audio: Float = 60,
		process: (String) -> String = { $0 }
	) -> LiveSegmentConfirmer.Result {
		_ = confirmer.apply(segments, audioSeconds: audio, process: process)
		return confirmer.apply(segments, audioSeconds: audio, process: process)
	}

	@Test func holdsBackTheLastTwoSegmentsAndProcessesTheRest() {
		var confirmer = LiveSegmentConfirmer()
		let result = confirmTwice(
			&confirmer,
			[seg(" Um, hello there.", 0, 1.5), seg(" How are you?", 2, 3), seg(" I am fine.", 3.5, 4.5), seg(" Thanks.", 5, 5.5)],
			process: fillerProcessor([]))
		#expect(result.confirmedAddition == "hello there. How are you?")
		#expect(result.confirmedSegmentCount == 2)
		#expect(result.pendingText == "I am fine. Thanks.")
		#expect(confirmer.confirmedThroughSeconds == 3)
	}

	@Test func aSegmentIsConfirmedOnlyOnceTwoPassesAgree() {
		var confirmer = LiveSegmentConfirmer()
		let first = confirmer.apply(
			[seg("One.", 0, 1), seg("Two.", 1.5, 2), seg("Three.", 2.5, 3)], audioSeconds: 3.2, process: { $0 })
		#expect(first.confirmedAddition.isEmpty)
		#expect(first.pendingText == "One. Two. Three.")
		let changed = confirmer.apply(
			[seg("Won.", 0, 1), seg("Two.", 1.5, 2), seg("Three.", 2.5, 3)], audioSeconds: 3.4, process: { $0 })
		#expect(changed.confirmedAddition.isEmpty)
		let agreed = confirmer.apply(
			[seg("won", 0, 1), seg("Two.", 1.5, 2), seg("Three.", 2.5, 3), seg("Four.", 3.3, 3.6)],
			audioSeconds: 3.8, process: { $0 })
		#expect(agreed.confirmedAddition == "won Two.")
		#expect(agreed.pendingText == "Three. Four.")
	}

	/// The old index-based confirmation retyped or dropped a sentence when Whisper merged or
	/// split segments of the re-decoded window. Confirmed audio is now never decoded again, and
	/// segments the decoder still reports inside it are ignored.
	@Test func resegmentationNeitherDropsNorRepeatsASentence() {
		var confirmer = LiveSegmentConfirmer()
		var typed = ""
		func pass(_ segments: [LiveSegment], _ audio: Float) {
			let result = confirmer.apply(segments, audioSeconds: audio, process: { $0 })
			guard !result.confirmedAddition.isEmpty else { return }
			let updated = WhisperKitTranscriber.appendingConfirmed(result.confirmedAddition, to: typed)
			#expect(updated.hasPrefix(typed))
			typed = updated
		}
		let a = seg("This is a long dictation.", 0.3, 3.7)
		let b = seg("It keeps talking for a while.", 4.5, 8.9)
		let c = seg("The weather is nice today.", 9.8, 12.5)
		pass([a, b, c], 12.6)
		pass([a, b, c], 13.0)
		#expect(typed == "This is a long dictation.")
		// The next pass starts at 3.7 s, and Whisper merges b and c into one segment
		#expect(confirmer.confirmedThroughSeconds == 3.7)
		let bc = seg("It keeps talking for a while. The weather is nice today.", 4.5, 12.5)
		let d = seg("We checked the history window.", 13.4, 17.3)
		pass([bc, d], 17.5)
		pass([bc, d], 18.0)
		#expect(typed == "This is a long dictation.")
		// A stale segment inside confirmed audio, then the window split again
		let e = seg("Now we are testing.", 18.3, 23.4)
		pass([seg("This is a long dictation.", 0.3, 3.7), b, c, d, e], 23.6)
		pass([b, c, d, e], 24.0)
		#expect(typed == "This is a long dictation. It keeps talking for a while. The weather is nice today.")
		let final = WhisperKitTranscriber.committingLiveTail(
			confirmer.apply([d, e], audioSeconds: 24.2, process: { $0 }).pendingText, to: typed)
		#expect(
			final
				== "This is a long dictation. It keeps talking for a while. The weather is nice today. We checked the history window. Now we are testing."
		)
	}

	@Test func confirmationPointStaysInsideTheAudioAndNeverMovesBack() {
		var confirmer = LiveSegmentConfirmer(holdBack: 1)
		// Short windows come back with timestamps past the end of the audio
		let result = confirmTwice(&confirmer, [seg("Hello.", 0.2, 19.8), seg("there", 19.9, 25)], audio: 1.4)
		#expect(result.confirmedAddition == "Hello.")
		#expect(confirmer.confirmedThroughSeconds == 1.4)
		let later = confirmTwice(&confirmer, [seg("there", 0.5, 1.0), seg("friend", 1.2, 1.5)], audio: 1.6)
		#expect(later.confirmedAddition.isEmpty, "a segment ending before 1.4 s is already typed")
		#expect(confirmer.confirmedThroughSeconds == 1.4)
	}

	@Test func stopCommitsEveryUnconfirmedSegmentOnce() {
		var confirmer = LiveSegmentConfirmer()
		let result = confirmer.apply(
			[seg("One.", 0, 1), seg("Two.", 1.5, 2), seg("Three.", 2.5, 3), seg("Four.", 3.5, 4)],
			audioSeconds: 4.2, process: { $0 })
		#expect(result.confirmedAddition.isEmpty)
		let final = WhisperKitTranscriber.committingLiveTail(result.pendingText, to: "")
		#expect(final == "One. Two. Three. Four.")
	}

	@Test func fillerOnlyChunkIsConsumedWithoutTypingAnything() {
		var confirmer = LiveSegmentConfirmer()
		let result = confirmTwice(
			&confirmer, [seg(" Um.", 0, 0.5), seg(" Hello.", 1, 1.5), seg(" World.", 2, 2.5)],
			process: fillerProcessor([]))
		#expect(result.confirmedAddition.isEmpty)
		#expect(result.confirmedSegmentCount == 1)
		#expect(confirmer.confirmedThroughSeconds == 0.5)
	}

	@Test func shortSessionsStayPending() {
		var confirmer = LiveSegmentConfirmer()
		let result = confirmTwice(&confirmer, [seg(" Hello.", 0, 1), seg(" World.", 1.2, 2)])
		#expect(result.confirmedAddition.isEmpty)
		#expect(result.confirmedSegmentCount == 0)
		#expect(result.pendingText == "Hello. World.")
	}

	/// Stopping commits the held-back tail after the confirmed text, so the tracker types only
	/// the tail.
	@Test func stopAppendsTheHeldBackTailOnce() {
		var confirmer = LiveSegmentConfirmer()
		let segments = [seg("One.", 0, 1), seg("Two.", 1, 2), seg("Three.", 2, 3), seg("Four.", 3, 4), seg("Five.", 4, 5)]
		let result = confirmTwice(&confirmer, segments)
		let confirmed = WhisperKitTranscriber.appendingConfirmed(result.confirmedAddition, to: "")
		let final = WhisperKitTranscriber.committingLiveTail(result.pendingText, to: confirmed)
		#expect(final.hasPrefix(confirmed))
		#expect(final == "One. Two. Three. Four. Five.")
	}

	/// A single-segment session is all tail: stopping commits the whole sentence, not the
	/// partial text the decoder reported mid-decode.
	@Test func stopCommitsASingleSegmentSessionWhole() {
		var confirmer = LiveSegmentConfirmer()
		let result = confirmTwice(&confirmer, [seg(" The quick brown fox jumps over the lazy dog.", 0, 3)])
		let final = WhisperKitTranscriber.committingLiveTail(fillerProcessor([])(result.pendingText), to: "")
		#expect(final == "The quick brown fox jumps over the lazy dog.")
	}

	@Test func stopWithNothingPendingKeepsConfirmedText() {
		#expect(WhisperKitTranscriber.committingLiveTail("", to: "Already typed.") == "Already typed.")
	}

	@Test func eachPassDecodesFromTheConfirmationPointWithTimestamps() {
		let base = DecodingOptions(withoutTimestamps: true, clipTimestamps: [0], promptTokens: [1, 2, 3])
		let speech = WhisperKitTranscriber.liveDecodingOptions(base, clipStart: 7.5, windowHasSpeech: true)
		#expect(speech.clipTimestamps == [7.5])
		#expect(!speech.withoutTimestamps)
		#expect(speech.promptTokens == [1, 2, 3])
		let silent = WhisperKitTranscriber.liveDecodingOptions(base, clipStart: 0, windowHasSpeech: false)
		#expect(silent.promptTokens == nil, "Whisper echoes the custom-word prompt on silence")
	}

	@Test func silentWindowIsNotSpeechEvenWithSkipSilenceOff() {
		let noise = (0..<WhisperKit.sampleRate * 2).map { _ in Float.random(in: -0.003...0.003) }
		#expect(!WhisperKitTranscriber.liveWindowHasSpeech(noise, sensitivity: .medium))
		#expect(!WhisperKitTranscriber.liveWindowHasSpeech([], sensitivity: .high))
	}
}

struct PromptEchoFilterTests {
	let words = ["Zyphora", "Quillmar"]

	@Test func promptEchoesAreDropped() {
		#expect(PromptEchoFilter.isEcho("The Quills of the Quillmar", customWords: words))
		#expect(PromptEchoFilter.isEcho(" [Zyphora]", customWords: words))
		#expect(PromptEchoFilter.isEcho("Zyphora, Quillmar.", customWords: words))
	}

	@Test func speechUsingCustomWordsIsKept() {
		#expect(!PromptEchoFilter.isEcho("Please schedule the demo with Zyphora and Quillmar tomorrow.", customWords: words))
		#expect(!PromptEchoFilter.isEcho("Quillmar.", customWords: words))
		#expect(!PromptEchoFilter.isEcho("The quick brown fox.", customWords: words))
		#expect(!PromptEchoFilter.isEcho("[BLANK_AUDIO]", customWords: words))
		#expect(!PromptEchoFilter.isEcho("The Quills of the Quillmar", customWords: []))
	}

	@Test func liveSegmentsDropOnlyTheEcho() {
		let segments = [seg(" The Quills of the Quillmar", 0, 1.5), seg(" The quick brown fox.", 2, 4)]
		#expect(
			WhisperKitTranscriber.withoutPromptEchoes(segments, promptWords: words).map(\.text) == [
				" The quick brown fox."
			])
		#expect(WhisperKitTranscriber.withoutPromptEchoes(segments, promptWords: []).count == 2)
	}
}

struct LiveVoiceActivityTests {
	@Test func silenceIsNotSpeech() {
		let silence = [Float](repeating: 0, count: WhisperKit.sampleRate)
		#expect(!WhisperKitTranscriber.liveChunkHasSpeech(silence, settings: VoiceActivitySettings()))
	}

	@Test func quietNoiseIsNotSpeech() {
		let noise = (0..<WhisperKit.sampleRate).map { _ in Float.random(in: -0.001...0.001) }
		#expect(!WhisperKitTranscriber.liveChunkHasSpeech(noise, settings: VoiceActivitySettings()))
	}

	@Test func disabledVADAlwaysTranscribes() {
		let silence = [Float](repeating: 0, count: WhisperKit.sampleRate)
		#expect(
			WhisperKitTranscriber.liveChunkHasSpeech(silence, settings: VoiceActivitySettings(enabled: false)))
	}

	@Test func spokenAudioIsSpeech() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LiveVAD-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make("Testing the live voice activity check.", in: directory)
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
		let recent = Array(samples.suffix(WhisperKitTranscriber.liveVADWindowSamples))
		#expect(WhisperKitTranscriber.liveChunkHasSpeech(recent, settings: VoiceActivitySettings()))
	}
}

struct EmptyTranscriptTests {
	@Test func whitespaceOnlyCountsAsEmpty() {
		#expect(AudioManager.isEmptyTranscript(""))
		#expect(AudioManager.isEmptyTranscript("  \n "))
		#expect(!AudioManager.isEmptyTranscript("hi"))
	}

	@MainActor
	@Test(.sharedTranscriber) func emptyAudioReturnsNoTextInsteadOfAPlaceholder() async throws {
		let text = try await WhisperKitTranscriber.shared.transcribeAudioArray([], enableTranslation: false)
		#expect(text.isEmpty)
	}
}

struct PrewarmKeyTests {
	@Test func keyChangesWithModelAndComputeUnits() {
		let ane = ModelComputeOptions(
			melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine,
			textDecoderCompute: .cpuAndNeuralEngine, prefillCompute: .cpuOnly)
		let gpu = ModelComputeOptions(
			melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU,
			prefillCompute: .cpuOnly)
		let a = WhisperKitTranscriber.prewarmKey(model: "openai_whisper-small", computeOptions: ane)
		#expect(a == WhisperKitTranscriber.prewarmKey(model: "openai_whisper-small", computeOptions: ane))
		#expect(a != WhisperKitTranscriber.prewarmKey(model: "openai_whisper-small", computeOptions: gpu))
		#expect(a != WhisperKitTranscriber.prewarmKey(model: "openai_whisper-base", computeOptions: ane))
	}
}

/// Feeds real WhisperKit segments through the live confirmation step, the way
/// realtimeLoop does, to prove the text pipeline reaches live dictation.
@MainActor
@Suite(.serialized, .enabled(if: WhisperKitTestModel.smallModelFolder != nil))
struct LiveTextPipelineWhisperKitTests {
	@Test(.timeLimit(.minutes(10)))
	func confirmedLiveTextIsProcessed() async throws {
		let folder = try #require(WhisperKitTestModel.smallModelFolder)
		let whisperKit = try await WhisperKit(
			WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false))
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LiveTP-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make(
			"The quick brown fox jumps over the lazy dog. Then the fox runs into the forest. The end.",
			in: directory)
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)

		let results = try await whisperKit.transcribe(
			audioArray: samples,
			decodeOptions: DecodingOptions(
				task: .transcribe, language: "en", temperature: 0, skipSpecialTokens: true,
				withoutTimestamps: false))
		let segments = results.flatMap(\.segments).map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) }
		try #require(segments.map(\.text).joined().lowercased().contains("fox"), "WhisperKit heard: \(segments)")

		var confirmer = LiveSegmentConfirmer(holdBack: 0)
		let seconds = Float(samples.count) / Float(WhisperKit.sampleRate)
		_ = confirmer.apply(segments, audioSeconds: seconds, process: fillerProcessor(["fox"]))
		let result = confirmer.apply(segments, audioSeconds: seconds, process: fillerProcessor(["fox"]))
		#expect(result.confirmedSegmentCount == segments.count)
		#expect(result.confirmedAddition.lowercased().contains("forest"))
		#expect(!result.confirmedAddition.lowercased().contains("fox"), "got \(result.confirmedAddition)")
	}
}

/// Real Parakeet transcription through the app's transcriber: file transcription, the
/// dictation path, the text pipeline and idle unload. Switches the shared transcriber to
/// Parakeet and back, restoring the model preferences it touches.
@MainActor
@Suite(.serialized, .sharedTranscriber, .enabled(if: ParakeetTranscriptionTests.enabled))
struct ParakeetPipelineTests {
	private func waitForInitialization(_ transcriber: WhisperKitTranscriber) async throws {
		let deadline = Date().addingTimeInterval(180)
		while Date() < deadline {
			if transcriber.isInitialized && !transcriber.isModelLoading { return }
			try await Task.sleep(nanoseconds: 250_000_000)
		}
		Issue.record("Transcriber never finished initializing: \(transcriber.initializationStatus)")
		throw CancellationError()
	}

	@Test(.timeLimit(.minutes(10)))
	func fileDictationAndIdleUnloadWorkWithParakeet() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitForInitialization(transcriber)

		let standard = UserDefaults.standard
		let savedSelected = standard.string(forKey: "selectedModel")
		let savedLastUsed = standard.string(forKey: "lastUsedModel")
		let previousModel = transcriber.currentModel
		defer {
			standard.set(savedSelected, forKey: "selectedModel")
			standard.set(savedLastUsed, forKey: "lastUsedModel")
		}
		let (defaults, suite) = isolatedDefaults()
		TextProcessingSettings.setCustomFillerWords(["fox"], in: defaults)
		transcriber.textProcessingDefaults = defaults
		defer {
			transcriber.textProcessingDefaults = .standard
			defaults.removePersistentDomain(forName: suite)
		}

		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetPipeline-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make(
			"The quick brown fox jumps over the lazy dog. Then it runs into the forest.", in: directory)
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)

		do {
			try await transcriber.switchModel(to: ParakeetModel.v3.rawValue)
			#expect(transcriber.parakeetEngine != nil)
			#expect(transcriber.whisperKit == nil)
			#expect(!transcriber.isIdleUnloaded)

			let fileManager = FileTranscriptionManager(whisperKit: transcriber)
			let segments = try await fileManager.transcribeFileWithTimestamps(at: audio)
			let segmentText = segments.map(\.text).joined(separator: " ").lowercased()
			#expect(segmentText.contains("forest"), "got \(segmentText)")
			#expect(!segmentText.contains("fox"), "text pipeline skipped: \(segmentText)")

			let fileText = try await fileManager.transcribeFile(at: audio).lowercased()
			#expect(fileText.contains("forest"), "got \(fileText)")
			#expect(!fileText.contains("fox"), "text pipeline skipped: \(fileText)")

			let dictation = try await transcriber.transcribeAudioArray(samples, enableTranslation: false)
			#expect(dictation.lowercased().contains("forest"), "got \(dictation)")
			#expect(!dictation.lowercased().contains("fox"), "text pipeline skipped: \(dictation)")

			let silence = try await transcriber.transcribeAudioArray(
				[Float](repeating: 0, count: WhisperKit.sampleRate * 2), enableTranslation: false)
			#expect(silence != "No speech detected")

			#expect(transcriber.canUnloadModel, "blockers: \(transcriber.idleUnloadBlockers)")
			await transcriber.unloadModel()
			#expect(transcriber.parakeetEngine == nil)
			#expect(transcriber.isIdleUnloaded)
			#expect(!transcriber.isModelLoaded)
			#expect(transcriber.hasAnyModel())

			let reloaded = try await transcriber.transcribeAudioArray(samples, enableTranslation: false)
			#expect(reloaded.lowercased().contains("forest"))
			#expect(transcriber.parakeetEngine != nil)
			#expect(!transcriber.isIdleUnloaded)
		} catch {
			Issue.record("Parakeet pipeline failed: \(error)")
		}

		if let previousModel, !ParakeetModel.isParakeetID(previousModel) {
			// The model was prewarmed at launch, so this reload skips prewarm and must still load
			try await transcriber.switchModel(to: previousModel)
			#expect(transcriber.isCurrentModelLoaded(), "state: \(transcriber.getCurrentModelState())")
		}
	}

	/// Picking another model while a Parakeet transcription runs used to tear the engine down under it.
	@Test(.timeLimit(.minutes(10)))
	func swappingModelsKeepsAnInFlightParakeetEngineUsable() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitForInitialization(transcriber)
		guard let previousModel = transcriber.currentModel, !ParakeetModel.isParakeetID(previousModel) else {
			return
		}
		let standard = UserDefaults.standard
		let savedSelected = standard.string(forKey: "selectedModel")
		let savedLastUsed = standard.string(forKey: "lastUsedModel")
		defer {
			standard.set(savedSelected, forKey: "selectedModel")
			standard.set(savedLastUsed, forKey: "lastUsedModel")
		}

		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetSwap-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make("The fox runs into the forest.", in: directory)
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)

		try await transcriber.switchModel(to: ParakeetModel.v3.rawValue)
		let engine = try #require(transcriber.parakeetEngine)

		transcriber.beginModelUse()
		var holdReleased = false
		defer { if !holdReleased { transcriber.endModelUse() } }
		try await transcriber.switchModel(to: previousModel)
		#expect(transcriber.parakeetEngine == nil)
		#expect(transcriber.whisperKit != nil)

		let transcript = try await engine.transcribe(samples: samples)
		#expect(transcript.text.lowercased().contains("forest"), "got \(transcript.text)")
		transcriber.endModelUse()
		holdReleased = true
		#expect(transcriber.isCurrentModelLoaded(), "state: \(transcriber.getCurrentModelState())")
	}
}
