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
	private var recentPeaks: [Float] = []
	private let peakHistorySize = 60
	private var adaptiveGain: Float = 5.0

	init(bandCount: Int = 7) {
		self.bandCount = bandCount
		self.levels = Array(repeating: 0, count: bandCount)
	}

	var hasAudioActivity: Bool {
		!isSilent && peakLevel > silenceThreshold
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

		var newLevels: [Float] = []
		var maxLevel: Float = 0
		var sum: Float = 0

		for i in 0..<bandCount {
			let start = i * samplesPerBand
			let end = min(start + samplesPerBand, samples.count)

			guard start < samples.count else {
				newLevels.append(0)
				continue
			}

			let band = Array(samples[start..<end])
			let rms = sqrt(band.map { $0 * $0 }.reduce(0, +) / Float(band.count))
			let normalizedLevel = min(1.0, rms * adaptiveGain)

			newLevels.append(normalizedLevel)
			maxLevel = max(maxLevel, rms)
			sum += rms
		}

		levels = newLevels
		peakLevel = maxLevel
		averageLevel = sum / Float(bandCount)

		if maxLevel < silenceThreshold {
			consecutiveSilentFrames += 1
			isSilent = true
		} else {
			consecutiveSilentFrames = 0
			isSilent = false
			updateAdaptiveGain(currentPeak: maxLevel)
		}
	}

	private func updateAdaptiveGain(currentPeak: Float) {
		recentPeaks.append(currentPeak)
		if recentPeaks.count > peakHistorySize {
			recentPeaks.removeFirst()
		}

		guard recentPeaks.count >= 10 else { return }

		let sortedPeaks = recentPeaks.sorted()
		let percentile90 = sortedPeaks[Int(Float(sortedPeaks.count) * 0.9)]

		if percentile90 > 0.001 {
			let targetGain = 0.7 / percentile90
			let clampedGain = max(2.0, min(20.0, targetGain))
			adaptiveGain = adaptiveGain * 0.95 + clampedGain * 0.05
		}
	}

	func reset() {
		levels = Array(repeating: 0, count: bandCount)
		peakLevel = 0
		averageLevel = 0
		isSilent = true
		consecutiveSilentFrames = 0
		recentPeaks.removeAll()
		adaptiveGain = 5.0
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
