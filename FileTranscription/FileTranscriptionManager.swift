import Foundation
import OSLog
import SwiftUI
import WhisperKit

@MainActor
@Observable
class FileTranscriptionManager: FileTranscriptionCapable {

	// MARK: - FileTranscriptionCapable Properties
	var progress: Double = 0.0
	var isTranscribing: Bool = false
	var currentFileName: String?
	var error: Error?

	// MARK: - Private Properties
	private let whisperKit: WhisperKitTranscriber
	private var currentTask: Task<Void, Never>?
	private let logger = Logger(
		subsystem: Bundle.main.bundleIdentifier ?? "Whispera", category: "FileTranscription")
	private var currentProgress: Progress?
	private var transcriptionTask: Task<[TranscriptionResult], Error>?

	// MARK: - File Queue Management
	private var fileQueue: [FileTranscriptionTask] = []
	private var isProcessingQueue: Bool = false

	init(whisperKit: WhisperKitTranscriber? = nil) {
		self.whisperKit = whisperKit ?? WhisperKitTranscriber.shared
	}

	// MARK: - FileTranscriptionCapable Methods

	func transcribeFile(at url: URL) async throws -> String {
		logger.info("🎵 Starting file transcription for: \(url.lastPathComponent)")

		guard supportsFileType(url) else {
			throw FileTranscriptionError.unsupportedFormat(url.pathExtension)
		}

		guard url.startAccessingSecurityScopedResource() else {
			throw FileTranscriptionError.fileAccessDenied
		}
		defer { url.stopAccessingSecurityScopedResource() }

		// Check user setting for timestamps
		let showTimestamps = UserDefaults.standard.bool(forKey: "showTimestamps")
		logger.info("📝 User setting showTimestamps: \(showTimestamps)")

		if showTimestamps {
			// Return timestamped transcription formatted as string
			let segments =
				try await performSingleTranscription(url: url, withTimestamps: true)
				as! [TranscriptionSegment]
			return formatSegmentsAsString(segments)
		} else {
			// Return plain text
			return try await performSingleTranscription(url: url, withTimestamps: false) as! String
		}
	}

	func transcribeFiles(at urls: [URL]) async throws -> [String] {
		logger.info("🎵 Starting batch transcription for \(urls.count) files")

		var results: [String] = []

		for (index, url) in urls.enumerated() {
			// Check for task cancellation before each file
			if Task.isCancelled {
				logger.info("🛑 Batch transcription cancelled at file \(index + 1)/\(urls.count)")
				break
			}

			currentFileName = url.lastPathComponent
			progress = Double(index) / Double(urls.count)

			do {
				let result = try await transcribeFile(at: url)
				results.append(result)
			} catch {
				logger.error(
					"❌ Failed to transcribe \(url.lastPathComponent): \(error.localizedDescription)")
				results.append("Error: \(error.localizedDescription)")
			}
		}

		progress = 1.0
		currentFileName = nil

		return results
	}

	func transcribeFileWithTimestamps(at url: URL) async throws -> [TranscriptionSegment] {
		logger.info("🎵 Starting timestamped transcription for: \(url.lastPathComponent)")

		guard supportsFileType(url) else {
			throw FileTranscriptionError.unsupportedFormat(url.pathExtension)
		}

		guard url.startAccessingSecurityScopedResource() else {
			throw FileTranscriptionError.fileAccessDenied
		}
		defer { url.stopAccessingSecurityScopedResource() }

		return try await performSingleTranscription(url: url, withTimestamps: true)
			as! [TranscriptionSegment]
	}

	func transcribeSegment(at url: URL, startTime: Double, endTime: Double) async throws -> String {
		logger.info(
			"🎵 Starting segment transcription for: \(url.lastPathComponent) [\(startTime)s - \(endTime)s]"
		)

		guard supportsFileType(url) else {
			throw FileTranscriptionError.unsupportedFormat(url.pathExtension)
		}

		guard startTime < endTime else {
			throw FileTranscriptionError.invalidTimeRange
		}

		guard url.startAccessingSecurityScopedResource() else {
			throw FileTranscriptionError.fileAccessDenied
		}
		defer { url.stopAccessingSecurityScopedResource() }

		// For segment transcription, we'll use WhisperKit's clipTimestamps feature
		return try await performSegmentTranscription(url: url, startTime: startTime, endTime: endTime)
	}

