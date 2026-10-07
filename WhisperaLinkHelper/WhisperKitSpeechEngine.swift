import Foundation
import LinkHelperCore
import WhisperKit

/// The Mac voice server's engine: the Whisper model the user already downloaded in Whispera, run
/// by WhisperKit inside the helper so phones can transcribe while Whispera itself is quit.
///
/// Never downloads anything: with no installed model it reports none and the voice server answers
/// `model_not_ready`. The model loads on the first request and unloads after five idle minutes.
final class WhisperKitSpeechEngine: LocalSpeechEngine, @unchecked Sendable {
	static let idleUnload: TimeInterval = 300
	private static let preferred = [
		"openai_whisper-small", "openai_whisper-small.en", "openai_whisper-base", "openai_whisper-base.en",
		"openai_whisper-large-v3-v20240930", "openai_whisper-large-v3_turbo", "openai_whisper-tiny",
		"openai_whisper-tiny.en",
	]

	private let base: URL
	private let modelsRoot: URL
	private let explicitModel: String?
	private let appDomain: String
	var engineName: String { "WhisperKit" }
	private let runner = Runner()

	init(appDomain: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
		self.appDomain = environment["WHISPERA_LINK_APP_DEFAULTS"].flatMap { $0.isEmpty ? nil : $0 } ?? appDomain
		let support =
			FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		base =
			environment["WHISPERA_LINK_STT_MODELS_BASE"].map { URL(fileURLWithPath: $0) }
			?? support.appendingPathComponent("Whispera")
		modelsRoot = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
		explicitModel = environment["WHISPERA_LINK_STT_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
	}

	private func isInstalled(_ name: String) -> Bool {
		let folder = modelsRoot.appendingPathComponent(name)
		return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
			FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
		}
	}

	/// The app's chosen model when it is a WhisperKit model on disk, else the first installed one.
	func currentModel() -> String? {
		if let explicitModel { return isInstalled(explicitModel) ? explicitModel : nil }
		CFPreferencesAppSynchronize(appDomain as CFString)
		for key in ["selectedModel", "lastUsedModel"] {
			if let name = CFPreferencesCopyAppValue(key as CFString, appDomain as CFString) as? String,
				!name.contains("/"), isInstalled(name)
			{ return name }
		}
		if let name = Self.preferred.first(where: isInstalled) { return name }
		let installed = (try? FileManager.default.contentsOfDirectory(atPath: modelsRoot.path)) ?? []
		return installed.sorted().first(where: isInstalled)
	}

	func modelIDs() -> [String] { currentModel().map { [$0] } ?? [] }

	func transcribe(samples: [Float], language: String?, prompt: String?, temperature: Float?) async throws
		-> LocalTranscript
	{
		guard let model = currentModel() else {
			throw APIError(503, "model_not_ready", SpeechService.noModelReady)
		}
		let config = WhisperKitConfig(
			model: model, downloadBase: base, modelFolder: modelsRoot.appendingPathComponent(model).path,
			tokenizerFolder: base,
			verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
		var options = DecodingOptions(
			verbose: false, task: .transcribe, language: language, temperature: temperature ?? 0,
			usePrefillPrompt: language != nil, detectLanguage: language == nil, skipSpecialTokens: true,
			withoutTimestamps: false)
		options.chunkingStrategy = .vad
		return try await runner.run(
			model: model, config: config, samples: samples, options: options, prompt: prompt)
	}

	/// One WhisperKit at a time, reused between requests and dropped when idle.
	private actor Runner {
		private var kit: WhisperKit?
		private var loadedModel: String?
		private var lastUse = Date()
		private var unloadTask: Task<Void, Never>?

		func run(
			model: String, config: WhisperKitConfig, samples: [Float], options: DecodingOptions, prompt: String?
		)
			async throws -> LocalTranscript
		{
			unloadTask?.cancel()
			if loadedModel != model || kit == nil {
				kit = nil
				kit = try await WhisperKit(config)
				loadedModel = model
			}
			guard let kit else {
				throw APIError(503, "model_not_ready", "The speech model on the Mac did not load.")
			}
			var decoding = options
			if let prompt, let tokenizer = kit.tokenizer {
				decoding.promptTokens = tokenizer.encode(text: " " + prompt).filter {
					$0 < tokenizer.specialTokens.specialTokenBegin
				}
			}
			let results = try await kit.transcribe(audioArray: samples, decodeOptions: decoding)
			lastUse = Date()
			scheduleUnload()
			let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
			let segments = results.flatMap(\.segments).map {
				LocalTranscript.Segment(
					start: Double($0.start), end: Double($0.end), text: Self.clean($0.text))
			}
			return LocalTranscript(text: text, language: results.first?.language, segments: segments)
		}

		private func scheduleUnload() {
			unloadTask = Task { [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(WhisperKitSpeechEngine.idleUnload * 1_000_000_000))
				guard !Task.isCancelled else { return }
				await self?.unloadIfIdle()
			}
		}

		private func unloadIfIdle() {
			guard Date().timeIntervalSince(lastUse) >= WhisperKitSpeechEngine.idleUnload else { return }
			kit = nil
			loadedModel = nil
		}

		private static func clean(_ text: String) -> String {
			text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}
}
