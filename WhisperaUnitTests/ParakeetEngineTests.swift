import CoreML
import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct ParakeetModelTests {

	@Test func recognisesParakeetIDs() {
		#expect(ParakeetModel.isParakeetID("parakeet-tdt-0.6b-v3"))
		#expect(ParakeetModel.isParakeetID("parakeet-tdt-0.6b-v2"))
		#expect(!ParakeetModel.isParakeetID("openai_whisper-base"))
		#expect(!ParakeetModel.isParakeetID("custom:parakeet-tdt-0.6b-v3"))
	}

	@MainActor
	@Test func standardModelDetectionExcludesOtherEngines() {
		#expect(WhisperKitTranscriber.isStandardWhisperKitModel("openai_whisper-small.en"))
		#expect(!WhisperKitTranscriber.isStandardWhisperKitModel("parakeet-tdt-0.6b-v3"))
		#expect(!WhisperKitTranscriber.isStandardWhisperKitModel("custom:foo"))
	}

	@MainActor
	@Test func displayNamesComeFromTheModel() {
		#expect(
			WhisperKitTranscriber.getModelDisplayName(for: "parakeet-tdt-0.6b-v3")
				== ParakeetModel.v3.displayName)
		#expect(WhisperKitTranscriber.getModelDisplayName(for: "parakeet-tdt-0.6b-v2").contains("English"))
	}

	@Test func modelsLiveUnderWhisperaModelsFolder() {
		let base = URL(fileURLWithPath: "/tmp/WhisperaBase")
		#expect(
			ParakeetEngine.directory(for: .v3, modelsBase: base).path
				== "/tmp/WhisperaBase/models/FluidInference/parakeet-tdt-0.6b-v3-coreml")
		#expect(
			ParakeetEngine.directory(for: .v2, modelsBase: base).lastPathComponent
				== "parakeet-tdt-0.6b-v2-coreml")
		#expect(!ParakeetEngine.isDownloaded(.v3, modelsBase: base))
	}
}

struct TranscriptSegmenterTests {

	private func tokens(_ spec: [(String, Double, Double)]) -> [TimedToken] {
		spec.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) }
	}

	@Test func emptyInputYieldsNoSegments() {
		#expect(TranscriptSegmenter.segments(from: []).isEmpty)
	}

	@Test func joinsSubwordPiecesAndSplitsOnSentenceEnd() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([
				(" Hel", 0.0, 0.2), ("lo", 0.2, 0.4), (" there.", 0.4, 0.8),
				(" How", 1.0, 1.2), (" are", 1.2, 1.4), (" you?", 1.4, 1.8),
			]))
		#expect(segments.map(\.text) == ["Hello there.", "How are you?"])
		#expect(segments.map(\.startTime) == [0.0, 1.0])
		#expect(segments.map(\.endTime) == [0.8, 1.8])
	}

	@Test func splitsOnLongPauses() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([(" one", 0, 0.3), (" two", 3.0, 3.3)]), pauseThreshold: 1.0)
		#expect(segments.map(\.text) == ["one", "two"])
	}

	@Test func doesNotSplitInsideAWord() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([(" Dr.", 0, 0.3), ("ive", 5.0, 5.3)]), pauseThreshold: 1.0)
		#expect(segments.map(\.text) == ["Dr.ive"])
	}

	@Test func capsSegmentDuration() {
		let words = (0..<10).map { (" w\($0)", Double($0), Double($0) + 0.5) }
		let segments = TranscriptSegmenter.segments(from: tokens(words), maxSegmentDuration: 4)
		#expect(segments.count == 3)
		#expect(segments.first?.text == "w0 w1 w2 w3")
	}
}

/// Real Parakeet transcription through FluidAudio. Runs when the v3 model is already downloaded, or when
/// WHISPERA_PARAKEET_E2E=1 (TEST_RUNNER_WHISPERA_PARAKEET_E2E=1 via xcodebuild) allows downloading it.
@MainActor
struct ParakeetTranscriptionTests {

	nonisolated static let modelsBase = FileManager.default.urls(
		for: .applicationSupportDirectory, in: .userDomainMask
	)[0].appendingPathComponent("Whispera", isDirectory: true)

	nonisolated static var enabled: Bool {
		ParakeetEngine.isDownloaded(.v3, modelsBase: modelsBase)
			|| ProcessInfo.processInfo.environment["WHISPERA_PARAKEET_E2E"] == "1"
	}

	@Test(.enabled(if: enabled, "Parakeet v3 not downloaded; set WHISPERA_PARAKEET_E2E=1"))
	func transcribesSpeechFromFileAndSamples() async throws {
		if !ParakeetEngine.isDownloaded(.v3, modelsBase: Self.modelsBase) {
			try await ParakeetEngine.download(.v3, modelsBase: Self.modelsBase)
		}
		let engine = try await ParakeetEngine.load(
			.v3, modelsBase: Self.modelsBase, computeUnits: nil)
		defer { engine.unload() }

		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetE2E-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make(
			"The quick brown fox jumps over the lazy dog. Then it runs into the forest.", in: directory)

		let fromFile = try await engine.transcribe(fileURL: audio)
		let lowered = fromFile.text.lowercased()
		#expect(lowered.contains("fox"))
		#expect(lowered.contains("forest"))
		#expect(!fromFile.segments.isEmpty)
		#expect((fromFile.segments.last?.endTime ?? 0) > 1)

		let cpuEngine = try await ParakeetEngine.load(
			.v3, modelsBase: Self.modelsBase, computeUnits: .cpuOnly)
		defer { cpuEngine.unload() }
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
		let fromSamples = try await cpuEngine.transcribe(samples: samples)
		#expect(fromSamples.text.lowercased().contains("fox"))
	}
}
