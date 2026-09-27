import CoreML
import Foundation
import WhisperKit

/// macOS has one GPU and one Neural Engine, so "devices" here are CoreML compute-unit
/// presets rather than Handy's GPU registry indices.
struct CLIComputeDevice: Equatable {
	let index: Int
	let id: String
	let summary: String
	let mel: MLComputeUnits
	let encoder: MLComputeUnits
	let decoder: MLComputeUnits
	let prefill: MLComputeUnits

	var computeOptions: ModelComputeOptions {
		ModelComputeOptions(
			melCompute: mel, audioEncoderCompute: encoder, textDecoderCompute: decoder, prefillCompute: prefill)
	}

	static let all: [CLIComputeDevice] = [
		CLIComputeDevice(
			index: 0, id: "default", summary: "App default: encoder on GPU, decoder on Neural Engine",
			mel: .cpuAndGPU, encoder: .cpuAndGPU, decoder: .cpuAndNeuralEngine, prefill: .cpuAndGPU),
		CLIComputeDevice(
			index: 1, id: "cpu", summary: "CPU only",
			mel: .cpuOnly, encoder: .cpuOnly, decoder: .cpuOnly, prefill: .cpuOnly),
		CLIComputeDevice(
			index: 2, id: "gpu", summary: "CPU and GPU",
			mel: .cpuAndGPU, encoder: .cpuAndGPU, decoder: .cpuAndGPU, prefill: .cpuAndGPU),
		CLIComputeDevice(
			index: 3, id: "ane", summary: "CPU and Neural Engine",
			mel: .cpuAndNeuralEngine, encoder: .cpuAndNeuralEngine, decoder: .cpuAndNeuralEngine,
			prefill: .cpuAndNeuralEngine),
		CLIComputeDevice(
			index: 4, id: "all", summary: "Let CoreML choose among CPU, GPU and Neural Engine",
			mel: .all, encoder: .all, decoder: .all, prefill: .all),
	]

	static func device(at index: Int?) -> CLIComputeDevice? {
		let resolved = index ?? 0
		return all.first { $0.index == resolved }
	}
}

/// A model the CLI can load: a stock WhisperKit download, an imported or Hugging Face custom
/// Whisper model, or a Parakeet model, all read from where the app keeps them.
struct CLIModel: Equatable {
	enum Engine: Equatable {
		case whisperKit(folder: URL)
		case customWhisper(folder: URL)
		case parakeet(ParakeetModel)
	}

	let id: String
	let name: String
	let engine: Engine

	var engineName: String {
		switch engine {
		case .whisperKit: return "whisperkit"
		case .customWhisper: return "custom"
		case .parakeet: return "parakeet"
		}
	}

	/// Parakeet picks the language itself and cannot translate.
	var honorsLanguage: Bool {
		if case .parakeet = engine { return false }
		return true
	}
}

