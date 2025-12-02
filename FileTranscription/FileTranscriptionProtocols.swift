import Foundation
import SwiftUI

// MARK: - Core File Transcription Protocols

@MainActor
protocol FileTranscriptionCapable: AnyObject {
	var progress: Double { get }
	var isTranscribing: Bool { get }
	var currentFileName: String? { get }
	var error: Error? { get }

	func transcribeFile(at url: URL) async throws -> String
	func transcribeFiles(at urls: [URL]) async throws -> [String]
	func transcribeFileWithTimestamps(at url: URL) async throws -> [TranscriptionSegment]
	func transcribeSegment(at url: URL, startTime: Double, endTime: Double) async throws -> String
	func cancelTranscription()
	func supportsFileType(_ url: URL) -> Bool
}

@MainActor
protocol FileDownloadable: AnyObject {
	var downloadProgress: Double { get }
	var isDownloading: Bool { get }
	var bytesDownloaded: Int64 { get }
	var totalBytes: Int64 { get }

	func downloadFile(from url: URL) async throws -> URL
	func cancelDownload()
}

@MainActor
protocol DragDropHandler: AnyObject {
	var isDragging: Bool { get }
	var acceptedFileTypes: Set<String> { get }

	func canAccept(_ info: DropInfo) -> Bool
	func handleDrop(_ info: DropInfo) async -> Bool
}

@MainActor
protocol YouTubeTranscriptionCapable: FileTranscriptionCapable {
	var videoInfo: YouTubeVideoInfo? { get }

	func transcribeYouTubeURL(_ url: URL) async throws -> String
	func transcribeYouTubeURLWithTimestamps(_ url: URL) async throws -> [TranscriptionSegment]
	func transcribeYouTubeSegment(_ url: URL, from startTime: TimeInterval, to endTime: TimeInterval)
		async throws -> String
	func getVideoInfo(_ url: URL) async throws -> YouTubeVideoInfo
}

// MARK: - Supporting Data Structures

struct YouTubeVideoInfo {
	let title: String
	let duration: TimeInterval
	let thumbnailURL: URL?
	let videoID: String
}

struct TranscriptionSegment {
	let text: String
	let startTime: Double
	let endTime: Double

	var formattedTimeRange: String {
		return "\(formatTime(startTime)) - \(formatTime(endTime))"
	}

	var formattedStartTime: String {
		return formatTime(startTime)
	}

	var formattedEndTime: String {
		return formatTime(endTime)
	}

	private func formatTime(_ seconds: Double) -> String {
		let minutes = Int(seconds) / 60
		let remainingSeconds = Int(seconds) % 60
		return String(format: "%d:%02d", minutes, remainingSeconds)
	}

	func formatTime(_ seconds: Double, format: TimestampFormat) -> String {
		switch format {
		case .mmss:
			let minutes = Int(seconds) / 60
			let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
			return String(format: "%d:%02d", minutes, remainingSeconds)
		case .hhmmss:
			let hours = Int(seconds) / 3600
			let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600)) / 60
			let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
			return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
		case .seconds:
			return String(format: "%.1fs", seconds)
		}
	}
}

enum TimestampFormat: String, CaseIterable {
	case mmss = "MM:SS"
	case hhmmss = "HH:MM:SS"
	case seconds = "Seconds"

	var displayName: String {
		return rawValue
	}
}

enum TranscriptionMode: String, CaseIterable {
	case plainText = "Plain Text"
	case timestamped = "With Timestamps"

	var displayName: String {
		return rawValue
	}
}

// MARK: - File Type Support

extension FileTranscriptionCapable {
	func supportsFileType(_ url: URL) -> Bool {
		let fileExtension = url.pathExtension.lowercased()
		return SupportedFileTypes.audioFormats.contains(fileExtension)
			|| SupportedFileTypes.videoFormats.contains(fileExtension)
	}
}

struct SupportedFileTypes {
	static let audioFormats: Set<String> = [
		"mp3", "m4a", "wav", "aac", "flac", "aiff", "au", "caf",
	]

	static let videoFormats: Set<String> = [
		"mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v",
	]

	static let allFormats: Set<String> = {
		return audioFormats.union(videoFormats)
	}()

	static let formattedDescription: String = {
		let audio = audioFormats.map { ".\($0)" }.joined(separator: ", ")
		let video = videoFormats.map { ".\($0)" }.joined(separator: ", ")
		return "Audio: \(audio)\nVideo: \(video)"
	}()
}
