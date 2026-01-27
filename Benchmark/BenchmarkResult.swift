import Foundation

struct BenchmarkResult: Codable, Identifiable {
	let id: UUID
	let modelName: String
	let audioFileName: String
	let audioDurationSeconds: Double
	let transcriptionDurationSeconds: Double
	let rtf: Double
	let transcribedText: String
	let timestamp: Date
	let deviceInfo: DeviceInfo

	var formattedRTF: String {
		String(format: "%.3fx", rtf)
	}

	var isRealTime: Bool {
		rtf <= 1.0
	}

	var speedDescription: String {
		if rtf < 0.1 {
			return "Extremely Fast"
		} else if rtf < 0.3 {
			return "Very Fast"
		} else if rtf < 0.5 {
			return "Fast"
		} else if rtf < 1.0 {
			return "Real-time"
		} else if rtf < 2.0 {
			return "Slower than real-time"
		} else {
			return "Slow"
		}
	}

	init(
		modelName: String,
		audioFileName: String,
		audioDurationSeconds: Double,
		transcriptionDurationSeconds: Double,
		transcribedText: String
	) {
		self.id = UUID()
		self.modelName = modelName
		self.audioFileName = audioFileName
		self.audioDurationSeconds = audioDurationSeconds
		self.transcriptionDurationSeconds = transcriptionDurationSeconds
		self.rtf = transcriptionDurationSeconds / audioDurationSeconds
		self.transcribedText = transcribedText
		self.timestamp = Date()
		self.deviceInfo = DeviceInfo.current
	}
}

struct DeviceInfo: Codable {
	let modelIdentifier: String
	let osVersion: String
	let processorCount: Int
	let physicalMemoryGB: Double

	static var current: DeviceInfo {
		var size = 0
		sysctlbyname("hw.model", nil, &size, nil, 0)
		var model = [CChar](repeating: 0, count: size)
		sysctlbyname("hw.model", &model, &size, nil, 0)
		let modelIdentifier = String(cString: model)

		let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
		let processorCount = ProcessInfo.processInfo.processorCount
		let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

		return DeviceInfo(
			modelIdentifier: modelIdentifier,
			osVersion: osVersion,
			processorCount: processorCount,
			physicalMemoryGB: physicalMemory
		)
	}
}

struct BenchmarkSummary: Codable {
	let modelName: String
	let totalAudioDuration: Double
	let totalTranscriptionTime: Double
	let averageRTF: Double
	let minRTF: Double
	let maxRTF: Double
	let fileCount: Int
	let results: [BenchmarkResult]

	var formattedAverageRTF: String {
		String(format: "%.3fx", averageRTF)
	}

	init(modelName: String, results: [BenchmarkResult]) {
		self.modelName = modelName
		self.results = results
		self.fileCount = results.count
		self.totalAudioDuration = results.reduce(0) { $0 + $1.audioDurationSeconds }
		self.totalTranscriptionTime = results.reduce(0) { $0 + $1.transcriptionDurationSeconds }
		self.averageRTF = totalTranscriptionTime / totalAudioDuration
		self.minRTF = results.map(\.rtf).min() ?? 0
		self.maxRTF = results.map(\.rtf).max() ?? 0
	}
}
