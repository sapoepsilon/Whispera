import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct NeuralVoiceActivityTrimmerTests {
	private let chunk = 4096

	@Test func trimsToTheSpeechChunksWithPadding() {
		let samples = [Float](repeating: 0.1, count: chunk * 6)
		var trimmer = NeuralVoiceActivityTrimmer(sensitivity: .medium)
		trimmer.padding = 0.1
		let result = trimmer.trim(samples, probabilities: [0.05, 0.1, 0.9, 0.7, 0.2, 0.05])

		guard case .speech(let trimmed) = result else {
			Issue.record("Expected speech, got \(result)")
			return
		}
		let padding = 1600
		#expect(trimmed.count == (4 - 2) * chunk + 2 * padding)
	}

	@Test func quietProbabilitiesMeanNoSpeech() {
		let samples = [Float](repeating: 0.1, count: chunk * 3)
		#expect(
			NeuralVoiceActivityTrimmer(sensitivity: .medium).trim(samples, probabilities: [0.1, 0.4, 0.2]) == .noSpeech)
	}

	@Test func sensitivityMovesTheThreshold() {
		let samples = [Float](repeating: 0.1, count: chunk * 2)
		let probabilities: [Float] = [0.1, 0.4]
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .low).trim(samples, probabilities: probabilities) == .noSpeech)
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .high).trim(samples, probabilities: probabilities) != .noSpeech)
		#expect(VADSensitivity.high.neuralThreshold < VADSensitivity.medium.neuralThreshold)
		#expect(VADSensitivity.medium.neuralThreshold < VADSensitivity.low.neuralThreshold)
	}

	@Test func emptyClipHasNoSpeech() {
		#expect(NeuralVoiceActivityTrimmer().trim([], probabilities: []) == .noSpeech)
	}
}

struct VADEngineSettingsTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "VADEngineSettingsTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToTheEnergyDetector() {
		#expect(VoiceActivitySettings(defaults: makeDefaults()).engine == .energy)
	}

	@Test func readsTheNeuralChoice() {
		let defaults = makeDefaults()
		defaults.set(VADEngine.neural.rawValue, forKey: VADEngine.defaultsKey)
		#expect(VoiceActivitySettings(defaults: defaults).engine == .neural)
		defaults.set("earshot", forKey: VADEngine.defaultsKey)
		#expect(VoiceActivitySettings(defaults: defaults).engine == .energy)
	}
}

/// Runs the real Silero model through FluidAudio; the first run downloads it from Hugging Face.
struct NeuralVoiceActivityModelTests {
	static let speechURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("WhisperaTests/Resources/bush_radio_address.wav")

	private func speech(seconds: Double) throws -> [Float] {
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: Self.speechURL.path)
		return Array(samples.prefix(Int(seconds * 16000)))
	}

	/// Steady hiss well above the energy detector's absolute floor.
	private func hiss(seconds: Double) -> [Float] {
		var generator = SystemRandomNumberGenerator()
		return (0..<Int(seconds * 16000)).map { _ in Float.random(in: -0.05...0.05, using: &generator) }
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func detectsRealSpeech() async throws {
		let clip = try speech(seconds: 8)
		let result = try await NeuralVoiceActivityDetector.shared.process(clip, sensitivity: .medium)
		guard case .speech(let trimmed) = result else {
			Issue.record("Silero found no speech in a real recording")
			return
		}
		#expect(trimmed.count > clip.count / 2)
		#expect(NeuralVoiceActivityDetector.isDownloaded)
	}

	@Test(.timeLimit(.minutes(5)))
	func steadyNoiseIsNotSpeech() async throws {
		let noise = hiss(seconds: 3)
		#expect(try await NeuralVoiceActivityDetector.shared.process(noise, sensitivity: .medium) == .noSpeech)
	}

	/// A notification beep between silences: loud enough for the energy detector, but not a voice.
	@Test(.timeLimit(.minutes(5)))
	func beepIsNotSpeechForTheModelButIsForEnergy() async throws {
		let silence = [Float](repeating: 0, count: 16000)
		let beep = (0..<16000).map { 0.3 * sin(2 * Float.pi * 1000 * Float($0) / 16000) }
		let clip = silence + beep + silence

		#expect(VoiceActivityTrimmer(sensitivity: .medium).process(clip) != .noSpeech)
		#expect(try await NeuralVoiceActivityDetector.shared.process(clip, sensitivity: .medium) == .noSpeech)
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func trimsSilenceAroundSpeech() async throws {
		let clip = try speech(seconds: 4)
		let silence = [Float](repeating: 0, count: 3 * 16000)
		let padded = silence + clip + silence

		let result = try await NeuralVoiceActivityDetector.shared.process(padded, sensitivity: .medium)

		guard case .speech(let trimmed) = result else {
			Issue.record("Silero found no speech in padded speech")
			return
		}
		#expect(trimmed.count < padded.count - 3 * 16000)
		#expect(trimmed.count >= Int(Double(clip.count) * 0.6))
	}
}
