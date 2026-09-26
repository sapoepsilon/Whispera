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
///
/// A single chunk over the threshold is not enough: Silero scores steady white hiss anywhere
/// from 0.1 to 0.98 chunk by chunk, so one lucky chunk used to turn a noise-only clip into
/// "speech" (measured: 13 of 30 three-second hiss clips). Chunks are grouped with Silero's own
/// hysteresis into segments, and a segment only counts when its loudness rises and falls the
/// way syllables do. Stationary noise stays within about 10% of its own level from frame to
/// frame, while even a single short word in background noise swings by several times.
struct NeuralVoiceActivityTrimmer: Sendable {
	var sampleRate = 16000
	var chunkSize = VadManager.chunkSize
	var padding: Double = 0.25
	var threshold: Float
	/// Once a segment has started it continues until the probability falls this far below
	/// `threshold`, matching Silero's recommended `neg_threshold = threshold - 0.15`.
	var hysteresis: Float = 0.15
	var frameDuration: Double = 0.02
	/// Ratio between the loud (90th percentile) and quiet (10th percentile) 20 ms frames a
	/// segment needs before it counts as speech.
	var minimumLoudnessSwing: Float = 1.6

	init(sensitivity: VADSensitivity = .medium) {
		threshold = sensitivity.neuralThreshold
	}

	/// Chunk ranges Silero considers one continuous stretch of speech.
	func segments(_ probabilities: [Float]) -> [Range<Int>] {
		let release = max(threshold - hysteresis, 0.01)
		var segments: [Range<Int>] = []
		var start: Int?
		for (index, probability) in probabilities.enumerated() {
			if let open = start {
				if probability < release {
					segments.append(open..<index)
					start = nil
				}
			} else if probability >= threshold {
				start = index
			}
		}
		if let open = start { segments.append(open..<probabilities.count) }
		return segments
	}

	/// How much the 20 ms loudness varies across `samples`; `.infinity` when part of it is silent.
	func loudnessSwing(_ samples: ArraySlice<Float>) -> Float {
		let frameLength = max(1, Int(Double(sampleRate) * frameDuration))
		var levels: [Float] = []
		levels.reserveCapacity(samples.count / frameLength + 1)
		var start = samples.startIndex
		while start + frameLength <= samples.endIndex {
			var sum: Float = 0
			for sample in samples[start..<(start + frameLength)] { sum += sample * sample }
			levels.append((sum / Float(frameLength)).squareRoot())
			start += frameLength
		}
		guard levels.count >= 2 else { return 0 }
		levels.sort()
		let quiet = levels[Int(Double(levels.count - 1) * 0.1)]
		let loud = levels[Int(Double(levels.count - 1) * 0.9)]
		guard loud > 0 else { return 0 }
		guard quiet > 1e-6 else { return .infinity }
		return loud / quiet
	}

	func trim(_ samples: [Float], probabilities: [Float]) -> VoiceActivityResult {
		guard !samples.isEmpty else { return .noSpeech }
		let speech = segments(probabilities).filter { segment in
			let start = min(samples.count, segment.lowerBound * chunkSize)
			let end = min(samples.count, segment.upperBound * chunkSize)
			return start < end && loudnessSwing(samples[start..<end]) >= minimumLoudnessSwing
		}
		guard let first = speech.first, let last = speech.last else { return .noSpeech }

		let paddingSamples = Int(Double(sampleRate) * padding)
		let start = max(0, first.lowerBound * chunkSize - paddingSamples)
		let end = min(samples.count, last.upperBound * chunkSize + paddingSamples)
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
