import CoreML
import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct CLIOptionsTests {

	@Test(arguments: [
		[String](),
		["-NSDocumentRevisionsDebugMode", "YES"],
		["-ApplePersistenceIgnoreState", "YES"],
		["-psn_0_12345"],
		["--json"],
	])
	func guiLaunchArgumentsDoNotTriggerCLI(arguments: [String]) {
		#expect(!CLIOptions.isCLIInvocation(arguments))
	}

	@Test(arguments: [
		["--transcribe-file", "a.wav"],
		["-f", "a.wav"],
		["--transcribe-file=a.wav"],
		["--list-models"],
		["--list-devices", "--json"],
		["--toggle-transcription"],
		["--cancel"],
		["--help"],
	])
	func cliFlagsTriggerHeadlessMode(arguments: [String]) {
		#expect(CLIOptions.isCLIInvocation(arguments))
	}

	@Test func parsesFullTranscribeInvocation() throws {
		let options = try CLIOptions.parse([
			"-f", "/tmp/a.wav", "--transcribe-file=/tmp/b.wav", "--model", "openai_whisper-tiny.en",
			"--device-index", "3", "--language", "de", "--translate", "--repeat", "4", "--json", "--debug",
		])
		#expect(options.action == .transcribe)
		#expect(options.files == ["/tmp/a.wav", "/tmp/b.wav"])
		#expect(options.model == "openai_whisper-tiny.en")
		#expect(options.deviceIndex == 3)
		#expect(options.language == "de")
		#expect(options.translate)
		#expect(options.repeatCount == 4)
		#expect(options.json)
		#expect(options.debug)
	}

	@Test func parsesListAndRemoteActions() throws {
		#expect(try CLIOptions.parse(["--list-models", "--json"]).action == .listModels)
		#expect(try CLIOptions.parse(["--list-devices"]).action == .listDevices)
		#expect(try CLIOptions.parse(["--toggle-transcription"]).action == .remote(.toggle))
		#expect(try CLIOptions.parse(["--toggle"]).action == .remote(.toggle))
		#expect(try CLIOptions.parse(["--toggle-post-process"]).action == .remote(.togglePostProcess))
		#expect(try CLIOptions.parse(["--start"]).action == .remote(.start))
		#expect(try CLIOptions.parse(["--stop"]).action == .remote(.stop))
		#expect(try CLIOptions.parse(["--cancel"]).action == .remote(.cancel))
		#expect(try CLIOptions.parse(["--cancel", "--help"]).action == .help)
	}

	@Test func skipsLaunchServicesArguments() throws {
		let options = try CLIOptions.parse(["-psn_0_1234", "-NSDocumentRevisionsDebugMode", "YES", "--list-models"])
		#expect(options.action == .listModels)
	}

	@Test func reportsUsageErrors() {
		#expect(throws: CLIOptions.ParseError.missingValue("--transcribe-file")) {
			try CLIOptions.parse(["--transcribe-file"])
		}
		#expect(throws: CLIOptions.ParseError.missingValue("--model")) {
			try CLIOptions.parse(["-f", "a.wav", "--model", "--json"])
		}
		#expect(throws: CLIOptions.ParseError.invalidNumber("--repeat", "0")) {
			try CLIOptions.parse(["-f", "a.wav", "--repeat", "0"])
		}
		#expect(throws: CLIOptions.ParseError.invalidNumber("--device-index", "-1")) {
			try CLIOptions.parse(["-f", "a.wav", "--device-index=-1"])
		}
		#expect(throws: CLIOptions.ParseError.unknownArgument("--bogus")) {
			try CLIOptions.parse(["--list-models", "--bogus"])
		}
		#expect(throws: CLIOptions.ParseError.conflictingActions) {
			try CLIOptions.parse(["--list-models", "--list-devices"])
		}
		#expect(throws: CLIOptions.ParseError.optionNeedsFile("--model")) {
			try CLIOptions.parse(["--list-devices", "--model", "x"])
		}
	}
}

struct CLIComputeDeviceTests {

	@Test func indicesAreContiguousAndUnique() {
		#expect(CLIComputeDevice.all.map(\.index) == Array(0..<CLIComputeDevice.all.count))
		#expect(Set(CLIComputeDevice.all.map(\.id)).count == CLIComputeDevice.all.count)
		#expect(CLIComputeDevice.device(at: nil)?.id == "default")
		#expect(CLIComputeDevice.device(at: 1)?.id == "cpu")
		#expect(CLIComputeDevice.device(at: 99) == nil)
	}

