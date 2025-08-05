import Foundation
import SwiftUI
import YouTubeKit

@MainActor
@Observable
class YouTubeTranscriptionManager: YouTubeTranscriptionCapable {
	
	// MARK: - FileTranscriptionCapable Properties
	var progress: Double = 0.0
	var isTranscribing: Bool = false
	var currentFileName: String?
	var error: Error?
	
	// MARK: - YouTubeTranscriptionCapable Properties
	var videoInfo: YouTubeVideoInfo?
	
	// MARK: - Private Properties
	private let fileTranscriptionManager: FileTranscriptionManager
	private let networkDownloader: NetworkFileDownloader
	private let logger = AppLogger.shared.youtubeTranscriber
	private var currentTask: Task<Void, Never>?
	
	// MARK: - Settings
	@ObservationIgnored @AppStorage("youtubeQuality") private var preferredQuality: YouTubeQuality = .medium
	@ObservationIgnored @AppStorage("autoDeleteDownloadedFiles") private var autoDeleteDownloadedFiles: Bool = true
	
	init(
		fileTranscriptionManager: FileTranscriptionManager,
		networkDownloader: NetworkFileDownloader
	) {
		self.fileTranscriptionManager = fileTranscriptionManager
		self.networkDownloader = networkDownloader
	}
	
	// MARK: - FileTranscriptionCapable Methods
	func transcribeFile(at url: URL) async throws -> String {
		if isYouTubeURL(url) {
			return try await transcribeYouTubeURL(url)
		} else {
			return try await fileTranscriptionManager.transcribeFile(at: url)
		}
	}
	
	func transcribeFiles(at urls: [URL]) async throws -> [String] {
		var results: [String] = []
		
		for (index, url) in urls.enumerated() {
			progress = Double(index) / Double(urls.count)
			
			do {
				let result = try await transcribeFile(at: url)
				results.append(result)
			} catch {
				logger.error("❌ Failed to transcribe \(url.absoluteString): \(error.localizedDescription)")
				results.append("Error: \(error.localizedDescription)")
			}
		}
		
		progress = 1.0
		return results
	}
	
	func transcribeFileWithTimestamps(at url: URL) async throws -> [TranscriptionSegment] {
		if isYouTubeURL(url) {
			return try await transcribeYouTubeURLWithTimestamps(url)
		} else {
			return try await fileTranscriptionManager.transcribeFileWithTimestamps(at: url)
		}
	}
	
	func transcribeSegment(at url: URL, startTime: Double, endTime: Double) async throws -> String {
		if isYouTubeURL(url) {
			return try await transcribeYouTubeSegment(url, from: startTime, to: endTime)
		} else {
			return try await fileTranscriptionManager.transcribeSegment(at: url, startTime: startTime, endTime: endTime)
		}
	}
	
	func cancelTranscription() {
		logger.info("🛑 Cancelling YouTube transcription")
		currentTask?.cancel()
		currentTask = nil
		networkDownloader.cancelDownload()
		fileTranscriptionManager.cancelTranscription()
		// Reset state
		isTranscribing = false
		progress = 0.0
		currentFileName = nil
		error = nil
		videoInfo = nil
		// TODO: we probably should delete the file if we have it downloaded already
	}
	
	func supportsFileType(_ url: URL) -> Bool {
		return isYouTubeURL(url) || fileTranscriptionManager.supportsFileType(url)
	}
	
	// MARK: - YouTubeTranscriptionCapable Methods
	func transcribeYouTubeURL(_ url: URL) async throws -> String {
		logger.info("🎬 Starting YouTube transcription for: \(url.absoluteString)")
		guard isYouTubeURL(url) else {
			throw YouTubeTranscriptionError.invalidYouTubeURL
		}
		isTranscribing = true
		progress = 0.0
		error = nil
		defer {
			isTranscribing = false
			progress = 0.0
			currentFileName = nil
		}
		
		do {
			// Step 1: Get video info (10% progress)
			progress = 0.1
			let info = try await getVideoInfo(url)
			videoInfo = info
			currentFileName = info.title
			// Step 2: Extract audio stream URL (20% progress)
			progress = 0.2
			let audioStreamURL = try await extractAudioStreamURL(from: url, quality: preferredQuality)
			// Step 3: Download audio file (20% -> 70% progress)
			progress = 0.2
			let downloadedFile = try await downloadAudioStream(from: audioStreamURL)
			progress = 0.7
			// Step 4: Transcribe the downloaded audio (70% -> 100% progress)
			let transcription = try await fileTranscriptionManager.transcribeFile(at: downloadedFile)
			progress = 1.0
			// Cleanup if enabled
			if autoDeleteDownloadedFiles {
				networkDownloader.cleanupFile(at: downloadedFile)
			}
			return transcription
		} catch {
			self.error = error
			throw error
		}
	}
	
