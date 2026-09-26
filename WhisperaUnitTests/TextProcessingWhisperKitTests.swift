import Foundation
import Testing
import WhisperKit

@testable import Whispera

enum WhisperKitTestModel {
	static var smallModelFolder: URL? {
		let folder = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(
				"Library/Application Support/Whispera/models/argmaxinc/whisperkit-coreml/openai_whisper-small")
		return FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
			? folder : nil
	}
}

/// Runs the text pipeline against real WhisperKit output. Needs the multilingual
/// openai_whisper-small model already downloaded by the app and the system `say` voices.
@MainActor
@Suite(.serialized, .enabled(if: WhisperKitTestModel.smallModelFolder != nil))
struct TextProcessingWhisperKitTests {
	func loadWhisperKit() async throws -> WhisperKit {
		let folder = try #require(WhisperKitTestModel.smallModelFolder)
		let config = WhisperKitConfig(
			modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false)
		return try await WhisperKit(config)
	}

	func speak(_ text: String, voice: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("whispera-tp-\(UUID().uuidString).wav")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
		process.arguments = ["-v", voice, "--data-format=LEI16@16000", "-o", url.path, text]
		try process.run()
		process.waitUntilExit()
		try #require(process.terminationStatus == 0)
		return url
	}

	func autoOptions(promptTokens: [Int]? = nil) -> DecodingOptions {
		let parameters = WhisperKitTranscriber.languageDecodingParameters(
			selectedLanguage: Constants.autoDetectLanguageName, enableTranslation: false)
		return DecodingOptions(
			task: .transcribe, language: parameters.language, temperature: 0, sampleLength: 224,
			usePrefillPrompt: true, usePrefillCache: true, detectLanguage: parameters.detectLanguage,
			skipSpecialTokens: true, promptTokens: promptTokens)
	}

	@Test(.timeLimit(.minutes(10)))
	func autoDetectIdentifiesGermanFromAudio() async throws {
		let whisperKit = try await loadWhisperKit()
		let audio = try speak(
			"Guten Morgen. Heute ist das Wetter sehr schön und wir gehen später in den Park.", voice: "Anna")
		defer { try? FileManager.default.removeItem(at: audio) }

		let results = try await whisperKit.transcribe(audioPath: audio.path, decodeOptions: autoOptions())
		let result = try #require(results.first)
		#expect(result.language == "de", "auto mode should detect German, got \(result.language): \(result.text)")

		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: nil, translating: false, modelDetectedLanguage: result.language,
			text: result.text)
		#expect(evidence == .modelDetected("de"))
	}
}