	@Test @MainActor func defaultDeviceMatchesTheAppsComputeOptions() {
		let app = WhisperKitTranscriber.shared.getComputeOptionsStatus()
		let device = CLIComputeDevice.all[0]
		#expect(app["melCompute"] == name(device.mel))
		#expect(app["audioEncoderCompute"] == name(device.encoder))
		#expect(app["textDecoderCompute"] == name(device.decoder))
		#expect(app["prefillCompute"] == name(device.prefill))
	}

	private func name(_ units: MLComputeUnits) -> String {
		switch units {
		case .cpuOnly: return "cpuOnly"
		case .cpuAndGPU: return "cpuAndGPU"
		case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
		case .all: return "all"
		@unknown default: return "unknown"
		}
	}
}

struct CLIModelAndSettingsTests {
	private func isolatedDefaults() throws -> (UserDefaults, String) {
		let suite = "WhisperaCLITests-\(UUID().uuidString)"
		return (try #require(UserDefaults(suiteName: suite)), suite)
	}

	@Test func listsOnlyModelDirectories() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("cli-models-\(UUID().uuidString)")
		let models = CLIModelCatalog.modelsDirectory(downloadBase: base)
		defer { try? FileManager.default.removeItem(at: base) }
		try FileManager.default.createDirectory(
			at: models.appendingPathComponent("openai_whisper-tiny.en"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: models.appendingPathComponent("openai_whisper-base"), withIntermediateDirectories: true)
		try Data().write(to: models.appendingPathComponent("config.json"))

		#expect(CLIModelCatalog.downloadedModels(in: models) == ["openai_whisper-base", "openai_whisper-tiny.en"])
		#expect(CLIModelCatalog.downloadedModels(in: base.appendingPathComponent("missing")) == [])
	}

	@Test func defaultModelPrefersLastUsedThenSelected() throws {
		let (defaults, suite) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		let downloaded = ["a", "b", "c"]

		#expect(CLIModelCatalog.defaultModel(downloaded: downloaded, defaults: defaults) == "a")
		defaults.set("c", forKey: "selectedModel")
		#expect(CLIModelCatalog.defaultModel(downloaded: downloaded, defaults: defaults) == "c")
		defaults.set("b", forKey: "lastUsedModel")
		#expect(CLIModelCatalog.defaultModel(downloaded: downloaded, defaults: defaults) == "b")
		defaults.set("gone", forKey: "lastUsedModel")
		#expect(CLIModelCatalog.defaultModel(downloaded: downloaded, defaults: defaults) == "c")
		#expect(CLIModelCatalog.defaultModel(downloaded: [], defaults: defaults) == nil)
	}

	@Test func resolvesLanguageFromFlagOrAppSetting() throws {
		let (defaults, suite) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(CLIDecodingSettings.resolveLanguage(nil, defaults: defaults) == .code("en"))
		defaults.set("french", forKey: "selectedLanguage")
		#expect(CLIDecodingSettings.resolveLanguage(nil, defaults: defaults) == .code("fr"))
		#expect(CLIDecodingSettings.resolveLanguage("German", defaults: defaults) == .code("de"))
		#expect(CLIDecodingSettings.resolveLanguage("es", defaults: defaults) == .code("es"))
		#expect(CLIDecodingSettings.resolveLanguage("AUTO", defaults: defaults) == .detect)
		#expect(CLIDecodingSettings.resolveLanguage("klingon", defaults: defaults) == nil)
	}

	@Test func storedAutoLanguageDetectsInsteadOfFallingBackToEnglish() throws {
		let (defaults, suite) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }

		defaults.set(Constants.autoDetectLanguageName, forKey: "selectedLanguage")
		#expect(CLIDecodingSettings.resolveLanguage(nil, defaults: defaults) == .detect)
		#expect(CLIDecodingSettings.resolveLanguage(" auto ", defaults: defaults) == .detect)
	}

	@Test func decodingOptionsFollowPersistedAppSettings() throws {
		let (defaults, suite) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }

		let fallback = CLIDecodingSettings.options(language: "en", detectLanguage: false, translate: false, defaults: defaults)
		#expect(fallback.temperature == 0)
		#expect(fallback.temperatureFallbackCount == 1)
		#expect(fallback.sampleLength == 224)
		#expect(fallback.skipSpecialTokens)
		#expect(fallback.task == .transcribe)

