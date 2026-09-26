import CoreML
import FluidAudio
import Foundation

// FluidAudio exports its own AppLogger, so this file leaves logging to its callers.

enum VADEngine: String, CaseIterable, Identifiable, Sendable {
	case energy
	case neural

	static let defaultsKey = "vadEngine"
	static let defaultValue = VADEngine.energy

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .energy: return String(localized: "Energy")
		case .neural: return String(localized: "Neural (Silero)")
		}
	}

	static func stored(in defaults: UserDefaults) -> VADEngine {
		defaults.string(forKey: defaultsKey).flatMap(VADEngine.init(rawValue:)) ?? defaultValue
	}
}

extension VADSensitivity {
	/// Speech probability a Silero chunk needs to count as speech.
	var neuralThreshold: Float {
		switch self {
		case .low: return 0.7
		case .medium: return 0.5
		case .high: return 0.3
		}
	}
}

/// Turns per-chunk Silero speech probabilities into the same trim-or-skip decision the
/// energy trimmer makes, so both engines feed the transcription path identically.
struct NeuralVoiceActivityTrimmer: Sendable {
	var sampleRate = 16000
	var chunkSize = VadManager.chunkSize
	var padding: Double = 0.25
	var threshold: Float

	init(sensitivity: VADSensitivity = .medium) {
		threshold = sensitivity.neuralThreshold
	}

	func trim(_ samples: [Float], probabilities: [Float]) -> VoiceActivityResult {
		guard !samples.isEmpty,
			let first = probabilities.firstIndex(where: { $0 >= threshold }),
			let last = probabilities.lastIndex(where: { $0 >= threshold })
		else { return .noSpeech }

		let paddingSamples = Int(Double(sampleRate) * padding)
		let start = max(0, first * chunkSize - paddingSamples)
		let end = min(samples.count, (last + 1) * chunkSize + paddingSamples)
		guard start < end else { return .noSpeech }
		return .speech(Array(samples[start..<end]))
	}
}

/// Silero VAD through FluidAudio, the library that already runs Parakeet. The CoreML model is
/// downloaded once next to the Parakeet models and kept loaded after first use.
actor NeuralVoiceActivityDetector {
	static let shared = NeuralVoiceActivityDetector()

	private var manager: VadManager?
	private var loading: Task<VadManager, Error>?

	static var modelsBase: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera/models/FluidInference", isDirectory: true)
	}

	static var isDownloaded: Bool {
		let model = modelsBase.appendingPathComponent(Repo.vad.folderName)
			.appendingPathComponent(ModelNames.VAD.sileroVadFile)
		return FileManager.default.fileExists(atPath: model.path)
	}

	/// Loads the model, downloading it first when needed.
	@discardableResult
	func prepare() async throws -> VadManager {
		if let manager { return manager }
		if let loading { return try await loading.value }
		let task = Task { () throws -> VadManager in
			let models = try await DownloadUtils.loadModels(
				.vad, modelNames: Array(ModelNames.VAD.requiredModels), directory: Self.modelsBase,
				computeUnits: .cpuAndNeuralEngine)
			guard let model = models[ModelNames.VAD.sileroVadFile] else { throw VadError.modelLoadingFailed }
			return VadManager(config: VadConfig(), vadModel: model)
		}
		loading = task
		do {
			let loaded = try await task.value
			manager = loaded
			loading = nil
			return loaded
		} catch {
			loading = nil
			throw error
		}
	}

	/// One probability per 256 ms chunk of 16 kHz mono audio.
	func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
		let manager = try await prepare()
		return try await manager.process(samples).map(\.probability)
	}

	func process(_ samples: [Float], sensitivity: VADSensitivity) async throws -> VoiceActivityResult {
		guard !samples.isEmpty else { return .noSpeech }
		let probabilities = try await speechProbabilities(samples)
		return NeuralVoiceActivityTrimmer(sensitivity: sensitivity).trim(samples, probabilities: probabilities)
	}
}
