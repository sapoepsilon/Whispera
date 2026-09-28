import Foundation
import Testing
import WhisperKit

@testable import Whispera

/// The models the real-WhisperKit suites decode with, as the app downloads them.
///
/// Every suite that uses one also carries `.sharedTranscriber`, so the model suites run one test at
/// a time with each other and with the suites that drive the app's shared transcriber. The small
/// model is loaded once per test process and reused.
///
/// The suites skip when the small model is missing, unless `WHISPERA_REQUIRE_MODEL_TESTS=1` is in
/// the test environment (`TEST_RUNNER_WHISPERA_REQUIRE_MODEL_TESTS=1 xcodebuild test ...`): then
/// they run and fail, so a machine meant to run them cannot pass by skipping.
@MainActor
enum WhisperKitTestModel {
	nonisolated static let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Application Support/Whispera/models/argmaxinc/whisperkit-coreml")

	nonisolated static var requiresModels: Bool {
		ProcessInfo.processInfo.environment["WHISPERA_REQUIRE_MODEL_TESTS"] == "1"
	}

	nonisolated static var smallModelFolder: URL? { folder("openai_whisper-small") }
	nonisolated static var turboModelFolder: URL? { folder("openai_whisper-large-v3_turbo_954MB") }

	/// Whether the small-model suites run: the model is there, or it is required.
	nonisolated static var runsSmallModelTests: Bool { smallModelFolder != nil || requiresModels }

	/// Whether the suites that transcribe through the app's shared transcriber run: some Whisper
	/// model is downloaded for it to load, or models are required.
	nonisolated static var runsAppModelTests: Bool { hasAnyModel || requiresModels }

	private nonisolated static var hasAnyModel: Bool {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
		return names.contains { folder($0) != nil }
	}

	private nonisolated static func folder(_ name: String) -> URL? {
		let folder = modelsDirectory.appendingPathComponent(name)
		return FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
			? folder : nil
	}

	private static var loadedSmall: WhisperKit?

	/// The openai_whisper-small model, built the way the app builds every WhisperKit instance.
	static func small() async throws -> WhisperKit {
		if let loadedSmall { return loadedSmall }
		let folder = try #require(smallModelFolder, "openai_whisper-small is not downloaded in \(modelsDirectory.path)")
		let whisperKit = try await load(folder)
		loadedSmall = whisperKit
		return whisperKit
	}

	/// Loaded for the one test that needs it and released afterwards.
	static func turbo() async throws -> WhisperKit {
		try await load(try #require(turboModelFolder, "openai_whisper-large-v3_turbo_954MB is not downloaded"))
	}

	private static func load(_ folder: URL) async throws -> WhisperKit {
		let whisperKit = try await WhisperKitTranscriber.makeWhisperKit(
			WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false))
		try await whisperKit.loadTokenizerIfNeeded()
		return whisperKit
	}
}