	func transcribeYouTubeURLWithTimestamps(_ url: URL) async throws -> [TranscriptionSegment] {
		logger.info("🎬⏱️ Starting timestamped YouTube transcription for: \(url.absoluteString)")
		
		guard isYouTubeURL(url) else {
			throw YouTubeTranscriptionError.invalidYouTubeURL
		}
		
		isTranscribing = true
		progress = 0.0
		error = nil
		
		defer {
			isTranscribing = false
			progress = 0.0
			currentFileName = nil
		}
		
		do {
			// Get video info
			progress = 0.1
			let info = try await getVideoInfo(url)
			videoInfo = info
			currentFileName = info.title
			
			// Extract and download audio
			progress = 0.2
			let audioStreamURL = try await extractAudioStreamURL(from: url, quality: preferredQuality)
			let downloadedFile = try await downloadAudioStream(from: audioStreamURL)
			progress = 0.7
			
			// Transcribe with timestamps
			let segments = try await fileTranscriptionManager.transcribeFileWithTimestamps(at: downloadedFile)
			progress = 1.0
			
			// Cleanup if enabled
			if autoDeleteDownloadedFiles {
				networkDownloader.cleanupFile(at: downloadedFile)
			}
			
			return segments
			
		} catch {
			self.error = error
			throw error
		}
	}
	
	func transcribeYouTubeSegment(_ url: URL, from startTime: TimeInterval, to endTime: TimeInterval) async throws -> String {
		logger.info("🎬✂️ Starting YouTube segment transcription [\(startTime)s - \(endTime)s]")
		
		guard isYouTubeURL(url) else {
			throw YouTubeTranscriptionError.invalidYouTubeURL
		}
		
		guard startTime < endTime else {
			throw YouTubeTranscriptionError.invalidTimeRange
		}
		
		isTranscribing = true
		progress = 0.0
		error = nil
		
		defer {
			isTranscribing = false
			progress = 0.0
			currentFileName = nil
		}
		
		do {
			// Get video info and validate time range
			progress = 0.1
			let info = try await getVideoInfo(url)
			videoInfo = info
			currentFileName = info.title
			
			guard endTime <= info.duration else {
				throw YouTubeTranscriptionError.timeRangeExceedsVideoDuration
			}
			// Extract and download audio
			progress = 0.2
			let audioStreamURL = try await extractAudioStreamURL(from: url, quality: preferredQuality)
			let downloadedFile = try await downloadAudioStream(from: audioStreamURL)
			progress = 0.7
			// Transcribe segment
			let transcription = try await fileTranscriptionManager.transcribeSegment(
				at: downloadedFile,
				startTime: startTime,
				endTime: endTime
			)
			progress = 1.0
			// Cleanup if enabled
			if autoDeleteDownloadedFiles {
				networkDownloader.cleanupFile(at: downloadedFile)
			}
			
			return transcription
			
		} catch {
			self.error = error
			throw error
		}
	}
	
	func getVideoInfo(_ url: URL) async throws -> YouTubeVideoInfo {
		logger.info("📺 Getting video info for: \(url.absoluteString)")
		
		guard isYouTubeURL(url) else {
			throw YouTubeTranscriptionError.invalidYouTubeURL
		}
		
		guard let videoID = extractVideoID(from: url) else {
			throw YouTubeTranscriptionError.videoIDExtractionFailed
		}
		
		logger.info("🆔 Extracted video ID: \(videoID)")
		
		do {
			let youtube = YouTube(videoID: videoID)
			let metadata = try await youtube.metadata
			let info = YouTubeVideoInfo(
				title: metadata?.title ?? "YouTube Video (\(videoID))",
				duration: 300.0,
				thumbnailURL: URL(string: "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg"),
				videoID: videoID
			)
			logger.info("✅ Retrieved video info: '\(info.title)', duration: \(info.duration)s")
			return info
		} catch {
			logger.error("❌ Failed to get video info: \(error.localizedDescription)")
			throw YouTubeTranscriptionError.videoInfoRetrievalFailed
		}
	}
	
