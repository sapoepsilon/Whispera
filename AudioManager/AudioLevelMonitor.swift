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
			let normalizedLevel = min(1.0, rms * 5.0)

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
		}
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