enum CLIModelCatalog {
	/// The app's WhisperKit downloadBase; tokenizers are cached under it too.
	static var defaultDownloadBase: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera")
	}

	static func modelsDirectory(downloadBase: URL = defaultDownloadBase) -> URL {
		downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
	}

	static func downloadedModels(in directory: URL = modelsDirectory()) -> [String] {
		let contents =
			(try? FileManager.default.contentsOfDirectory(
				at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
		return
			contents
			.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
			.map(\.lastPathComponent)
			.sorted()
	}

	/// Custom models the app registered whose folders still exist. Read straight from the app's
	/// defaults so the CLI never instantiates the app's model store.
	static func customModels(defaults: UserDefaults) -> [CustomWhisperModel] {
		guard let data = defaults.data(forKey: CustomModelStore.storageKey),
			let models = try? JSONDecoder().decode([CustomWhisperModel].self, from: data)
		else { return [] }
		return models.filter { FileManager.default.fileExists(atPath: $0.folderPath) }
	}

	static func availableModels(downloadBase: URL = defaultDownloadBase, defaults: UserDefaults) -> [CLIModel] {
		let whisperKitDirectory = modelsDirectory(downloadBase: downloadBase)
		let whisperKit = downloadedModels(in: whisperKitDirectory).map {
			CLIModel(
				id: $0, name: $0,
				engine: .whisperKit(folder: whisperKitDirectory.appendingPathComponent($0, isDirectory: true)))
		}
		let parakeet = ParakeetModel.allCases
			.filter { ParakeetEngine.isDownloaded($0, modelsBase: downloadBase) }
			.map { CLIModel(id: $0.rawValue, name: $0.rawValue, engine: .parakeet($0)) }
		let custom = customModels(defaults: defaults).map {
			CLIModel(id: $0.id, name: $0.displayName, engine: .customWhisper(folder: $0.folderURL))
		}
		return whisperKit + parakeet + custom
	}

	/// Same preference order the app uses when it auto-loads a model at launch.
	static func defaultModel(downloaded: [String], defaults: UserDefaults) -> String? {
		for key in ["lastUsedModel", "selectedModel"] {
			if let name = defaults.string(forKey: key), downloaded.contains(name) {
				return name
			}
		}
		return downloaded.first
	}
}

enum CLIDecodingSettings {
	/// Mirrors WhisperKitTranscriber's persisted decoding options so the CLI transcribes
	/// the way the app does, without instantiating the app's singleton (which auto-loads a model).
	static func options(language: String?, detectLanguage: Bool, translate: Bool, defaults: UserDefaults)
		-> DecodingOptions
	{
		func bool(_ key: String, _ fallback: Bool) -> Bool {
			defaults.object(forKey: key) as? Bool ?? fallback
		}
		let fallbackCount = defaults.integer(forKey: "decodingTemperatureFallbackCount")
		let sampleLength = defaults.integer(forKey: "decodingSampleLength")
		return DecodingOptions(
			verbose: false,
			task: translate ? .translate : .transcribe,
			language: language,
			temperature: defaults.float(forKey: "decodingTemperature"),
			temperatureFallbackCount: fallbackCount == 0 ? 1 : fallbackCount,
			sampleLength: sampleLength == 0 ? 224 : sampleLength,
			usePrefillPrompt: bool("decodingUsePrefillPrompt", true),
			usePrefillCache: bool("decodingUsePrefillCache", true),
			detectLanguage: detectLanguage,
			skipSpecialTokens: bool("decodingSkipSpecialTokens", true),
			withoutTimestamps: bool("decodingWithoutTimestamps", false),
			wordTimestamps: bool("decodingWordTimestamps", true),
			clipTimestamps: [0]
		)
	}

	enum LanguageChoice: Equatable {
		case code(String)
		case detect
	}

	static func resolveLanguage(_ input: String?, defaults: UserDefaults) -> LanguageChoice? {
		guard let input else {
			let stored = defaults.string(forKey: "selectedLanguage") ?? Constants.defaultLanguageName
			return choice(forLanguageName: stored)
		}
		guard let name = RemoteCommand.resolveLanguageName(input) else { return nil }
		return choice(forLanguageName: name)
	}

	private static func choice(forLanguageName name: String) -> LanguageChoice {
		Constants.decodingLanguageCode(for: name).map(LanguageChoice.code) ?? .detect
	}
}

struct CLITranscriptionRun: Codable, Equatable {
	let file: String
	let text: String
	let language: String
	let audioSeconds: Double
	let runsMs: [Double]

	var bestMs: Double { runsMs.min() ?? 0 }
	/// Real-time factor of the fastest run: processing time over audio time, lower is faster.
	var rtf: Double { audioSeconds > 0 ? (bestMs / 1000) / audioSeconds : 0 }

	enum CodingKeys: String, CodingKey {
		case file, text, language
		case audioSeconds = "audio_seconds"
		case runsMs = "runs_ms"
		case bestMs = "best_ms"
		case rtf
	}

	init(file: String, text: String, language: String, audioSeconds: Double, runsMs: [Double]) {
		self.file = file
		self.text = text
		self.language = language
		self.audioSeconds = audioSeconds
		self.runsMs = runsMs
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		file = try container.decode(String.self, forKey: .file)
		text = try container.decode(String.self, forKey: .text)
		language = try container.decode(String.self, forKey: .language)
		audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
		runsMs = try container.decode([Double].self, forKey: .runsMs)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(file, forKey: .file)
		try container.encode(text, forKey: .text)
		try container.encode(language, forKey: .language)
		try container.encode(audioSeconds, forKey: .audioSeconds)
		try container.encode(runsMs, forKey: .runsMs)
		try container.encode(bestMs, forKey: .bestMs)
		try container.encode(rtf, forKey: .rtf)
	}
}

struct CLITranscriptionReport: Codable, Equatable {
	let model: String
	let device: String
	let loadMs: Double
	let results: [CLITranscriptionRun]

	enum CodingKeys: String, CodingKey {
		case model, device, results
		case loadMs = "load_ms"
	}
}

enum HeadlessTranscriberError: LocalizedError {
	case noModelsDownloaded
	case modelNotDownloaded(String, available: [String])
	case unknownDevice(Int)
	case unknownLanguage(String)
	case translationUnsupported(String)

	var errorDescription: String? {
		switch self {
		case .noModelsDownloaded:
			return "No models are downloaded. Download one in Whispera Settings first."
		case .modelNotDownloaded(let model, let available):
			return "Model \(model) is not downloaded. Available: \(available.joined(separator: ", "))"
		case .unknownDevice(let index):
			return "No compute device with index \(index). See --list-devices."
		case .unknownLanguage(let language):
			return "Unknown language: \(language)"
		case .translationUnsupported(let model):
			return "\(model) cannot translate. Use a Whisper model with --translate."
		}
	}
}

/// Runs the app's transcript text pipeline (filler words, custom words, Chinese script)
/// over CLI output, with the same language evidence rules as the app.
struct CLITextPipeline {
	let configuration: TextProcessingConfiguration
	/// nil when the language is detected, or when the engine ignores the language choice.
	let selectedLanguageCode: String?
	let translating: Bool

	init(
		configuration: TextProcessingConfiguration, language: CLIDecodingSettings.LanguageChoice,
		translating: Bool, modelHonorsLanguage: Bool
	) {
		self.configuration = configuration
		self.translating = translating
		if modelHonorsLanguage, case .code(let code) = language {
			selectedLanguageCode = code
		} else {
			selectedLanguageCode = nil
		}
	}

	func process(_ text: String, modelDetectedLanguage: String?) -> (text: String, language: String) {
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: selectedLanguageCode, translating: translating,
			modelDetectedLanguage: modelDetectedLanguage, text: text)
		let processed =
			text.isEmpty ? text : TranscriptTextProcessor(configuration: configuration).process(text, language: evidence)
		return (processed, modelDetectedLanguage ?? evidence.languageCode ?? "")
	}
}