	func cancelTranscription() {
		logger.info("🛑 Cancelling file transcription")
		transcriptionTask?.cancel()
		currentProgress?.cancel()
		currentTask?.cancel()
		transcriptionTask = nil
		currentTask = nil
		currentProgress = nil
		isTranscribing = false
		progress = 0.0
		currentFileName = nil
		error = nil
	}

	func supportsFileType(_ url: URL) -> Bool {
		let fileExtension = url.pathExtension.lowercased()
		return SupportedFileTypes.allFormats.contains(fileExtension)
	}

	// MARK: - Private Helpers

	private func formatSegmentsAsString(_ segments: [TranscriptionSegment]) -> String {
		let timestampFormat = UserDefaults.standard.string(forKey: "timestampFormat") ?? "MM:SS"
		logger.info("📝 Formatting \(segments.count) segments with timestamp format: \(timestampFormat)")

		let formattedString = segments.map { segment in
			let timestamp = formatTimestamp(segment.startTime, format: timestampFormat)
			return "[\(timestamp)] \(segment.text)"
		}.joined(separator: "\n")

		logger.info("📝 Generated formatted string length: \(formattedString.count) characters")
		return formattedString
	}

	private func formatTimestamp(_ timeInSeconds: Double, format: String) -> String {
		let totalSeconds = Int(timeInSeconds)
		let hours = totalSeconds / 3600
		let minutes = (totalSeconds % 3600) / 60
		let seconds = totalSeconds % 60

		switch format {
		case "HH:MM:SS":
			return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
		case "Seconds":
			return String(format: "%.1fs", timeInSeconds)
		default:  // "MM:SS"
			return String(format: "%02d:%02d", minutes, seconds)
		}
	}

	// MARK: - Private Implementation

	private func performSingleTranscription(url: URL, withTimestamps: Bool) async throws -> Any {
		isTranscribing = true
		currentFileName = url.lastPathComponent
		progress = 0.0
		error = nil

		defer {
			isTranscribing = false
			currentFileName = nil
			progress = 0.0
			currentProgress = nil
			transcriptionTask = nil
		}

		do {
			// Use WhisperKit's transcribe method
			let enableTranslation = UserDefaults.standard.bool(forKey: "enableTranslation")

			if withTimestamps {
				// Use new timestamped file transcription method with real progress
				let result = try await transcribeWithProgress(
					url: url, enableTranslation: enableTranslation, withTimestamps: true)
				return result
			} else {
				// Use new file transcription method with real progress
				let result = try await transcribeWithProgress(
					url: url, enableTranslation: enableTranslation, withTimestamps: false)
				return result
			}

		} catch is CancellationError {
			logger.info("🛑 Transcription cancelled by user")
			throw CancellationError()
		} catch {
			self.error = error
			logger.error("❌ Transcription failed: \(error.localizedDescription)")
			throw error
		}
	}

	private func transcribeWithProgress(url: URL, enableTranslation: Bool, withTimestamps: Bool)
		async throws -> Any
	{
		// Access WhisperKit's internal transcribe method with progress callback
		guard let whisperKitInstance = whisperKit.whisperKit else {
			throw FileTranscriptionError.transcriptionFailed("WhisperKit not initialized")
		}

		// Configure decoding options based on timestamp requirements
		if withTimestamps {
			logger.info("📝 Configuring for timestamps - withoutTimestamps: false, wordTimestamps: true")
			// Configure for timestamp output
			whisperKit.updateAdvancedSettings(
				withoutTimestamps: false,
				wordTimestamps: true
			)
		} else {
			logger.info("📝 Configuring for plain text - withoutTimestamps: true, wordTimestamps: false")
			whisperKit.updateAdvancedSettings(
				withoutTimestamps: true,
				wordTimestamps: false
			)
		}

		// Get updated options with timestamp settings
		let decodingOptions = whisperKit.getCurrentDecodingOptions(enableTranslation: enableTranslation)

		// Store the progress object for cancellation
		currentProgress = whisperKitInstance.progress

		// Use WhisperKit's transcribe method with progress callback
		let progressCallback: ((TranscriptionProgress) -> Bool?) = { [weak self] _ in
			Task { @MainActor in
				// Use WhisperKit's real progress from the Progress object
				self?.progress = whisperKitInstance.progress.fractionCompleted
			}
			return nil  // Continue transcription
		}

		// Create and store the transcription task so we can cancel it
		transcriptionTask = Task {
			return try await whisperKitInstance.transcribe(
				audioPath: url.path,
				decodeOptions: decodingOptions,
				callback: progressCallback
			)
		}

		let transcriptionResults: [TranscriptionResult] = try await transcriptionTask!.value

		progress = 1.0

		if withTimestamps {
			// Convert WhisperKit results to TranscriptionSegment array
			let allSegments = transcriptionResults.flatMap { transcriptionResult in
				transcriptionResult.segments.compactMap { whisperSegment -> TranscriptionSegment? in
					let text = whisperSegment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
					guard !text.isEmpty else {
						return nil
					}

					return TranscriptionSegment(
						text: text,
						startTime: Double(whisperSegment.start),
						endTime: Double(whisperSegment.end)
					)
				}
			}
			logger.info("📝 Generated \(allSegments.count) timestamped segments")
			if allSegments.isEmpty {
				logger.warning(
					"⚠️ No timestamped segments generated - this may indicate timestamp configuration issue")
			}
			return allSegments
		} else {
			// Return plain text
			let transcription = transcriptionResults.compactMap { $0.text }.joined(separator: " ")
				.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
			return transcription.isEmpty ? "No speech detected" : transcription
		}
	}

