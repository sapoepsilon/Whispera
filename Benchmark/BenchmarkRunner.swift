import AVFoundation
import Foundation

@MainActor
class BenchmarkRunner: ObservableObject {
	@Published var isRunning = false
	@Published var currentProgress: Double = 0
	@Published var currentFile: String = ""
	@Published var results: [BenchmarkResult] = []
	@Published var error: String?
	@Published var savedBenchmarks: [BenchmarkSummary] = []

	private let transcriber: WhisperKitTranscriber

	private var benchmarksDirectory: URL? {
		guard let appSupport = FileManager.default.urls(
			for: .applicationSupportDirectory, in: .userDomainMask
		).first else { return nil }
		return appSupport.appendingPathComponent("Whispera/benchmarks")
	}

	init(transcriber: WhisperKitTranscriber = .shared) {
		self.transcriber = transcriber
		loadSavedBenchmarks()
	}

	private func ensureBenchmarksDirectory() -> URL? {
		guard let dir = benchmarksDirectory else { return nil }
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func runBenchmark(
		audioFiles: [URL],
		modelName: String? = nil
	) async -> BenchmarkSummary? {
		guard !audioFiles.isEmpty else {
			error = "No audio files provided"
			return nil
		}

		let model = modelName ?? transcriber.currentModel ?? "unknown"

		guard transcriber.isInitialized else {
			error = "WhisperKit not initialized"
			return nil
		}

		guard transcriber.isCurrentModelLoaded() else {
			error = "No model loaded"
			return nil
		}

		isRunning = true
		results = []
		error = nil
		currentProgress = 0

		var benchmarkResults: [BenchmarkResult] = []
		let totalFiles = audioFiles.count

		for (index, audioURL) in audioFiles.enumerated() {
			currentFile = audioURL.lastPathComponent
			currentProgress = Double(index) / Double(totalFiles)

			AppLogger.shared.general.info("Benchmarking file \(index + 1)/\(totalFiles): \(audioURL.lastPathComponent)")

			do {
				let result = try await benchmarkSingleFile(audioURL: audioURL, modelName: model)
				benchmarkResults.append(result)
				results.append(result)

				AppLogger.shared.general.info(
					"RTF for \(audioURL.lastPathComponent): \(result.formattedRTF) (\(result.speedDescription))"
				)
			} catch {
				AppLogger.shared.general.error("Failed to benchmark \(audioURL.lastPathComponent): \(error)")
				self.error = "Failed to benchmark \(audioURL.lastPathComponent): \(error.localizedDescription)"
			}
		}

		currentProgress = 1.0
		isRunning = false

		guard !benchmarkResults.isEmpty else {
			error = "No successful benchmarks"
			return nil
		}

		let summary = BenchmarkSummary(modelName: model, results: benchmarkResults)
		AppLogger.shared.general.info("Benchmark complete. Average RTF: \(summary.formattedAverageRTF)")

		return summary
	}

	private func benchmarkSingleFile(audioURL: URL, modelName: String) async throws -> BenchmarkResult {
		let audioDuration = try await getAudioDuration(audioURL)

		let startTime = CFAbsoluteTimeGetCurrent()
		let transcribedText = try await transcriber.transcribe(
			audioURL: audioURL,
			enableTranslation: false
		)
		let endTime = CFAbsoluteTimeGetCurrent()

		let transcriptionDuration = endTime - startTime

		return BenchmarkResult(
			modelName: modelName,
			audioFileName: audioURL.lastPathComponent,
			audioDurationSeconds: audioDuration,
			transcriptionDurationSeconds: transcriptionDuration,
			transcribedText: transcribedText
		)
	}

	private func getAudioDuration(_ url: URL) async throws -> Double {
		let asset = AVAsset(url: url)
		let duration = try await asset.load(.duration)
		return CMTimeGetSeconds(duration)
	}

	func saveBenchmark(_ summary: BenchmarkSummary) -> Bool {
		guard let dir = ensureBenchmarksDirectory() else { return false }

		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601

		guard let data = try? encoder.encode(summary) else { return false }

		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let timestamp = dateFormatter.string(from: Date())

		let fileName = "benchmark_\(summary.modelName)_\(timestamp).json"
		let fileURL = dir.appendingPathComponent(fileName)

		do {
			try data.write(to: fileURL)
			AppLogger.shared.general.info("Saved benchmark to: \(fileURL.path)")
			loadSavedBenchmarks()
			return true
		} catch {
			AppLogger.shared.general.error("Failed to save benchmark: \(error)")
			return false
		}
	}

	func loadSavedBenchmarks() {
		guard let dir = benchmarksDirectory,
			  FileManager.default.fileExists(atPath: dir.path) else {
			savedBenchmarks = []
			return
		}

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601

		do {
			let files = try FileManager.default.contentsOfDirectory(
				at: dir,
				includingPropertiesForKeys: [.creationDateKey],
				options: [.skipsHiddenFiles]
			).filter { $0.pathExtension == "json" }
			.sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }

			savedBenchmarks = files.compactMap { url in
				guard let data = try? Data(contentsOf: url),
					  let summary = try? decoder.decode(BenchmarkSummary.self, from: data) else {
					return nil
				}
				return summary
			}
			AppLogger.shared.general.info("Loaded \(savedBenchmarks.count) saved benchmarks")
		} catch {
			AppLogger.shared.general.error("Failed to load benchmarks: \(error)")
			savedBenchmarks = []
		}
	}

