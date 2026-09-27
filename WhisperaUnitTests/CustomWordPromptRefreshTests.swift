import Foundation
import Testing
import WhisperKit

@testable import Whispera

@MainActor
struct CustomWordPromptObserverTests {
	private func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "CustomWordPromptObserverTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	/// RemoteControlCenter adds words this way for links, the CLI, Raycast and App Intents.
	@Test func wordsAddedOutsideSettingsAreReported() {
		let defaults = makeDefaults()
		var changes = 0
		let observer = CustomWordPromptObserver(defaults: defaults) { changes += 1 }

		TextProcessingSettings.addCustomWords(["Zyntrak"], in: defaults)
		#expect(changes == 1)
		#expect(observer.prompt == " Zyntrak")

		TextProcessingSettings.removeCustomWord("Zyntrak", in: defaults)
		#expect(changes == 2)
		#expect(observer.prompt == nil)
	}

	@Test func turningBiasOffAndOnIsReported() {
		let defaults = makeDefaults()
		TextProcessingSettings.setCustomWords(["Whispera"], in: defaults)
		var changes = 0
		let observer = CustomWordPromptObserver(defaults: defaults) { changes += 1 }

		defaults.set(false, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		#expect(changes == 1)
		#expect(observer.prompt == nil)

		defaults.set(true, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		#expect(changes == 2)
		#expect(observer.prompt == " Whispera")
	}

	@Test func writesThatKeepThePromptAreIgnored() {
		let defaults = makeDefaults()
		TextProcessingSettings.setCustomWords(["Whispera"], in: defaults)
		var changes = 0
		let observer = CustomWordPromptObserver(defaults: defaults) { changes += 1 }

		TextProcessingSettings.addCustomWords(["whispera"], in: defaults)
		TextProcessingSettings.setCustomWords(["Whispera"], in: defaults)
		defaults.set(0.3, forKey: TextProcessingSettings.Keys.wordCorrectionThreshold)
		#expect(changes == 0)
		#expect(observer.prompt == " Whispera")
	}

	@Test func noTokenizerMeansNoPromptTokens() {
		#expect(WhisperKitTranscriber.promptTokens(for: " Whispera", tokenizer: nil) == nil)
	}
}

extension TextProcessingWhisperKitTests {
	@Test(.timeLimit(.minutes(10)))
	func promptTokensComeFromTheLoadedTokenizer() async throws {
		let whisperKit = try await loadWhisperKit()
		let tokenizer = try #require(whisperKit.tokenizer)
		#expect(WhisperKitTranscriber.promptTokens(for: nil, tokenizer: tokenizer) == nil)
		let tokens = try #require(
			WhisperKitTranscriber.promptTokens(for: " Zyntrak, Whispera", tokenizer: tokenizer))
		#expect(!tokens.isEmpty)
		#expect(tokens.allSatisfy { $0 < tokenizer.specialTokens.specialTokenBegin })
		#expect(tokenizer.decode(tokens: tokens).contains("Zyntrak"))
	}
}

/// Drives the app's shared transcriber with a real WhisperKit model, in the state the app leaves
/// it after launch: prewarmed, with its tokenizer not loaded until the first transcription.
@MainActor
@Suite(.serialized, .sharedTranscriber, .enabled(if: ModelIdleUnloadIntegrationTests.hasDownloadedModel))
struct CustomWordPromptTranscriberTests {
	private func waitForWhisperKit(_ transcriber: WhisperKitTranscriber) async throws {
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline {
			if transcriber.isInitialized, transcriber.isCurrentModelLoaded(), transcriber.whisperKit != nil {
				return
			}
			try await Task.sleep(nanoseconds: 250_000_000)
		}
		Issue.record(
			"No WhisperKit model in the shared transcriber: initialized=\(transcriber.isInitialized) loaded=\(transcriber.isCurrentModelLoaded()) hasKit=\(transcriber.whisperKit != nil)"
		)
		throw CancellationError()
	}

	private func decodedPrompt(_ transcriber: WhisperKitTranscriber) -> String? {
		guard let tokens = transcriber.decodingOptions?.promptTokens,
			let tokenizer = transcriber.whisperKit?.tokenizer
		else { return nil }
		return tokenizer.decode(tokens: tokens)
	}