	private func transcribeWithTimestamps(url: URL, enableTranslation: Bool) async throws
		-> [TranscriptionSegment]
	{
		// This is a placeholder implementation since we need to access WhisperKit's internal methods
		// In a real implementation, we would need to modify WhisperKitTranscriber to expose the raw segments
		logger.info("🎯 Performing timestamped transcription")

		// For now, we'll get the plain text and create dummy segments
		// TODO: Modify WhisperKitTranscriber to return raw segments with timestamps
		let plainText = try await whisperKit.transcribe(
			audioURL: url, enableTranslation: enableTranslation)

		// Create segments from the plain text (this is a temporary solution)
		let words = plainText.split(separator: " ").map(String.init)
		var segments: [TranscriptionSegment] = []

		// Estimate timing based on average speaking rate (150 words per minute)
		let wordsPerSecond = 2.5
		var currentTime = 0.0

		for (_, word) in words.enumerated() {
			// Rough estimate based on word length
			let wordDuration = Double(word.count) / 5.0 / wordsPerSecond
			let segment = TranscriptionSegment(
				text: word,
				startTime: currentTime,
				endTime: currentTime + wordDuration
			)
			segments.append(segment)
			currentTime += wordDuration + 0.1  // Small pause between words
		}

		return segments
	}

	private func performSegmentTranscription(url: URL, startTime: Double, endTime: Double)
		async throws -> String
	{
		logger.info("🎯 Performing segment transcription from \(startTime)s to \(endTime)s")

		isTranscribing = true
		currentFileName = url.lastPathComponent
		progress = 0.0

		defer {
			isTranscribing = false
			currentFileName = nil
			progress = 0.0
		}

		// Use new WhisperKitTranscriber segment method
		let enableTranslation = UserDefaults.standard.bool(forKey: "enableTranslation")
		progress = 0.5

		let result = try await whisperKit.transcribeFileSegment(
			at: url,
			startTime: startTime,
			endTime: endTime,
			enableTranslation: enableTranslation
		)

		progress = 1.0
		return result
	}
}

// MARK: - Supporting Types

private struct FileTranscriptionTask {
	let url: URL
	let withTimestamps: Bool
	let startTime: Double?
	let endTime: Double?
}

// MARK: - Error Types

enum FileTranscriptionError: LocalizedError {
	case unsupportedFormat(String)
	case fileAccessDenied
	case invalidTimeRange
	case transcriptionFailed(String)
	case cancelled

	var errorDescription: String? {
		switch self {
		case .unsupportedFormat(let format):
			return "Unsupported file format: .\(format)"
		case .fileAccessDenied:
			return "Unable to access the selected file. Please check permissions."
		case .invalidTimeRange:
			return "Invalid time range. Start time must be less than end time."
		case .transcriptionFailed(let reason):
			return "Transcription failed: \(reason)"
		case .cancelled:
			return "Transcription was cancelled."
		}
	}

	var recoverySuggestion: String? {
		switch self {
		case .unsupportedFormat:
			return "Please select a supported audio or video file format."
		case .fileAccessDenied:
			return "Make sure the file exists and you have permission to read it."
		case .invalidTimeRange:
			return "Please enter a valid time range with start time before end time."
		case .transcriptionFailed:
			return "Please try again or select a different file."
		case .cancelled:
			return nil
		}
	}
}