	func deleteBenchmark(at index: Int) {
		guard index < savedBenchmarks.count,
			  let dir = benchmarksDirectory else { return }

		let summary = savedBenchmarks[index]
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

		do {
			let files = try FileManager.default.contentsOfDirectory(
				at: dir,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			).filter { $0.pathExtension == "json" && $0.lastPathComponent.contains(summary.modelName) }

			for file in files {
				try FileManager.default.removeItem(at: file)
			}
			loadSavedBenchmarks()
		} catch {
			AppLogger.shared.general.error("Failed to delete benchmark: \(error)")
		}
	}

	func exportResults(summary: BenchmarkSummary) -> URL? {
		guard let dir = ensureBenchmarksDirectory() else { return nil }

		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601

		guard let data = try? encoder.encode(summary) else {
			return nil
		}

		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let timestamp = dateFormatter.string(from: Date())

		let fileName = "benchmark_\(summary.modelName)_\(timestamp).json"
		let fileURL = dir.appendingPathComponent(fileName)

		do {
			try data.write(to: fileURL)
			return fileURL
		} catch {
			AppLogger.shared.general.error("Failed to export benchmark results: \(error)")
			return nil
		}
	}

	func generateReport(summary: BenchmarkSummary) -> String {
		var report = """
		# Whispera RTF Benchmark Report

		## Summary
		- **Model**: \(summary.modelName)
		- **Files Tested**: \(summary.fileCount)
		- **Total Audio Duration**: \(formatDuration(summary.totalAudioDuration))
		- **Total Transcription Time**: \(formatDuration(summary.totalTranscriptionTime))
		- **Average RTF**: \(summary.formattedAverageRTF)
		- **Min RTF**: \(String(format: "%.3fx", summary.minRTF))
		- **Max RTF**: \(String(format: "%.3fx", summary.maxRTF))

		## Device Info
		- **Model**: \(summary.results.first?.deviceInfo.modelIdentifier ?? "Unknown")
		- **OS**: \(summary.results.first?.deviceInfo.osVersion ?? "Unknown")
		- **Processors**: \(summary.results.first?.deviceInfo.processorCount ?? 0)
		- **Memory**: \(String(format: "%.1f GB", summary.results.first?.deviceInfo.physicalMemoryGB ?? 0))

		## Individual Results

		| File | Duration | Transcription Time | RTF | Speed |
		|------|----------|-------------------|-----|-------|
		"""

		for result in summary.results {
			report += "\n| \(result.audioFileName) | \(formatDuration(result.audioDurationSeconds)) | \(formatDuration(result.transcriptionDurationSeconds)) | \(result.formattedRTF) | \(result.speedDescription) |"
		}

		report += "\n\n---\n*Generated by Whispera Benchmark*"

		return report
	}

	private func formatDuration(_ seconds: Double) -> String {
		if seconds < 60 {
			return String(format: "%.2fs", seconds)
		} else if seconds < 3600 {
			let minutes = Int(seconds) / 60
			let secs = seconds.truncatingRemainder(dividingBy: 60)
			return String(format: "%dm %.2fs", minutes, secs)
		} else {
			let hours = Int(seconds) / 3600
			let minutes = (Int(seconds) % 3600) / 60
			let secs = seconds.truncatingRemainder(dividingBy: 60)
			return String(format: "%dh %dm %.2fs", hours, minutes, secs)
		}
	}
}
