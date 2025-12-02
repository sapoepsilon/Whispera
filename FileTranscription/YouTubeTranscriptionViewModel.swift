import Foundation
import OSLog
import SwiftUI

@MainActor
@Observable
class YouTubeTranscriptionViewModel {

	// MARK: - UI State
	var inputURL: String = ""
	var videoInfo: YouTubeVideoInfo?
	var isLoadingVideoInfo: Bool = false
	var isTranscribing: Bool = false
	var transcriptionProgress: Double = 0.0
	var transcriptionResult: String = ""
	var transcriptionSegments: [TranscriptionSegment] = []
	var error: FileTranscriptionError?
	var showingError: Bool = false

	// MARK: - Segment Selection
	var isSegmentMode: Bool = false
	var selectedStartTime: Double = 0.0
	var selectedEndTime: Double = 0.0
	var customStartTime: String = "0:00"
	var customEndTime: String = "5:00"

	// MARK: - Settings
	@ObservationIgnored @AppStorage("youtubeQuality") private var youtubeQuality: String = "medium"
	@ObservationIgnored @AppStorage("autoDeleteDownloadedFiles") private
		var autoDeleteDownloadedFiles: Bool = true
	@ObservationIgnored @AppStorage("showTimestamps") var showTimestamps: Bool = true
	@ObservationIgnored @AppStorage("timestampFormat") private var timestampFormat: String = "MM:SS"
	@ObservationIgnored @AppStorage("defaultTranscriptionMode") private var defaultTranscriptionMode: String = "plain"

	// MARK: - Dependencies
	private let youtubeTranscriptionManager: YouTubeTranscriptionManager
	private let logger = Logger(
		subsystem: Bundle.main.bundleIdentifier ?? "Whispera", category: "YouTubeTranscriptionViewModel"
	)

	// MARK: - Private State
	private var currentTask: Task<Void, Never>?

	init(youtubeTranscriptionManager: YouTubeTranscriptionManager) {
		self.youtubeTranscriptionManager = youtubeTranscriptionManager
	}

	// MARK: - Public Methods

	func validateAndLoadVideoInfo() {
		guard !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			clearVideoInfo()
			return
		}

		guard let url = URL(string: inputURL.trimmingCharacters(in: .whitespacesAndNewlines)),
			isValidYouTubeURL(url)
		else {
			showError(FileTranscriptionError.transcriptionFailed("Invalid YouTube URL: \(inputURL)"))
			return
		}

