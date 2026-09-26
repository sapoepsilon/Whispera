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

struct LiveSegmentConfirmationTests {
	@Test func holdsBackTheLastTwoSegmentsAndProcessesTheRest() {
		let result = WhisperKitTranscriber.confirmLiveSegments(
			[" Um, hello there.", " How are you?", " I am fine.", " Thanks."], alreadyConfirmed: 0,
			process: fillerProcessor([]))
		#expect(result.confirmedAddition == "hello there. How are you?")
		#expect(result.confirmedSegmentCount == 2)
		#expect(result.pendingText == "I am fine. Thanks.")
	}

	@Test func onlyNewSegmentsAreProcessedAndConfirmed() {
		let segments = [" One.", " Two.", " Three.", " Four.", " Five."]
		let result = WhisperKitTranscriber.confirmLiveSegments(
			segments, alreadyConfirmed: 2, process: { "[" + $0 + "]" })
		#expect(result.confirmedAddition == "[Three.]")
		#expect(result.confirmedSegmentCount == 3)
	}

	@Test func nothingNewKeepsTheCountAndTypesNothing() {
		let result = WhisperKitTranscriber.confirmLiveSegments(
			[" One.", " Two.", " Three."], alreadyConfirmed: 1, process: { _ in
				Issue.record("Nothing should be processed")
				return ""
			})
		#expect(result.confirmedAddition.isEmpty)
		#expect(result.confirmedSegmentCount == 1)
		#expect(result.pendingText == "Two. Three.")
	}

	@Test func fillerOnlyChunkIsConsumedWithoutTypingAnything() {
		let result = WhisperKitTranscriber.confirmLiveSegments(
			[" Um.", " Hello.", " World."], alreadyConfirmed: 0, process: fillerProcessor([]))
		#expect(result.confirmedAddition.isEmpty)
		#expect(result.confirmedSegmentCount == 1)
	}

	@Test func shortSessionsStayPending() {
		let result = WhisperKitTranscriber.confirmLiveSegments(
			[" Hello.", " World."], alreadyConfirmed: 0, process: fillerProcessor([]))
		#expect(result.confirmedAddition.isEmpty)
		#expect(result.confirmedSegmentCount == 0)
		#expect(result.pendingText == "Hello. World.")
	}

	/// DictationWordTracker types only the suffix past what it already typed, so confirmed
	/// text must only ever grow by appending, even when processing drops words.
	@Test func confirmedTextOnlyGrowsByAppending() {
		let process = fillerProcessor(["basically"])
		var segments: [String] = []
		var confirmed = ""
		var count = 0
		for text in [" Basically we start.", " Um, then we build.", " Then we test.", " Basically done.", " Bye."] {
			segments.append(text)
			let result = WhisperKitTranscriber.confirmLiveSegments(
				segments, alreadyConfirmed: count, process: process)
			count = result.confirmedSegmentCount
			guard !result.confirmedAddition.isEmpty else { continue }
			let updated = WhisperKitTranscriber.appendingConfirmed(result.confirmedAddition, to: confirmed)
			#expect(updated.hasPrefix(confirmed))
			confirmed = updated
		}
		#expect(confirmed == "we start. then we build. Then we test.")
		#expect(!confirmed.lowercased().contains("basically"))
		#expect(!confirmed.lowercased().contains("um"))
	}

	/// Stopping commits the held-back tail after the confirmed text, so the tracker types only
	/// the tail. A long session keeps each sentence once.
	@Test func stopAppendsTheHeldBackTailOnce() {
		let process = fillerProcessor([])
		let segments = [" One.", " Two.", " Three.", " Four.", " Five."]
		let result = WhisperKitTranscriber.confirmLiveSegments(segments, alreadyConfirmed: 0, process: process)
		let confirmed = WhisperKitTranscriber.appendingConfirmed(result.confirmedAddition, to: "")
		let final = WhisperKitTranscriber.committingLiveTail(process(result.pendingText), to: confirmed)
		#expect(final.hasPrefix(confirmed))
		#expect(final == "One. Two. Three. Four. Five.")
	}

	/// A single-segment session is all tail: stopping commits the whole sentence, not the
	/// partial text the decoder reported mid-decode.
	@Test func stopCommitsASingleSegmentSessionWhole() {
		let process = fillerProcessor([])
		let result = WhisperKitTranscriber.confirmLiveSegments(
			[" The quick brown fox jumps over the lazy dog."], alreadyConfirmed: 0, process: process)
		let final = WhisperKitTranscriber.committingLiveTail(process(result.pendingText), to: "")
		#expect(final == "The quick brown fox jumps over the lazy dog.")
	}

	@Test func stopWithNothingPendingKeepsConfirmedText() {
		#expect(WhisperKitTranscriber.committingLiveTail("", to: "Already typed.") == "Already typed.")
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
		let segments = results.flatMap(\.segments).map(\.text)
		try #require(segments.joined().lowercased().contains("fox"), "WhisperKit heard: \(segments)")

		let result = WhisperKitTranscriber.confirmLiveSegments(
			segments, alreadyConfirmed: 0, holdBack: 0, process: fillerProcessor(["fox"]))
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