	@Test(.timeLimit(.minutes(10)))
	func customWordsReachTheDecoderFromTheFirstDictationAndFromOutsideSettings() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitForWhisperKit(transcriber)
		let defaults = UserDefaults.standard
		let savedWords = defaults.object(forKey: TextProcessingSettings.Keys.customWords)
		let savedBias = defaults.object(forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		defer {
			defaults.set(savedWords, forKey: TextProcessingSettings.Keys.customWords)
			defaults.set(savedBias, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		}
		defaults.set(true, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)

		// Added the way a whispera:// link, the CLI, Raycast or an App Intent adds it
		let first = "Qorvexa\(Int.random(in: 1000...9999))"
		TextProcessingSettings.addCustomWords([first], in: defaults)
		let silence = [Float](repeating: 0, count: 16000)
		_ = try await transcriber.transcribeAudioArray(silence, enableTranslation: false)
		let afterDictation = try #require(decodedPrompt(transcriber), "The dictation went out without a prompt")
		#expect(afterDictation.contains(first))

		// No dictation in between: the cached options the live loop reuses must follow the store
		let second = "Brellwick\(Int.random(in: 1000...9999))"
		TextProcessingSettings.addCustomWords([second], in: defaults)
		let afterAdd = try #require(decodedPrompt(transcriber))
		#expect(afterAdd.contains(second))

		defaults.set(false, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		#expect(transcriber.decodingOptions?.promptTokens == nil)
	}

	/// The menu-bar Browse, drag-and-drop, queue and YouTube path, plain and timestamped. Right
	/// after a launch or a model switch the model is only prewarmed and its tokenizer loads inside
	/// transcribe, after the options were built, so the first file went out without the prompt.
	@Test(.timeLimit(.minutes(10)), arguments: [false, true])
	func theFirstQueuedFileAfterALoadCarriesTheCustomWordPrompt(withTimestamps: Bool) async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitForWhisperKit(transcriber)
		let whisperKit = try #require(transcriber.whisperKit)
		let defaults = UserDefaults.standard
		let keys = [
			TextProcessingSettings.Keys.customWords, TextProcessingSettings.Keys.biasDecodingWithCustomWords,
			"decodingWithoutTimestamps", "decodingWordTimestamps",
		]
		let saved = keys.map { defaults.object(forKey: $0) }
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("FirstFilePrompt-\(UUID().uuidString)", isDirectory: true)
		defer {
			for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
			try? FileManager.default.removeItem(at: directory)
		}
		defaults.set(true, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		let word = "Quillmar\(Int.random(in: 1000...9999))"
		TextProcessingSettings.addCustomWords([word], in: defaults)
		let audio = try SpeechFixture.make("The meeting notes are ready for review.", in: directory)

		// The state a launch or a model switch leaves: specialized, weights and tokenizer not loaded
		try await whisperKit.prewarmModels()
		whisperKit.tokenizer = nil
		try #require(whisperKit.modelState == .prewarmed)
		let manager = FileTranscriptionManager(whisperKit: transcriber)
		_ = try await manager.transcribeFile(at: audio, withTimestamps: withTimestamps)

		let options = try #require(manager.lastSentDecodingOptions)
		let tokens = try #require(options.promptTokens, "The file went out without the custom-word prompt")
		let tokenizer = try #require(whisperKit.tokenizer)
		#expect(tokenizer.decode(tokens: tokens).contains(word))
	}

	/// History re-transcription and the transcriber's own file methods share this path.
	@Test(.timeLimit(.minutes(10)))
	func reTranscribingAFileAfterALoadCarriesTheCustomWordPrompt() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitForWhisperKit(transcriber)
		let whisperKit = try #require(transcriber.whisperKit)
		let defaults = UserDefaults.standard
		let savedWords = defaults.object(forKey: TextProcessingSettings.Keys.customWords)
		let savedBias = defaults.object(forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RetranscribePrompt-\(UUID().uuidString)", isDirectory: true)
		defer {
			defaults.set(savedWords, forKey: TextProcessingSettings.Keys.customWords)
			defaults.set(savedBias, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
			try? FileManager.default.removeItem(at: directory)
		}
		defaults.set(true, forKey: TextProcessingSettings.Keys.biasDecodingWithCustomWords)
		let word = "Zyphora\(Int.random(in: 1000...9999))"
		TextProcessingSettings.addCustomWords([word], in: defaults)
		let audio = try SpeechFixture.make("The meeting notes are ready for review.", in: directory)

		try await whisperKit.prewarmModels()
		whisperKit.tokenizer = nil
		_ = try await transcriber.transcribe(audioURL: audio, enableTranslation: false)

		let prompt = try #require(decodedPrompt(transcriber), "The re-transcription went out without a prompt")
		#expect(prompt.contains(word))
	}
}
