import Foundation
import SwiftUI
import OSLog

@MainActor
@Observable
class FileTranscriptionViewModel {
    
    // MARK: - UI State
    var selectedFiles: [URL] = []
    var transcriptionResults: [FileTranscriptionResult] = []
    var isTranscribing: Bool = false
    var overallProgress: Double = 0.0
    var currentFileName: String?
    var error: FileTranscriptionError?
    var showingError: Bool = false
    
    // MARK: - Settings
    @ObservationIgnored @AppStorage("showTimestamps") private var showTimestamps: Bool = true
    @ObservationIgnored @AppStorage("timestampFormat") private var timestampFormat: String = "MM:SS"
    @ObservationIgnored @AppStorage("defaultTranscriptionMode") private var defaultTranscriptionMode: String = "plain"
    @ObservationIgnored @AppStorage("maxFileSizeMB") private var maxFileSizeMB: Int = 100
    
    // MARK: - Dependencies
    private let fileTranscriptionManager: FileTranscriptionManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Whispera", category: "FileTranscriptionViewModel")
    
    // MARK: - Private State
    private var currentTask: Task<Void, Never>?
    
    init(fileTranscriptionManager: FileTranscriptionManager) {
        self.fileTranscriptionManager = fileTranscriptionManager
        setupObservation()
    }
    
    // MARK: - Public Methods
    
    func addFiles(_ urls: [URL]) {
        logger.info("Adding \(urls.count) files to transcription queue")
        
        let validFiles = urls.filter { url in
            do {
                try validateFile(url)
                return true
            } catch {
                logger.error("Invalid file \(url.lastPathComponent): \(error.localizedDescription)")
                if let fileError = error as? FileTranscriptionError {
                    showError(fileError)
                }
                return false
            }
        }
        
        selectedFiles.append(contentsOf: validFiles)
        logger.info("Added \(validFiles.count) valid files. Total queue: \(self.selectedFiles.count)")
    }
    
    func removeFile(at index: Int) {
        guard index < selectedFiles.count else { return }
        let removedFile = selectedFiles.remove(at: index)
        logger.info("Removed file: \(removedFile.lastPathComponent)")
        
        // Also remove corresponding result if it exists
        transcriptionResults.removeAll { $0.fileURL == removedFile }
    }
    
    func clearAllFiles() {
        logger.info("Clearing all files from queue")
        selectedFiles.removeAll()
        transcriptionResults.removeAll()
    }
    
    func startTranscription() {
        guard !selectedFiles.isEmpty else {
            logger.warning("No files selected for transcription")
            return
        }
        
        guard !isTranscribing else {
            logger.warning("Transcription already in progress")
            return
        }
        
        logger.info("Starting transcription for \(self.selectedFiles.count) files")
        isTranscribing = true
        overallProgress = 0.0
        error = nil
        
        currentTask = Task {
            await performTranscription()
        }
    }
    
    func cancelTranscription() {
        logger.info("Cancelling transcription")
        currentTask?.cancel()
        currentTask = nil
        fileTranscriptionManager.cancelTranscription()
        
        isTranscribing = false
        overallProgress = 0.0
        currentFileName = nil
    }
    
    func retryFailedTranscriptions() {
        let failedResults = transcriptionResults.filter { $0.status == .failed }
        logger.info("Retrying \(failedResults.count) failed transcriptions")
        
        // Remove failed results and re-add files to queue
        transcriptionResults.removeAll { $0.status == .failed }
        let filesToRetry = failedResults.map { $0.fileURL }
        selectedFiles.append(contentsOf: filesToRetry)
        
        if !filesToRetry.isEmpty {
            startTranscription()
        }
    }
    
    func exportResults(to url: URL) throws {
        logger.info("Exporting transcription results to: \(url.path)")
        
        let successfulResults = transcriptionResults.filter { $0.status == .completed }
        guard !successfulResults.isEmpty else {
            throw FileTranscriptionError.transcriptionFailed("No successful transcriptions to export")
        }
        
        var content = "# Transcription Results\n\n"
        content += "Generated on \(Date().formatted())\n\n"
        
        for result in successfulResults {
            content += "## \(result.filename)\n\n"
            
            if showTimestamps, let segments = result.segments {
                for segment in segments {
                    let formattedTime = segment.formatTime(segment.startTime, format: TimestampFormat.fromString(timestampFormat))
                    content += "[\(formattedTime)] \(segment.text)\n\n"
                }
            } else {
                content += "\(result.text)\n\n"
            }
            
            content += "---\n\n"
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Successfully exported \(successfulResults.count) transcription results")
    }
    
    // MARK: - Private Methods
    
    private func setupObservation() {
        // Observe file transcription manager state changes
        // This would typically be done with Combine or similar reactive framework
        // For now, we'll update during transcription
    }
    
    private func validateFile(_ url: URL) throws {
        // Check file exists and is accessible
        guard url.startAccessingSecurityScopedResource() else {
            throw FileTranscriptionError.fileAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileTranscriptionError.transcriptionFailed("File not found: \(url.path)")
        }
        
        // Check file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                let maxSizeBytes = Int64(maxFileSizeMB) * 1024 * 1024
                if fileSize > maxSizeBytes {
                    throw FileTranscriptionError.transcriptionFailed("File too large: \(fileSize) bytes (maximum: \(maxSizeBytes) bytes)")
                }
            }
        } catch {
            throw FileTranscriptionError.transcriptionFailed("File not found: \(url.path)")
        }
        