/// Loads a downloaded model straight from disk (never downloads) and transcribes files with it.
@MainActor
final class HeadlessTranscriber {
	private enum Backend {
		case whisperKit(WhisperKit)
		case parakeet(ParakeetEngine)
	}

	let model: CLIModel
	let device: CLIComputeDevice
	let loadMs: Double
	private let backend: Backend

	init(model: CLIModel, device: CLIComputeDevice, downloadBase: URL, verbose: Bool) async throws {
		let start = Date()
		switch model.engine {
		case .whisperKit(let folder), .customWhisper(let folder):
			let isStock: Bool
			if case .whisperKit = model.engine { isStock = true } else { isStock = false }
			let config = WhisperKitConfig(
				model: isStock ? model.id : nil,
				downloadBase: downloadBase,
				modelFolder: folder.path,
				computeOptions: device.computeOptions,
				verbose: verbose,
				logLevel: verbose ? .debug : .error,
				prewarm: false,
				load: true,
				download: false
			)
			backend = .whisperKit(try await WhisperKitTranscriber.makeWhisperKit(config))
		case .parakeet(let parakeet):
			// Device 0 keeps the app's own Parakeet placement; the others pin the encoder's units
			let units = device.index == 0 ? ComputeUnitPreference.load().parakeetComputeUnits : device.encoder
			backend = .parakeet(
				try await ParakeetEngine.load(
					parakeet, modelsBase: downloadBase, computeUnits: units, repairIfCorrupt: false))
		}
		self.model = model
		self.device = device
		self.loadMs = Date().timeIntervalSince(start) * 1000
	}

	func unload() {
		if case .parakeet(let engine) = backend { engine.unload() }
	}

	static func loadSamples(from path: String) throws -> [Float] {
		try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
	}

	/// Adds the custom-word decoder prompt the app uses, when that bias is on.
	func decodingOptions(_ base: DecodingOptions, defaults: UserDefaults) -> DecodingOptions {
		guard case .whisperKit(let whisperKit) = backend,
			TextProcessingSettings.biasDecodingWithCustomWords(from: defaults),
			let prompt = TextProcessingSettings.decoderPrompt(for: TextProcessingSettings.customWords(from: defaults)),
			let tokenizer = whisperKit.tokenizer
		else { return base }
		let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
		var options = base
		options.promptTokens = tokens.isEmpty ? nil : tokens
		return WhisperKitTranscriber.promptSafeDecodingOptions(options)
	}

	/// The language is nil when the engine does not report one.
	func transcribe(samples: [Float], options: DecodingOptions) async throws -> (text: String, language: String?) {
		switch backend {
		case .whisperKit(let whisperKit):
			let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
			let text =
				results
				.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
				.joined(separator: " ")
			return (text, results.first?.language ?? options.language)
		case .parakeet(let engine):
			return (try await engine.transcribe(samples: samples).text, nil)
		}
	}

	func run(
		file: String, repeatCount: Int, options: DecodingOptions, pipeline: CLITextPipeline? = nil
	) async throws -> CLITranscriptionRun {
		let samples = try Self.loadSamples(from: file)
		var timings: [Double] = []
		var last: (text: String, language: String?) = ("", nil)
		for _ in 0..<max(repeatCount, 1) {
			let start = Date()
			last = try await transcribe(samples: samples, options: options)
			timings.append(Date().timeIntervalSince(start) * 1000)
		}
		let output: (text: String, language: String) =
			pipeline?.process(last.text, modelDetectedLanguage: last.language) ?? (last.text, last.language ?? "")
		return CLITranscriptionRun(
			file: file,
			text: output.text,
			language: output.language,
			audioSeconds: Double(samples.count) / Double(WhisperKit.sampleRate),
			runsMs: timings
		)
	}
}
