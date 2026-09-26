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

enum ParakeetLoadError: LocalizedError, Equatable {
	case notDownloaded(String)
	case invalidVocabulary

	var errorDescription: String? {
		switch self {
		case .notDownloaded(let name):
			return String(localized: "\(name) is not downloaded. Download it again in Settings.")
		case .invalidVocabulary:
			return String(localized: "The Parakeet vocabulary file is damaged.")
		}
	}
}

/// Replaces a model folder with a fresh download without ever leaving the user with nothing: the
/// old folder is moved aside first and moved back if the download fails (offline, disk full).
enum ModelFolderRepair {
	static func replace(_ folder: URL, download: () async throws -> Void) async throws {
		let fileManager = FileManager.default
		let backup = folder.deletingLastPathComponent()
			.appendingPathComponent(".\(folder.lastPathComponent).previous-\(UUID().uuidString)", isDirectory: true)
		let hadFolder = fileManager.fileExists(atPath: folder.path)
		if hadFolder {
			try fileManager.moveItem(at: folder, to: backup)
		}
		do {
			try await download()
		} catch {
			if hadFolder {
				try? fileManager.removeItem(at: folder)
				do {
					try fileManager.moveItem(at: backup, to: folder)
				} catch {
					AppLogger.shared.transcriber.error("Could not restore model folder \(folder.path): \(error)")
				}
			}
			throw error
		}
		if hadFolder {
			try? fileManager.removeItem(at: backup)
		}
	}
}

/// Parakeet TDT running on CoreML through FluidAudio. Models live next to the WhisperKit ones
/// under `<modelsBase>/models/FluidInference/`.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
	/// FluidAudio rejects anything shorter than one second at 16 kHz.
	nonisolated static let minimumSampleCount = 16_000

	let model: ParakeetModel
	private let manager: AsrManager
	/// `AsrManager` keeps decoder state across its awaits and resets it after every call, so two
	/// overlapping transcriptions (a dictation plus a history re-transcribe, say) would corrupt each other.
	private let calls = SerialAsyncQueue()

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

	/// Loads straight from disk. FluidAudio's own loader deletes the whole 460 MB model after any
	/// load error, even a transient one while offline, so it is never used here. A model that still
	/// fails after a retry is re-downloaded only when `repairIfCorrupt` is set, and the old copy is
	/// put back if that download fails.
	static func load(
		_ model: ParakeetModel, modelsBase: URL, computeUnits: MLComputeUnits?, repairIfCorrupt: Bool = true
	) async throws -> ParakeetEngine {
		let configuration = AsrModels.defaultConfiguration()
		if let computeUnits {
			configuration.computeUnits = computeUnits
		}
		let directory = directory(for: model, modelsBase: modelsBase)
		guard isDownloaded(model, modelsBase: modelsBase) else {
			throw ParakeetLoadError.notDownloaded(model.displayName)
		}

		let models: AsrModels
		do {
			models = try await loadFromDisk(directory, configuration: configuration, version: model.version)
		} catch {
			AppLogger.shared.transcriber.error("Parakeet load failed, retrying once: \(error)")
			do {
				models = try await loadFromDisk(directory, configuration: configuration, version: model.version)
			} catch {
				guard repairIfCorrupt else { throw error }
				AppLogger.shared.transcriber.error(
					"Parakeet model still fails to load, downloading a fresh copy: \(error)")
				try await ModelFolderRepair.replace(directory) {
					try await download(model, modelsBase: modelsBase)
				}
				models = try await loadFromDisk(directory, configuration: configuration, version: model.version)
			}
		}
		let manager = AsrManager(config: .default)
		try await manager.initialize(models: models)
		return ParakeetEngine(model: model, manager: manager)
	}

	/// Mirrors FluidAudio's per-model compute units: the preprocessor always runs on the CPU.
	private static func loadFromDisk(
		_ directory: URL, configuration: MLModelConfiguration, version: AsrModelVersion
	) async throws -> AsrModels {
		typealias Names = ModelNames.ASR
		func load(_ name: String, units: MLComputeUnits) async throws -> MLModel {
			let config = MLModelConfiguration()
			config.computeUnits = units
			config.allowLowPrecisionAccumulationOnGPU = true
			return try await MLModel.load(contentsOf: directory.appendingPathComponent(name), configuration: config)
		}
		let preprocessor = try await load(Names.preprocessorFile, units: .cpuOnly)
		let encoder = try await load(Names.encoderFile, units: configuration.computeUnits)
		let decoder = try await load(Names.decoderFile, units: configuration.computeUnits)
		let joint = try await load(Names.jointFile, units: configuration.computeUnits)
		return AsrModels(
			encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
			configuration: configuration,
			vocabulary: try vocabulary(at: directory.appendingPathComponent(Names.vocabularyFile)),
			version: version)
	}

	nonisolated static func vocabulary(at url: URL) throws -> [Int: String] {
		let data = try Data(contentsOf: url)
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
			throw ParakeetLoadError.invalidVocabulary
		}
		var vocabulary: [Int: String] = [:]
		for (key, value) in object {
			if let id = Int(key) { vocabulary[id] = value }
		}
		guard !vocabulary.isEmpty else { throw ParakeetLoadError.invalidVocabulary }
		return vocabulary
	}

	func transcribe(samples: [Float]) async throws -> EngineTranscript {
		try await transcribe(samples, source: .microphone)
	}

	func transcribe(fileURL: URL) async throws -> EngineTranscript {
		let samples = try await Task.detached(priority: .userInitiated) {
			try AudioConverter().resampleAudioFile(fileURL)
		}.value
		return try await transcribe(samples, source: .system)
	}

	private func transcribe(_ samples: [Float], source: AudioSource) async throws -> EngineTranscript {
		let manager = manager
		let padded = Self.paddedToMinimumLength(samples)
		let result = try await calls.run {
			try await manager.transcribe(padded, source: source)
		}
		return Self.transcript(from: result)
	}

	/// Trailing silence lets a short word such as "yes" or "ok" through the one-second minimum
	/// without changing what the model hears.
	nonisolated static func paddedToMinimumLength(_ samples: [Float]) -> [Float] {
		guard samples.count < minimumSampleCount else { return samples }
		return samples + [Float](repeating: 0, count: minimumSampleCount - samples.count)
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
