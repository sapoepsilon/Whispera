import CoreML
import Foundation
import WhisperKit

enum ComputeUnitPreference: String, CaseIterable, Identifiable, Sendable {
	case automatic
	case cpuOnly
	case gpu
	case neuralEngine

	static let storageKey = "computeUnitPreference"

	var id: String { rawValue }

	static func load(from defaults: UserDefaults = .standard) -> ComputeUnitPreference {
		guard let raw = defaults.string(forKey: storageKey) else { return .automatic }
		return ComputeUnitPreference(rawValue: raw) ?? .automatic
	}

	func save(to defaults: UserDefaults = .standard) {
		defaults.set(rawValue, forKey: Self.storageKey)
	}

	var displayName: String {
		switch self {
		case .automatic: return "Automatic"
		case .cpuOnly: return "CPU"
		case .gpu: return "GPU"
		case .neuralEngine: return "Neural Engine"
		}
	}

	var summary: String {
		switch self {
		case .automatic:
			return
				"Audio processing on CPU + GPU, text decoding on CPU + Neural Engine. Best for most Apple Silicon Macs."
		case .cpuOnly:
			return "Everything runs on the CPU. Slowest, but avoids GPU and Neural Engine issues."
		case .gpu:
			return "Every stage runs on CPU + GPU."
		case .neuralEngine:
			return "Every stage runs on CPU + Neural Engine. Lowest power use on Apple Silicon."
		}
	}

	var whisperKitComputeOptions: ModelComputeOptions {
		switch self {
		case .automatic:
			return ModelComputeOptions(
				melCompute: .cpuAndGPU,
				audioEncoderCompute: .cpuAndGPU,
				textDecoderCompute: .cpuAndNeuralEngine,
				prefillCompute: .cpuAndGPU
			)
		case .cpuOnly:
			return Self.uniform(.cpuOnly)
		case .gpu:
			return Self.uniform(.cpuAndGPU)
		case .neuralEngine:
			return Self.uniform(.cpuAndNeuralEngine)
		}
	}

	/// nil lets FluidAudio apply its own per-model defaults (preprocessor on CPU, the rest on the Neural Engine).
	var parakeetComputeUnits: MLComputeUnits? {
		switch self {
		case .automatic: return nil
		case .cpuOnly: return .cpuOnly
		case .gpu: return .cpuAndGPU
		case .neuralEngine: return .cpuAndNeuralEngine
		}
	}

	private static func uniform(_ units: MLComputeUnits) -> ModelComputeOptions {
		ModelComputeOptions(
			melCompute: units,
			audioEncoderCompute: units,
			textDecoderCompute: units,
			prefillCompute: units
		)
	}
}