	// MARK: - Private Methods
	private func isYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" ||
		host == "www.youtube.com" ||
		host == "youtu.be" ||
		host == "m.youtube.com"
	}
	
	private func extractVideoID(from url: URL) -> String? {
		if url.host == "youtu.be" {
			return url.lastPathComponent
		}
		if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		   let queryItems = components.queryItems {
			return queryItems.first { $0.name == "v" }?.value
		}
		return nil
	}
	
	private func extractAudioStreamURL(from youtubeURL: URL, quality: YouTubeQuality) async throws -> URL {
		logger.info("🎵 Extracting audio stream URL with quality: \(quality.rawValue)")
		guard let videoID = extractVideoID(from: youtubeURL) else {
			throw YouTubeTranscriptionError.videoIDExtractionFailed
		}
		
		do {
			let youtube = YouTube(videoID: videoID)
			let streams = try await youtube.streams
			let audioStreams = streams.filter { stream in
				stream.includesAudioTrack && !stream.includesVideoTrack
			}
			
			let sortedStreams = audioStreams.sorted { stream1, stream2 in
				let bitrate1 = stream1.bitrate ?? 0
				let bitrate2 = stream2.bitrate ?? 0
				
				switch quality {
					case .high:
						return bitrate1 > bitrate2
					case .medium, .low:
						return abs(bitrate1 - 128) < abs(bitrate2 - 128) // Prefer ~128kbps
				}
			}
			
			guard let selectedStream = sortedStreams.first else {
				throw YouTubeTranscriptionError.audioExtractionFailed
			}
			let streamURL = selectedStream.url
			logger.info("✅ Selected audio stream: bitrate \(selectedStream.bitrate ?? 0)")
			return streamURL
			
		} catch {
			logger.error("❌ Failed to extract audio stream: \(error.localizedDescription)")
			throw YouTubeTranscriptionError.audioExtractionFailed
		}
	}
	
	private func downloadAudioStream(from streamURL: URL) async throws -> URL {
		logger.info("⬇️ Downloading audio stream using chunked download for optimal speed")
		// Use chunked download for YouTube streams to improve speed significantly
		// Pass video title if available for better filename
		let preferredName = videoInfo?.title
		return try await networkDownloader.downloadFileWithChunks(from: streamURL, chunkSize: 2_097_152, preferredFileName: preferredName) // 2MB chunks
	}
	
}

// MARK: - Supporting Types
enum YouTubeQuality: String, CaseIterable {
	case low = "128kbps"
	case medium = "256kbps"
	case high = "320kbps"
	
	var displayName: String {
		return rawValue
	}
	
	var bitrateKbps: Int {
		switch self {
			case .low: return 128
			case .medium: return 256
			case .high: return 320
		}
	}
}

// MARK: - Error Types
enum YouTubeTranscriptionError: LocalizedError {
	case invalidYouTubeURL
	case videoNotFound
	case audioExtractionFailed
	case invalidTimeRange
	case timeRangeExceedsVideoDuration
	case networkError(String)
	case videoIDExtractionFailed
	case videoInfoRetrievalFailed
	
	var errorDescription: String? {
		switch self {
			case .invalidYouTubeURL:
				return "Invalid YouTube URL. Please provide a valid YouTube video URL."
			case .videoNotFound:
				return "YouTube video not found. The video may be private or deleted."
			case .audioExtractionFailed:
				return "Failed to extract audio from YouTube video."
			case .invalidTimeRange:
				return "Invalid time range. Start time must be less than end time."
			case .timeRangeExceedsVideoDuration:
				return "Time range exceeds video duration."
			case .networkError(let reason):
				return "Network error: \(reason)"
			case .videoIDExtractionFailed:
				return "Failed to extract video ID from YouTube URL."
			case .videoInfoRetrievalFailed:
				return "Failed to retrieve video information from YouTube."
		}
	}
	
	var recoverySuggestion: String? {
		switch self {
			case .invalidYouTubeURL:
				return "Make sure the URL is a valid YouTube video link."
			case .videoNotFound:
				return "Check that the video exists and is publicly accessible."
			case .audioExtractionFailed:
				return "Try a different video or check your internet connection."
			case .invalidTimeRange:
				return "Enter a valid time range with start time before end time."
			case .timeRangeExceedsVideoDuration:
				return "Choose a time range within the video's duration."
			case .networkError:
				return "Check your internet connection and try again."
			case .videoIDExtractionFailed:
				return "Make sure the YouTube URL format is correct (e.g., youtube.com/watch?v=... or youtu.be/...)."
			case .videoInfoRetrievalFailed:
				return "Check your internet connection and verify the video is accessible."
		}
	}
}
