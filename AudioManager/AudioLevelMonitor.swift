import Foundation

@MainActor
@Observable
final class AudioLevelMonitor {
	private(set) var levels: [Float]
	private(set) var peakLevel: Float = 0
	private(set) var averageLevel: Float = 0
	private(set) var isSilent: Bool = true
	private(set) var consecutiveSilentFrames: Int = 0

	private let bandCount: Int
	private let silenceThreshold: Float = 0.001
	// dB span mapped onto the 0...1 visual range below the adaptive ceiling
	private let dynamicRangeDb: Float = 40
	// the ceiling itself maps below 1.0 so ordinary speech, which hovers near
	// its own recent peak in the log domain, doesn't pin the meters at max
	private let headroomDb: Float = 8
	// Rolling estimate of how loud "loud" is for the current mic, in dB.
	// Mics differ wildly in sensitivity (AirPods report far hotter RMS than
	// the built-in mic), so a fixed scale either pins the meters or flatlines
	// them. The ceiling jumps up as soon as it is exceeded and decays slowly,
	// and is deliberately NOT reset between recordings so calibration sticks.
	private var ceilingDb: Float = -25

	init(bandCount: Int = 7) {
		self.bandCount = bandCount
		self.levels = Array(repeating: 0, count: bandCount)
	}

	var hasAudioActivity: Bool {
		!isSilent && peakLevel > silenceThreshold
	}

	// normalized 0...1 loudness suitable for driving visuals; the loudest
	// band tracks speech far better than the average, which dilutes bursts
	var overallLevel: Float {
		levels.max() ?? 0
	}

	var microphoneStatus: MicrophoneStatus {
		if consecutiveSilentFrames > 50 {
			return .blocked
		} else if isSilent {
			return .silent
		} else {
			return .active
		}
	}

	func update(from samples: [Float]) {
		guard !samples.isEmpty else {
			markSilent()
			return
		}

		let samplesPerBand = max(1, samples.count / bandCount)

		var bandRms: [Float] = []
		var maxLevel: Float = 0
		var sum: Float = 0

		for i in 0..<bandCount {
			let start = i * samplesPerBand
			let end = min(start + samplesPerBand, samples.count)

			guard start < samples.count else {
				bandRms.append(0)
				continue
			}

			let band = Array(samples[start..<end])
			let rms = sqrt(band.map { $0 * $0 }.reduce(0, +) / Float(band.count))

			bandRms.append(rms)
			maxLevel = max(maxLevel, rms)
			sum += rms
		}

		peakLevel = maxLevel
		averageLevel = sum / Float(bandCount)

		if maxLevel < silenceThreshold {
			consecutiveSilentFrames += 1
			isSilent = true
		} else {
			consecutiveSilentFrames = 0
			isSilent = false
			updateCeiling(peakDb: decibels(maxLevel))
		}

		levels = bandRms.map(normalizedLevel)
	}

	private func updateCeiling(peakDb: Float) {
		if peakDb > ceilingDb {
			ceilingDb = min(0, ceilingDb + (peakDb - ceilingDb) * 0.5)
		} else {
			ceilingDb = max(-45, ceilingDb + (peakDb - ceilingDb) * 0.005)
		}
	}

	private func normalizedLevel(_ rms: Float) -> Float {
		let floorDb = ceilingDb - dynamicRangeDb
		let linear = min(1, max(0, (decibels(rms) - floorDb) / (dynamicRangeDb + headroomDb)))
		// squaring expands the top of the range: speech chunks cluster within
		// a few dB of each other, and without expansion they all read as max
		return linear * linear
	}

	private func decibels(_ rms: Float) -> Float {
		20 * log10(max(rms, 1e-7))
	}

	func reset() {
		levels = Array(repeating: 0, count: bandCount)
		peakLevel = 0
		averageLevel = 0
		isSilent = true
		consecutiveSilentFrames = 0
	}

	private func markSilent() {
		consecutiveSilentFrames += 1
		isSilent = true
		peakLevel = 0
		averageLevel = 0
	}
}

enum MicrophoneStatus: String, CustomStringConvertible {
	case active = "Active"
	case silent = "Silent"
	case blocked = "Blocked (no audio)"

	var description: String { rawValue }
}