		loadVideoInfo(for: url)
	}

	func loadVideoInfo(for url: URL) {
		guard !isLoadingVideoInfo else { return }

		logger.info("Loading video info for: \(url.absoluteString)")
		isLoadingVideoInfo = true
		error = nil

		currentTask = Task {
			do {
				let info = try await youtubeTranscriptionManager.getVideoInfo(url)

				videoInfo = info
				selectedEndTime = min(info.duration, 300.0)  // Default to 5 minutes or video duration
				customEndTime = formatTime(selectedEndTime)

				logger.info("Loaded video info: '\(info.title)', duration: \(info.duration)s")

			} catch {
				logger.error("Failed to load video info: \(error.localizedDescription)")

				let fileError: FileTranscriptionError
				if let existingError = error as? FileTranscriptionError {
					fileError = existingError
				} else {
					fileError = FileTranscriptionError.transcriptionFailed(
						"Network error: \(error.localizedDescription)")
				}
				showError(fileError)
			}

			isLoadingVideoInfo = false
		}
	}

	func startTranscription() {
		guard let url = URL(string: inputURL.trimmingCharacters(in: .whitespacesAndNewlines)),
			isValidYouTubeURL(url)
		else {
			showError(FileTranscriptionError.transcriptionFailed("Invalid YouTube URL: \(inputURL)"))
			return
		}

		guard !isTranscribing else {
			logger.warning("Transcription already in progress")
			return
		}

		logger.info("Starting YouTube transcription")
		isTranscribing = true
		transcriptionProgress = 0.0
		transcriptionResult = ""
		transcriptionSegments = []
		error = nil

		currentTask = Task {
			await performTranscription(for: url)
		}
	}

	func cancelTranscription() {
		logger.info("Cancelling YouTube transcription")
		currentTask?.cancel()
		currentTask = nil
		youtubeTranscriptionManager.cancelTranscription()

		isTranscribing = false
		transcriptionProgress = 0.0
	}

	func copyResultToClipboard() {
		let textToCopy: String

		if showTimestamps && !transcriptionSegments.isEmpty {
			textToCopy = transcriptionSegments.map { segment in
				let formattedTime = segment.formatTime(
					segment.startTime, format: TimestampFormat.fromString(timestampFormat))
				return "[\(formattedTime)] \(segment.text)"
			}.joined(separator: "\n")
		} else {
			textToCopy = transcriptionResult
		}

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(textToCopy, forType: .string)

		logger.info("Copied transcription result to clipboard")
	}

	func exportResult(to url: URL) throws {
		guard !transcriptionResult.isEmpty else {
			throw FileTranscriptionError.transcriptionFailed("No transcription result to export")
		}

		logger.info("Exporting YouTube transcription result to: \(url.path)")

		var content = "# YouTube Transcription\n\n"
		if let videoInfo = videoInfo {
			content += "**Video:** \(videoInfo.title)\n"
			content += "**Duration:** \(formatTime(videoInfo.duration))\n"
			content += "**URL:** \(inputURL)\n"
			content += "**Transcribed:** \(Date().formatted())\n\n"

			if isSegmentMode {
				content +=
					"**Segment:** \(formatTime(selectedStartTime)) - \(formatTime(selectedEndTime))\n\n"
			}
		}

		content += "## Transcription\n\n"

		if showTimestamps && !transcriptionSegments.isEmpty {
			for segment in transcriptionSegments {
				let formattedTime = segment.formatTime(
					segment.startTime, format: TimestampFormat.fromString(timestampFormat))
				content += "[\(formattedTime)] \(segment.text)\n\n"
			}
		} else {
			content += "\(transcriptionResult)\n\n"
		}

		try content.write(to: url, atomically: true, encoding: .utf8)
		logger.info("Successfully exported YouTube transcription result")
	}

	func updateSegmentTimes() {
		guard let videoInfo = videoInfo else { return }

		// Parse custom time inputs
		selectedStartTime = parseTime(customStartTime)
		selectedEndTime = parseTime(customEndTime)

		// Validate time range
		if selectedStartTime >= selectedEndTime {
			selectedEndTime = min(selectedStartTime + 60, videoInfo.duration)  // Add 1 minute minimum
			customEndTime = formatTime(selectedEndTime)
		}

		if selectedEndTime > videoInfo.duration {
			selectedEndTime = videoInfo.duration
			customEndTime = formatTime(selectedEndTime)
		}

		if selectedStartTime < 0 {
			selectedStartTime = 0
			customStartTime = formatTime(selectedStartTime)
		}

		logger.info("Updated segment times: \(self.selectedStartTime)s - \(self.selectedEndTime)s")
	}

	// MARK: - Private Methods

	private func clearVideoInfo() {
		videoInfo = nil
		selectedStartTime = 0.0
		selectedEndTime = 300.0
		customStartTime = "0:00"
		customEndTime = "5:00"
	}

	private func isValidYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
			|| host == "m.youtube.com"
	}

	private func performTranscription(for url: URL) async {
		do {
			if isSegmentMode {
				logger.info(
					"Starting segment transcription: \(self.selectedStartTime)s - \(self.selectedEndTime)s")
				transcriptionResult = try await youtubeTranscriptionManager.transcribeYouTubeSegment(
					url,
					from: selectedStartTime,
					to: selectedEndTime
				)

				// For segment mode, try to get timestamps if available
				if defaultTranscriptionMode == "timestamps" {
					do {
						let fullSegments =
							try await youtubeTranscriptionManager.transcribeYouTubeURLWithTimestamps(url)
						// Filter segments to the selected time range
						transcriptionSegments = fullSegments.filter { segment in
							segment.startTime >= selectedStartTime && segment.endTime <= selectedEndTime
						}
					} catch {
						logger.warning(
							"Failed to get timestamps for segment: \(error.localizedDescription)")
					}
				}

			} else {
				logger.info("Starting full video transcription")

				if defaultTranscriptionMode == "timestamps" {
					transcriptionSegments =
						try await youtubeTranscriptionManager.transcribeYouTubeURLWithTimestamps(url)
					transcriptionResult = transcriptionSegments.map { $0.text }.joined(separator: " ")
				} else {
					transcriptionResult = try await youtubeTranscriptionManager.transcribeYouTubeURL(url)
				}
			}

			logger.info("YouTube transcription completed successfully")

		} catch {
			logger.error("YouTube transcription failed: \(error.localizedDescription)")

			let fileError: FileTranscriptionError
			if let existingError = error as? FileTranscriptionError {
				fileError = existingError
			} else {
				fileError = FileTranscriptionError.transcriptionFailed(error.localizedDescription)
			}
			showError(fileError)
		}

		isTranscribing = false
		transcriptionProgress = 1.0
	}

	private func showError(_ error: FileTranscriptionError) {
		self.error = error
		self.showingError = true
		logger.error("Showing error: \(error.localizedDescription)")
	}

	private func formatTime(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let remainingSeconds = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, remainingSeconds)
	}

	private func parseTime(_ timeString: String) -> Double {
		let components = timeString.split(separator: ":")

		if components.count == 2,
			let minutes = Int(components[0]),
			let seconds = Int(components[1])
		{
			return Double(minutes * 60 + seconds)
		} else if components.count == 1,
			let totalSeconds = Int(components[0])
		{
			return Double(totalSeconds)
		}

		return 0.0
	}
}

// MARK: - Quality Helper

extension YouTubeTranscriptionViewModel {
	var qualityOptions: [(String, String)] {
		[
			("low", "Low (128kbps)"),
			("medium", "Medium (256kbps)"),
			("high", "High (320kbps)"),
		]
	}

	var currentQualityDisplayName: String {
		qualityOptions.first { $0.0 == youtubeQuality }?.1 ?? "Medium (256kbps)"
	}
}

// MARK: - Validation Helpers

extension YouTubeTranscriptionViewModel {
	var isURLValid: Bool {
		guard !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let url = URL(string: inputURL.trimmingCharacters(in: .whitespacesAndNewlines))
		else {
			return false
		}
		return isValidYouTubeURL(url)
	}

	var canStartTranscription: Bool {
		return isURLValid && !isTranscribing && !isLoadingVideoInfo
	}

	var hasValidSegmentRange: Bool {
		guard isSegmentMode else { return true }
		return selectedStartTime < selectedEndTime && selectedEndTime > 0
	}
}
