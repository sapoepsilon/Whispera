import CoreML
import FluidAudio
import Foundation

extension ParakeetModel {
	fileprivate var version: AsrModelVersion {
		switch self {
		case .v3: return .v3
		case .v2: return .v2
		}
	}

	fileprivate var repo: Repo {
		switch self {
		case .v3: return .parakeet
		case .v2: return .parakeetV2
		}
	}
}

/// Parakeet TDT running on CoreML through FluidAudio. Models live next to the WhisperKit ones
/// under `<modelsBase>/models/FluidInference/`.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
	let model: ParakeetModel
	private let manager: AsrManager

	var modelID: String { model.rawValue }

	private init(model: ParakeetModel, manager: AsrManager) {
		self.model = model
		self.manager = manager
	}

	nonisolated static func directory(for model: ParakeetModel, modelsBase: URL) -> URL {
		modelsBase
			.appendingPathComponent("models/FluidInference", isDirectory: true)
			.appendingPathComponent(model.repo.folderName, isDirectory: true)
	}

	nonisolated static func isDownloaded(_ model: ParakeetModel, modelsBase: URL) -> Bool {
		AsrModels.modelsExist(at: directory(for: model, modelsBase: modelsBase), version: model.version)
	}

	static func download(_ model: ParakeetModel, modelsBase: URL) async throws {
		try await AsrModels.download(
			to: directory(for: model, modelsBase: modelsBase), version: model.version)
	}

	static func load(_ model: ParakeetModel, modelsBase: URL, computeUnits: MLComputeUnits?)
		async throws -> ParakeetEngine
	{
		let configuration: MLModelConfiguration? = computeUnits.map { units in
			let configuration = AsrModels.defaultConfiguration()
			configuration.computeUnits = units
			return configuration
		}
		let models = try await AsrModels.load(
			from: directory(for: model, modelsBase: modelsBase),
			configuration: configuration,
			version: model.version
		)
		let manager = AsrManager(config: .default)
		try await manager.initialize(models: models)
		return ParakeetEngine(model: model, manager: manager)
	}

	func transcribe(samples: [Float]) async throws -> EngineTranscript {
		let result = try await manager.transcribe(samples, source: .microphone)
		return Self.transcript(from: result)
	}

	func transcribe(fileURL: URL) async throws -> EngineTranscript {
		let result = try await manager.transcribe(fileURL, source: .system)
		return Self.transcript(from: result)
	}

	func unload() {
		manager.cleanup()
	}

	private static func transcript(from result: ASRResult) -> EngineTranscript {
		let tokens = (result.tokenTimings ?? []).map {
			TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
		}
		var segments = TranscriptSegmenter.segments(from: tokens)
		let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
		if segments.isEmpty, !text.isEmpty {
			segments = [TranscriptionSegment(text: text, startTime: 0, endTime: result.duration)]
		}
		return EngineTranscript(text: text, segments: segments)
	}
}