        // Check file format
        let fileExtension = url.pathExtension.lowercased()
        guard SupportedFileTypes.allFormats.contains(fileExtension) else {
            throw FileTranscriptionError.unsupportedFormat(fileExtension)
        }
    }
    
    private func performTranscription() async {
        let totalFiles = selectedFiles.count
        
        for (index, fileURL) in selectedFiles.enumerated() {
            guard !Task.isCancelled else {
                logger.info("Transcription cancelled by user")
                break
            }
            
            currentFileName = fileURL.lastPathComponent
            overallProgress = Double(index) / Double(totalFiles)
            
            // Create pending result
            let result = FileTranscriptionResult(
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                text: "",
                segments: nil,
                status: .inProgress,
                startTime: Date(),
                duration: 0
            )
            transcriptionResults.append(result)
            
            do {
                logger.info("Transcribing file \(index + 1)/\(totalFiles): \(fileURL.lastPathComponent)")
                
                let transcriptionText: String
                let segments: [TranscriptionSegment]?
                
                if defaultTranscriptionMode == "timestamps" {
                    let transcriptionSegments = try await fileTranscriptionManager.transcribeFileWithTimestamps(at: fileURL)
                    segments = transcriptionSegments
                    transcriptionText = transcriptionSegments.map { $0.text }.joined(separator: " ")
                } else {
                    transcriptionText = try await fileTranscriptionManager.transcribeFile(at: fileURL)
                    segments = nil
                }
                
                // Update result with success
                if let resultIndex = transcriptionResults.firstIndex(where: { $0.fileURL == fileURL }) {
                    transcriptionResults[resultIndex] = FileTranscriptionResult(
                        fileURL: fileURL,
                        filename: fileURL.lastPathComponent,
                        text: transcriptionText,
                        segments: segments,
                        status: .completed,
                        startTime: result.startTime,
                        duration: Date().timeIntervalSince(result.startTime)
                    )
                }
                
                logger.info("Successfully transcribed: \(fileURL.lastPathComponent)")
                
            } catch {
                logger.error("Failed to transcribe \(fileURL.lastPathComponent): \(error.localizedDescription)")
                
                let fileError: FileTranscriptionError
                if let existingError = error as? FileTranscriptionError {
                    fileError = existingError
                } else {
                    fileError = FileTranscriptionError.transcriptionFailed(error.localizedDescription)
                }
                
                // Update result with failure
                if let resultIndex = transcriptionResults.firstIndex(where: { $0.fileURL == fileURL }) {
                    transcriptionResults[resultIndex] = FileTranscriptionResult(
                        fileURL: fileURL,
                        filename: fileURL.lastPathComponent,
                        text: "",
                        segments: nil,
                        status: .failed,
                        error: fileError,
                        startTime: result.startTime,
                        duration: Date().timeIntervalSince(result.startTime)
                    )
                }
                
                // Show error for first failure, but continue with other files
                if self.error == nil {
                    showError(fileError)
                }
            }
        }
        
        // Clean up
        selectedFiles.removeAll()
        isTranscribing = false
        overallProgress = 1.0
        currentFileName = nil
        
        logger.info("Transcription batch completed")
    }
    
    private func showError(_ error: FileTranscriptionError) {
        self.error = error
        self.showingError = true
        logger.error("Showing error: \(error.localizedDescription)")
    }
}

// MARK: - Supporting Types

struct FileTranscriptionResult: Identifiable {
    let id = UUID()
    let fileURL: URL
    let filename: String
    let text: String
    let segments: [TranscriptionSegment]?
    let status: TranscriptionStatus
    let error: FileTranscriptionError?
    let startTime: Date
    let duration: TimeInterval
    
    init(fileURL: URL, filename: String, text: String, segments: [TranscriptionSegment]?, 
         status: TranscriptionStatus, error: FileTranscriptionError? = nil, 
         startTime: Date, duration: TimeInterval) {
        self.fileURL = fileURL
        self.filename = filename
        self.text = text
        self.segments = segments
        self.status = status
        self.error = error
        self.startTime = startTime
        self.duration = duration
    }
}

enum TranscriptionStatus {
    case pending
    case inProgress
    case completed
    case failed
    
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "clock"
        case .inProgress: return "waveform"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}

// MARK: - Helper Extensions

extension TimestampFormat {
    static func fromString(_ string: String) -> TimestampFormat {
        switch string {
        case "MM:SS": return .mmss
        case "HH:MM:SS": return .hhmmss
        case "Seconds": return .seconds
        default: return .mmss
        }
    }
}