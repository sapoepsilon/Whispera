import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct CLICatalogCustomModelTests {
	private func isolatedDefaults() throws -> (UserDefaults, String) {
		let suite = "CLICatalogCustomModelTests-\(UUID().uuidString)"
		return (try #require(UserDefaults(suiteName: suite)), suite)
	}

	@Test func listsRegisteredCustomModelsWhoseFoldersExist() throws {
		let (defaults, suite) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("cli-custom-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: base) }
		let present = base.appendingPathComponent("present", isDirectory: true)
		try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: CLIModelCatalog.modelsDirectory(downloadBase: base).appendingPathComponent("openai_whisper-tiny"),
			withIntermediateDirectories: true)

		let models = [
			CustomWhisperModel(
				id: "custom:mine", displayName: "My Model", source: .localFolder(originalPath: "/x"),
				folderPath: present.path, addedAt: Date()),
			CustomWhisperModel(
				id: "custom:gone", displayName: "Gone", source: .localFolder(originalPath: "/y"),
				folderPath: base.appendingPathComponent("gone").path, addedAt: Date()),
		]
		defaults.set(try JSONEncoder().encode(models), forKey: CustomModelStore.storageKey)

		let available = CLIModelCatalog.availableModels(downloadBase: base, defaults: defaults)
		#expect(available.map(\.id) == ["openai_whisper-tiny", "custom:mine"])
		let custom = try #require(available.last)
		#expect(custom.name == "My Model")
		#expect(custom.engineName == "custom")
		#expect(custom.engine == .customWhisper(folder: present))
		#expect(custom.honorsLanguage)
	}

	@Test func parakeetIgnoresTheLanguageChoice() {
		let model = CLIModel(id: ParakeetModel.v3.rawValue, name: "p", engine: .parakeet(.v3))
		#expect(!model.honorsLanguage)
		#expect(model.engineName == "parakeet")
	}
}

struct CLITextPipelineTests {
	private func configuration() -> TextProcessingConfiguration {
		var configuration = TextProcessingConfiguration()
		configuration.preferredLanguages = ["en-US"]
		return configuration
	}

	@Test func fillerWordsAreRemovedWithTheSelectedLanguage() {
		let pipeline = CLITextPipeline(
			configuration: configuration(), language: .code("en"), translating: false, modelHonorsLanguage: true)
		let output = pipeline.process("Um, so the meeting, uh, starts at three.", modelDetectedLanguage: "en")
		#expect(!output.text.lowercased().contains("um,"))
		#expect(!output.text.lowercased().contains("uh"))
		#expect(output.text.contains("meeting"))
		#expect(output.language == "en")
	}

	@Test func customWordsCorrectCLIOutput() {
		var configuration = configuration()
		configuration.customWords = ["Whispera"]
		let pipeline = CLITextPipeline(
			configuration: configuration, language: .detect, translating: false, modelHonorsLanguage: true)
		#expect(pipeline.process("um so I use whisper a daily", modelDetectedLanguage: "en").text == "so I use Whispera daily")
	}

	@Test func parakeetOutputFallsBackToTextLanguageDetection() {
		let pipeline = CLITextPipeline(
			configuration: configuration(), language: .code("fr"), translating: false, modelHonorsLanguage: false)
		#expect(pipeline.selectedLanguageCode == nil)
		let output = pipeline.process(
			"Um, the quarterly report is ready for review and the team will meet tomorrow morning.",
			modelDetectedLanguage: nil)
		#expect(output.language == "en")
		#expect(!output.text.hasPrefix("Um"))
	}

	@Test func chineseOutputFollowsTheConfiguredScript() {
		var configuration = configuration()
		configuration.chineseScript = .automatic
		configuration.preferredLanguages = ["zh-Hant-TW"]
		let pipeline = CLITextPipeline(
			configuration: configuration, language: .detect, translating: false, modelHonorsLanguage: true)
		#expect(pipeline.process("我们开会", modelDetectedLanguage: "zh").text == "我們開會")
	}

	@Test func translationReportsEnglish() {
		let pipeline = CLITextPipeline(
			configuration: configuration(), language: .code("de"), translating: true, modelHonorsLanguage: true)
		#expect(pipeline.process("Hello there", modelDetectedLanguage: nil).language == "en")
	}
}

@MainActor
struct HeadlessEngineIntegrationTests {
	static let audioURL = HeadlessTranscriberIntegrationTests.audioURL
	static let parakeetDownloaded = ParakeetEngine.isDownloaded(.v3, modelsBase: CLIModelCatalog.defaultDownloadBase)
	static let tinyFolder = CLIModelCatalog.modelsDirectory().appendingPathComponent("openai_whisper-tiny.en")
	static let hasAudio = FileManager.default.fileExists(atPath: audioURL.path)

	private func englishOptions() -> DecodingOptions {
		CLIDecodingSettings.options(
			language: "en", detectLanguage: false, translate: false,
			defaults: UserDefaults(suiteName: UUID().uuidString)!)
	}

	@Test(
		.enabled(if: parakeetDownloaded, "Needs Parakeet v3 downloaded in the app"),
		.enabled(if: hasAudio, "Needs the bundled test recording"),
		.timeLimit(.minutes(10))
	)
	func transcribesWithParakeet() async throws {
		let model = CLIModel(id: ParakeetModel.v3.rawValue, name: "p", engine: .parakeet(.v3))
		let transcriber = try await HeadlessTranscriber(
			model: model, device: CLIComputeDevice.all[0], downloadBase: CLIModelCatalog.defaultDownloadBase,
			verbose: false)
		defer { transcriber.unload() }
		var configuration = TextProcessingConfiguration()
		configuration.customFillerWords = ["education"]
		let pipeline = CLITextPipeline(
			configuration: configuration, language: .code("en"), translating: false, modelHonorsLanguage: false)

		let raw = try await transcriber.run(file: Self.audioURL.path, repeatCount: 1, options: englishOptions())
		let processed = try await transcriber.run(
			file: Self.audioURL.path, repeatCount: 1, options: englishOptions(), pipeline: pipeline)

		#expect(raw.text.lowercased().contains("education"), "Transcript: \(raw.text.prefix(300))")
		// The custom filler word proves the app's text pipeline ran over real engine output
		#expect(!processed.text.lowercased().contains("education"))
		#expect(processed.language == "en")
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: tinyFolder.path), "Needs openai_whisper-tiny.en"),
		.enabled(if: hasAudio, "Needs the bundled test recording"),
		.timeLimit(.minutes(10))
	)
	func transcribesWithAnImportedCustomModel() async throws {
		let model = CLIModel(id: "custom:tiny-copy", name: "Tiny", engine: .customWhisper(folder: Self.tinyFolder))
		let transcriber = try await HeadlessTranscriber(
			model: model, device: CLIComputeDevice.all[0], downloadBase: CLIModelCatalog.defaultDownloadBase,
			verbose: false)

		let run = try await transcriber.run(file: Self.audioURL.path, repeatCount: 1, options: englishOptions())

		#expect(run.text.lowercased().contains("education"), "Transcript: \(run.text.prefix(300))")
		#expect(run.language == "en")
	}

	@Test(.enabled(if: parakeetDownloaded, "Needs Parakeet v3 downloaded in the app"))
	func parakeetRefusesToTranslate() async throws {
		let suite = "HeadlessEngineIntegrationTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let status = await WhisperaCLI.run(
			arguments: ["--transcribe-file", Self.audioURL.path, "--model", ParakeetModel.v3.rawValue, "--translate"],
			defaults: defaults)
		#expect(status == 1)
	}
}
