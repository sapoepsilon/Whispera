import Foundation
import Testing

@testable import Whispera

struct VoiceActivityTrimmerTests {
	private let rate = 16000

	private func tone(seconds: Double, amplitude: Float, frequency: Float = 220) -> [Float] {
		let count = Int(Double(rate) * seconds)
		return (0..<count).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(rate)) }
	}

	private func noise(seconds: Double, amplitude: Float) -> [Float] {
		var state: UInt32 = 0x1234_5678
		return (0..<Int(Double(rate) * seconds)).map { _ in
			state = state &* 1_664_525 &+ 1_013_904_223
			return (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude
		}
	}

	@Test func emptyClipHasNoSpeech() {
		#expect(VoiceActivityTrimmer().process([]) == .noSpeech)
	}

	@Test func silentClipHasNoSpeech() {
		#expect(VoiceActivityTrimmer().process(noise(seconds: 2, amplitude: 0.001)) == .noSpeech)
	}

	@Test func steadyHumAboveFloorIsTreatedAsSilence() {
		let hum = tone(seconds: 2, amplitude: 0.02, frequency: 60)
		#expect(
			VoiceActivityTrimmer().process(hum) == .noSpeech,
			"A constant background level has no activity relative to its own noise floor")
	}

	@Test func shortClickIsNotSpeech() {
		let clip = noise(seconds: 1, amplitude: 0.001) + tone(seconds: 0.03, amplitude: 0.5)
			+ noise(seconds: 1, amplitude: 0.001)
		#expect(VoiceActivityTrimmer().process(clip) == .noSpeech)
	}

	@Test func leadingAndTrailingSilenceIsTrimmedWithPadding() throws {
		let speech = tone(seconds: 1, amplitude: 0.2)
		let clip = noise(seconds: 1.5, amplitude: 0.001) + speech + noise(seconds: 1.5, amplitude: 0.001)
		let trimmer = VoiceActivityTrimmer()

		guard case .speech(let trimmed) = trimmer.process(clip) else {
			Issue.record("Expected speech")
			return
		}

		let expected = Double(speech.count) + 2 * trimmer.padding * Double(rate)
		let tolerance = Double(trimmer.frameLength * 2)
		#expect(abs(Double(trimmed.count) - expected) <= tolerance)
		#expect(trimmed.count < clip.count)
	}

	@Test func continuousSpeechWithoutPausesIsNotDropped() {
		guard case .speech(let trimmed) = VoiceActivityTrimmer().process(tone(seconds: 3, amplitude: 0.1))
		else {
			Issue.record("A clip that is speech from start to end must still be transcribed")
			return
		}
		#expect(trimmed.count == 3 * rate)
	}

	@Test func clipThatIsAllSpeechIsKeptWhole() {
		let clip = tone(seconds: 1, amplitude: 0.2) + tone(seconds: 0.2, amplitude: 0.01)
			+ tone(seconds: 1, amplitude: 0.2)
		guard case .speech(let trimmed) = VoiceActivityTrimmer().process(clip) else {
			Issue.record("Expected speech")
			return
		}
		#expect(trimmed.count == clip.count)
	}

	@Test func sensitivityControlsQuietSpeech() {
		let clip = noise(seconds: 1, amplitude: 0.0005) + tone(seconds: 1, amplitude: 0.015)
			+ noise(seconds: 1, amplitude: 0.0005)

		#expect(VoiceActivityTrimmer(sensitivity: .low).process(clip) == .noSpeech)
		if case .speech = VoiceActivityTrimmer(sensitivity: .medium).process(clip) {
		} else {
			Issue.record("Medium sensitivity should keep quiet speech")
		}
		if case .speech = VoiceActivityTrimmer(sensitivity: .high).process(clip) {
		} else {
			Issue.record("High sensitivity should keep quiet speech")
		}
	}

	@Test func settingsDefaultToEnabledMedium() throws {
		let suite = "VoiceActivityTrimmerTests.defaults.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		let settings = VoiceActivitySettings(defaults: defaults)
		#expect(settings.enabled)
		#expect(settings.sensitivity == .medium)
	}

	@Test func settingsReadPersistedValues() throws {
		let suite = "VoiceActivityTrimmerTests.persisted.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		defaults.set(false, forKey: VoiceActivitySettings.enabledKey)
		defaults.set("high", forKey: VoiceActivitySettings.sensitivityKey)

		#expect(VoiceActivitySettings(defaults: defaults) == .init(enabled: false, sensitivity: .high))
	}

	@Test func unknownSensitivityFallsBackToDefault() throws {
		let suite = "VoiceActivityTrimmerTests.unknown.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		defaults.set("extreme", forKey: VoiceActivitySettings.sensitivityKey)
		#expect(VoiceActivitySettings(defaults: defaults).sensitivity == .medium)
	}
}
