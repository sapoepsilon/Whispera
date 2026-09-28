import Accelerate
import Foundation
import WhisperKit

enum VADSensitivity: String, CaseIterable, Identifiable, Sendable {
	case low
	case medium
	case high

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .low: return String(localized: "Low")
		case .medium: return String(localized: "Medium")
		case .high: return String(localized: "High")
		}
	}

	/// Minimum RMS energy a frame needs to count as speech. Higher sensitivity
	/// means a lower floor, so quieter speech survives.
	var energyFloor: Float {
		switch self {
		case .low: return 0.02
		case .medium: return 0.008
		case .high: return 0.003
		}
	}
}

struct VoiceActivitySettings: Equatable, Sendable {
	static let enabledKey = "vadEnabled"
	static let sensitivityKey = "vadSensitivity"
	/// On for new installs. Installs that predate Skip Silence keep it off (see UpgradeDefaults),
	/// because a quiet microphone would otherwise start losing dictations after an update.
	static let defaultEnabled = true
	static let defaultSensitivity = VADSensitivity.medium

	/// Shown in the menu bar when a clip is dropped, naming the setting responsible.
	static var noSpeechNotice: String {
		String(
			localized:
				"No speech detected - clip skipped. Skip Silence (Settings > General > Microphone) drops clips it hears as silence; if you did speak, raise Speech Sensitivity or turn Skip Silence off."
		)
	}

	var enabled: Bool
	var sensitivity: VADSensitivity
	var engine: VADEngine

	init(
		enabled: Bool = defaultEnabled, sensitivity: VADSensitivity = defaultSensitivity,
		engine: VADEngine = .defaultValue
	) {
		self.enabled = enabled
		self.sensitivity = sensitivity
		self.engine = engine
	}

	init(defaults: UserDefaults) {
		enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled
		sensitivity =
			defaults.string(forKey: Self.sensitivityKey).flatMap(VADSensitivity.init(rawValue:))
			?? Self.defaultSensitivity
		engine = VADEngine.stored(in: defaults)
	}
}

enum VoiceActivityResult: Equatable, Sendable {
	case speech([Float])
	case noSpeech
}

/// Energy-based voice activity detection for push-to-talk clips: trims leading and
/// trailing silence and reports clips with no speech so they are never sent to
/// Whisper, which hallucinates text ("Thank you.", "you") on silent input.
struct VoiceActivityTrimmer: Sendable {
	var sampleRate: Int = WhisperKit.sampleRate
	var frameDuration: Double = 0.03
	var padding: Double = 0.25
	var minimumSpeechDuration: Double = 0.12
	var energyFloor: Float = VADSensitivity.medium.energyFloor
	/// A frame must be this many times louder than the clip's own noise floor, so a
	/// steady fan or hum at a level above `energyFloor` still reads as silence.
	var noiseFloorMultiplier: Float = 2.5
	/// Caps the adaptive threshold at a multiple of `energyFloor`. Without it a clip
	/// that is almost all speech has a speech-level "noise floor" and gets dropped.
	var maximumFloorMultiple: Float = 4

	init(sensitivity: VADSensitivity = .medium) {
		energyFloor = sensitivity.energyFloor
	}

	var frameLength: Int { max(1, Int(Double(sampleRate) * frameDuration)) }

	func frameEnergies(_ samples: [Float]) -> [Float] {
		samples.withUnsafeBufferPointer(frameEnergies)
	}

	/// The RMS energy of each frame, read in place so a long window costs no copies.
	func frameEnergies(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
		let length = frameLength
		var energies: [Float] = []
		guard let base = samples.baseAddress else { return energies }
		energies.reserveCapacity(samples.count / length + 1)
		var start = 0
		while start < samples.count {
			let end = min(start + length, samples.count)
			var energy: Float = 0
			vDSP_rmsqv(base + start, 1, &energy, vDSP_Length(end - start))
			energies.append(energy)
			start = end
		}
		return energies
	}

	func threshold(for energies: [Float]) -> Float {
		guard !energies.isEmpty else { return energyFloor }
		let sorted = energies.sorted()
		let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.1)]
		let adaptive = min(noiseFloor * noiseFloorMultiplier, energyFloor * maximumFloorMultiple)
		return max(energyFloor, adaptive)
	}

	/// The same decision as `process`, without copying the speech out.
	func hasSpeech(_ samples: ArraySlice<Float>) -> Bool {
		samples.withUnsafeBufferPointer { pointer in
			let energies = frameEnergies(pointer)
			guard !energies.isEmpty else { return false }
			let cutoff = threshold(for: energies)
			let activeFrames = energies.lazy.filter { $0 > cutoff }.count
			return activeFrames > 0 && Double(activeFrames) * frameDuration >= minimumSpeechDuration
		}
	}

	func process(_ samples: [Float]) -> VoiceActivityResult {
		guard !samples.isEmpty else { return .noSpeech }

		let energies = frameEnergies(samples)
		let cutoff = threshold(for: energies)
		let activity = energies.map { $0 > cutoff }

		guard let first = activity.firstIndex(of: true),
			let last = activity.lastIndex(of: true)
		else { return .noSpeech }

		let activeFrames = activity.lazy.filter { $0 }.count
		guard Double(activeFrames) * frameDuration >= minimumSpeechDuration else { return .noSpeech }

		let paddingSamples = Int(Double(sampleRate) * padding)
		let start = max(0, first * frameLength - paddingSamples)
		let end = min(samples.count, (last + 1) * frameLength + paddingSamples)
		return .speech(Array(samples[start..<end]))
	}
}