		defaults.set(Float(0.4), forKey: "decodingTemperature")
		defaults.set(3, forKey: "decodingTemperatureFallbackCount")
		defaults.set(128, forKey: "decodingSampleLength")
		defaults.set(false, forKey: "decodingSkipSpecialTokens")
		let custom = CLIDecodingSettings.options(language: nil, detectLanguage: true, translate: true, defaults: defaults)
		#expect(custom.temperature == Float(0.4))
		#expect(custom.temperatureFallbackCount == 3)
		#expect(custom.sampleLength == 128)
		#expect(!custom.skipSpecialTokens)
		#expect(custom.task == .translate)
		#expect(custom.detectLanguage == true)
		#expect(custom.language == nil)
	}

	@Test func reportEncodesHandyStyleKeys() throws {
		let run = CLITranscriptionRun(
			file: "a.wav", text: "hello", language: "en", audioSeconds: 10, runsMs: [900, 500, 700])
		#expect(run.bestMs == 500)
		#expect(abs(run.rtf - 0.05) < 0.0001)

		let report = CLITranscriptionReport(model: "m", device: "default", loadMs: 12, results: [run])
		let data = try JSONEncoder().encode(report)
		let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(json["model"] as? String == "m")
		#expect(json["load_ms"] as? Double == 12)
		let first = try #require((json["results"] as? [[String: Any]])?.first)
		#expect(first["best_ms"] as? Double == 500)
		#expect(first["runs_ms"] as? [Double] == [900, 500, 700])
		#expect(first["audio_seconds"] as? Double == 10)
		#expect(first["rtf"] as? Double != nil)
		#expect(try JSONDecoder().decode(CLITranscriptionReport.self, from: data) == report)
	}
}

struct HeadlessTranscriberIntegrationTests {
	static let audioURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("WhisperaTests/Resources/bush_radio_address.wav")

	static var smallestDownloadedModel: String? {
		let models = CLIModelCatalog.downloadedModels()
		return models.first { $0.contains("tiny") } ?? models.first { $0.contains("base") }
	}

	@Test(
		.enabled(if: smallestDownloadedModel != nil, "Needs a downloaded tiny or base model"),
		.enabled(if: FileManager.default.fileExists(atPath: audioURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5))
	)
	@MainActor
	func transcribesRealAudioWithoutTheAppSingleton() async throws {
		let model = try #require(Self.smallestDownloadedModel)
		let transcriber = try await HeadlessTranscriber(
			model: CLIModel(
				id: model, name: model,
				engine: .whisperKit(folder: CLIModelCatalog.modelsDirectory().appendingPathComponent(model))),
			device: CLIComputeDevice.all[0], downloadBase: CLIModelCatalog.defaultDownloadBase,
			verbose: false)
		let options = CLIDecodingSettings.options(
			language: "en", detectLanguage: false, translate: false, defaults: UserDefaults(suiteName: UUID().uuidString)!)

		let run = try await transcriber.run(file: Self.audioURL.path, repeatCount: 2, options: options)

		#expect(run.runsMs.count == 2)
		#expect(run.audioSeconds > 200 && run.audioSeconds < 240)
		#expect(run.bestMs > 0)
		#expect(run.text.lowercased().contains("education"), "Transcript: \(run.text.prefix(300))")
	}
}

struct CLIRemoteURLTests {
	private func makeContext() throws -> (UserDefaults, String, URL) {
		let suite = "CLIRemoteURLTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
		return (defaults, suite, directory)
	}

	@MainActor
	@Test func micCommandsCarryTheTokenAndTheAppAcceptsThem() throws {
		let (defaults, suite, directory) = try makeContext()
		defer {
			defaults.removePersistentDomain(forName: suite)
			try? FileManager.default.removeItem(at: directory)
		}
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)

		let url = try WhisperaCLI.remoteURL(for: .toggle, defaults: defaults, tokenDirectory: directory)
		let token = try #require(RemoteControlToken.load(in: directory, createIfMissing: false))
		#expect(RemoteCommand.token(in: url) == token)
		let center = RemoteControlCenter(defaults: defaults, tokenDirectory: directory)
		#expect(center.authorizeURL(.toggle, url: url) == .allowed)
	}

	@Test func stopAndCancelWorkWithURLControlOffButStartDoesNot() throws {
		let (defaults, suite, directory) = try makeContext()
		defer {
			defaults.removePersistentDomain(forName: suite)
			try? FileManager.default.removeItem(at: directory)
		}

		#expect(try WhisperaCLI.remoteURL(for: .stop, defaults: defaults, tokenDirectory: directory) == RemoteCommand.stop.url)
		#expect(try WhisperaCLI.remoteURL(for: .cancel, defaults: defaults, tokenDirectory: directory) == RemoteCommand.cancel.url)
		#expect(throws: CLIRemoteError.self) {
			try WhisperaCLI.remoteURL(for: .start, defaults: defaults, tokenDirectory: directory)
		}
	}

	@Test func invocationLogNameOmitsFilePaths() throws {
		let options = try CLIOptions.parse(["-f", "/Users/someone/private/interview.wav"])
		#expect(options.action.logName == "transcribe")
		#expect(!options.action.logName.contains("interview"))
	}
}
