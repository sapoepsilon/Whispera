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
		}
	}
}

/// Loads a downloaded model straight from disk (never downloads) and transcribes files with it.
final class HeadlessTranscriber {
	let model: String
	let device: CLIComputeDevice
	let loadMs: Double
	private let whisperKit: WhisperKit

	init(model: String, device: CLIComputeDevice, downloadBase: URL, verbose: Bool) async throws {
		let folder = CLIModelCatalog.modelsDirectory(downloadBase: downloadBase).appendingPathComponent(model)
		let start = Date()
		let config = WhisperKitConfig(
			model: model,
			downloadBase: downloadBase,
			modelFolder: folder.path,
			computeOptions: device.computeOptions,
			verbose: verbose,
			logLevel: verbose ? .debug : .error,
			prewarm: false,
			load: true,
			download: false
		)
		whisperKit = try await WhisperKit(config)
		self.model = model
		self.device = device
		self.loadMs = Date().timeIntervalSince(start) * 1000
	}

	static func loadSamples(from path: String) throws -> [Float] {
		try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
	}

	func transcribe(samples: [Float], options: DecodingOptions) async throws -> (text: String, language: String) {
		let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
		let text =
			results
			.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
		return (text, results.first?.language ?? options.language ?? "")
	}

	func run(file: String, repeatCount: Int, options: DecodingOptions) async throws -> CLITranscriptionRun {
		let samples = try Self.loadSamples(from: file)
		var timings: [Double] = []
		var last: (text: String, language: String) = ("", "")
		for _ in 0..<max(repeatCount, 1) {
			let start = Date()
			last = try await transcribe(samples: samples, options: options)
			timings.append(Date().timeIntervalSince(start) * 1000)
		}
		return CLITranscriptionRun(
			file: file,
			text: last.text,
			language: last.language,
			audioSeconds: Double(samples.count) / Double(WhisperKit.sampleRate),
			runsMs: timings
		)
	}
}
