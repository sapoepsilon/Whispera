import Foundation
import SwiftUI
import OSLog
import AVFoundation

@MainActor
@Observable
class NetworkFileDownloader: FileDownloadable {
    
    // MARK: - FileDownloadable Properties
    var downloadProgress: Double = 0.0
    var isDownloading: Bool = false
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    
    // MARK: - Private Properties
    private var currentDownloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Whispera", category: "NetworkDownloader")
    private let fileManager = FileManager.default
    private var downloadCache: [String: URL] = [:] // Maps URL strings to local file paths
    private let cacheExpirationTime: TimeInterval = 3600 // 1 hour cache expiration
    
    // MARK: - File Management
    private var downloadsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Whispera/Downloads", isDirectory: true)
    }
    
    private var cacheMetadataURL: URL {
        downloadsDirectory.appendingPathComponent(".download_cache.json")
    }
    
    init() {
        // Configure URLSession with progress tracking
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0 // 5 minutes
        
        let delegate = NetworkDownloadDelegate()
        self.urlSession = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: .main
        )
        
        // Set up delegate callback and parent reference
        delegate.parentDownloader = self
        delegate.progressCallback = { [weak self] progress, bytesDownloaded, totalBytes in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.bytesDownloaded = bytesDownloaded
                self?.totalBytes = totalBytes
                
                // Notify UI of progress updates
                NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
            }
        }
        
        createDownloadsDirectoryIfNeeded()
        loadDownloadCache()
    }
    
    // MARK: - FileDownloadable Methods
    
    func downloadFile(from url: URL) async throws -> URL {
        logger.info("🌐 Starting download from: \(url.absoluteString)")
        
        // Check cache first
        if let cachedFile = getCachedFile(for: url) {
            logger.info("🎯 Using cached file: \(cachedFile.lastPathComponent)")
            return cachedFile
        }
        
        guard !isDownloading else {
            throw NetworkDownloadError.downloadInProgress
        }
        
        // Validate URL
        guard url.scheme == "http" || url.scheme == "https" else {
            throw NetworkDownloadError.invalidURL
        }
        
        isDownloading = true
        downloadProgress = 0.0
        bytesDownloaded = 0
        totalBytes = 0
        
        // Notify UI of state change
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
        
        defer {
            isDownloading = false
            downloadProgress = 0.0
            bytesDownloaded = 0
            totalBytes = 0
            currentDownloadTask = nil
            
            // Notify UI of state change
            NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
        }
        
        do {
            // Create download request
            var request = URLRequest(url: url)
            request.setValue("Whispera/1.0", forHTTPHeaderField: "User-Agent")
            
            // Start download
            let downloadTask = urlSession.downloadTask(with: request)
            currentDownloadTask = downloadTask
            
            let localFile = try await withCheckedThrowingContinuation { continuation in
                // Store continuation in delegate
                if let delegate = urlSession.delegate as? NetworkDownloadDelegate {
                    delegate.completion = continuation
                }
                
                downloadTask.resume()
            }
            
            // Add to cache on successful download
            addToCache(url: url, localPath: localFile)
            return localFile
            
        } catch {
            logger.error("❌ Download failed: \(error.localizedDescription)")
            throw NetworkDownloadError.downloadFailed(error.localizedDescription)
        }
    }
    
    func cancelDownload() {
        logger.info("🛑 Cancelling download")
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
        bytesDownloaded = 0
        totalBytes = 0
        
        // Notify UI of state change
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
    }
    
    /// Download file using parallel chunked downloads for improved speed
    /// This method is particularly effective for YouTube and other throttled streams
    func downloadFileWithChunks(from url: URL, chunkSize: Int64 = 2_097_152, preferredFileName: String? = nil) async throws -> URL {
        logger.info("🚀 Starting chunked download from: \(url.absoluteString)")
        
        // Check cache first
        if let cachedFile = getCachedFile(for: url) {
            logger.info("🎯 Using cached file: \(cachedFile.lastPathComponent)")
            return cachedFile
        }
        
        guard !isDownloading else {
            throw NetworkDownloadError.downloadInProgress
        }
        
        // Validate URL
        guard url.scheme == "http" || url.scheme == "https" else {
            throw NetworkDownloadError.invalidURL
        }
        
        isDownloading = true
        downloadProgress = 0.0
        bytesDownloaded = 0
        totalBytes = 0
        
        // Notify UI of state change
        NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
        
        defer {
            isDownloading = false
            downloadProgress = 0.0
            bytesDownloaded = 0
            totalBytes = 0
            
            // Notify UI of state change
            NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
        }
        
        do {
            // Step 1: Get file size with HEAD request
            let fileSize = try await getFileSize(from: url)
            totalBytes = fileSize
            
            logger.info("📏 File size: \(ByteCountFormatter().string(fromByteCount: fileSize))")
            
            // Step 2: Calculate chunks
            let numberOfChunks = Int((fileSize + chunkSize - 1) / chunkSize) // Round up
            let chunks = (0..<numberOfChunks).map { chunkIndex in
                let start = Int64(chunkIndex) * chunkSize
                let end = min(start + chunkSize - 1, fileSize - 1)
                return ChunkInfo(index: chunkIndex, start: start, end: end)
            }
            
            logger.info("🧩 Downloading \(chunks.count) chunks of ~\(ByteCountFormatter().string(fromByteCount: chunkSize)) each")
            
            // Step 3: Download chunks in parallel
            let chunkData = try await downloadChunksInParallel(from: url, chunks: chunks)
            
            // Step 4: Combine chunks and write to file
            let finalURL = try await combineChunksToFile(chunkData: chunkData, originalURL: url, preferredFileName: preferredFileName)
            
            // Step 5: Validate the combined file
            do {
                try self.validateDownloadedFile(at: finalURL)
                logger.info("✅ Chunked download completed and validated: \(finalURL.lastPathComponent)")
                
                // Add to cache on successful download
                addToCache(url: url, localPath: finalURL)
                return finalURL
            } catch {
                logger.error("❌ Chunked download validation failed: \(error.localizedDescription)")
                // Clean up invalid file
                try? FileManager.default.removeItem(at: finalURL)
                throw error
            }
            
        } catch {
            logger.error("❌ Chunked download failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Chunked Download Helper Methods
    
    private func getFileSize(from url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Whispera/1.0", forHTTPHeaderField: "User-Agent")
        
        let (_, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkDownloadError.downloadFailed("Failed to get file size")
        }
        
        let contentLength = httpResponse.expectedContentLength
        guard contentLength > 0 else {
            throw NetworkDownloadError.downloadFailed("Invalid file size")
        }
        
        return contentLength
    }
    
    private func downloadChunksInParallel(from url: URL, chunks: [ChunkInfo]) async throws -> [ChunkData] {
        let maxConcurrentDownloads = min(4, chunks.count) // Limit concurrent downloads
        
        return try await withThrowingTaskGroup(of: ChunkData.self, returning: [ChunkData].self) { taskGroup in
            var chunkData: [ChunkData] = []
            var activeDownloads = 0
            var chunkIndex = 0
            
            // Start initial downloads
            while activeDownloads < maxConcurrentDownloads && chunkIndex < chunks.count {
                let chunk = chunks[chunkIndex]
                taskGroup.addTask {
                    try await self.downloadSingleChunk(from: url, chunk: chunk)
                }
                activeDownloads += 1
                chunkIndex += 1
            }
            
            // Process completed downloads and start new ones
            while !taskGroup.isEmpty {
                let completedChunk = try await taskGroup.next()!
                chunkData.append(completedChunk)
                
                // Update progress
                await MainActor.run {
                    self.bytesDownloaded += Int64(completedChunk.data.count)
                    self.downloadProgress = Double(self.bytesDownloaded) / Double(self.totalBytes)
                    
                    // Notify UI of progress update
                    NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
                }
                
                // Start next download if available
                if chunkIndex < chunks.count {
                    let chunk = chunks[chunkIndex]
                    taskGroup.addTask {
                        try await self.downloadSingleChunk(from: url, chunk: chunk)
                    }
                    chunkIndex += 1
                }
            }
            
            // Sort chunks by index to maintain order
            return chunkData.sorted { $0.index < $1.index }
        }
    }
    
    private func downloadSingleChunk(from url: URL, chunk: ChunkInfo) async throws -> ChunkData {
        var request = URLRequest(url: url)
        request.setValue("Whispera/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkDownloadError.downloadFailed("Invalid response for chunk \(chunk.index)")
        }
        
        // Accept both 206 (Partial Content) and 200 (OK) status codes
        guard httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
            throw NetworkDownloadError.downloadFailed("Failed to download chunk \(chunk.index): HTTP \(httpResponse.statusCode)")
        }
        
        logger.debug("📦 Downloaded chunk \(chunk.index): \(data.count) bytes")
        
        return ChunkData(index: chunk.index, data: data)
    }
    
    private func combineChunksToFile(chunkData: [ChunkData], originalURL: URL, preferredFileName: String? = nil) async throws -> URL {
        // Generate final destination
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let downloadsDir = appSupport.appendingPathComponent("Whispera/Downloads", isDirectory: true)
        
        // Create directory if needed
        try fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        
        // Generate filename - prefer title, fallback to time-based
        let baseName: String
        if let preferredName = preferredFileName, !preferredName.isEmpty {
            // Sanitize the preferred filename for filesystem safety
            let sanitizedName = sanitizeFilename(preferredName)
            baseName = "\(sanitizedName).m4a"
        } else {
            // Fallback to original logic
            var originalName = originalURL.lastPathComponent
            if originalName == "videoplayback" || !originalName.contains(".") {
                originalName = "audio.m4a"
            }
            let timestamp = Int(Date().timeIntervalSince1970)
            let randomSuffix = Int.random(in: 1000...9999)
            baseName = "\(timestamp)_\(randomSuffix)_\(originalName)"
        }
        
        // Ensure filename is unique by adding counter if needed
        var finalName = baseName
        var finalURL = downloadsDir.appendingPathComponent(finalName)
        var counter = 1
        
        while fileManager.fileExists(atPath: finalURL.path) {
            let nameWithoutExtension = (baseName as NSString).deletingPathExtension
            let pathExtension = (baseName as NSString).pathExtension
            
            if pathExtension.isEmpty {
                finalName = "\(nameWithoutExtension) (\(counter))"
            } else {
                finalName = "\(nameWithoutExtension) (\(counter)).\(pathExtension)"
            }
            
            finalURL = downloadsDir.appendingPathComponent(finalName)
            counter += 1
            
            // Safety check to prevent infinite loop
            if counter > 1000 {
                throw NetworkDownloadError.fileMoveError("Could not generate unique filename after 1000 attempts")
            }
        }
        
        // Combine chunks in order
        let outputStream = OutputStream(url: finalURL, append: false)!
        outputStream.open()
        defer { outputStream.close() }
        
        for chunk in chunkData {
            chunk.data.withUnsafeBytes { bytes in
                let bytesWritten = outputStream.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: chunk.data.count)
                if bytesWritten != chunk.data.count {
                    logger.error("⚠️ Failed to write complete chunk \(chunk.index)")
                }
            }
        }
        
        logger.info("📁 Combined file saved to: \(finalURL.path)")
        return finalURL
    }
    
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid characters for filesystem
        let invalidChars = CharacterSet(charactersIn: "/:*?\"<>|\\")
        var sanitized = filename.components(separatedBy: invalidChars).joined(separator: "_")
        
        // Trim whitespace and dots from beginning/end
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        
        // Ensure it's not empty and not too long
        if sanitized.isEmpty {
            sanitized = "audio"
        } else if sanitized.count > 100 {
            // Limit to 100 characters to avoid filesystem issues
            sanitized = String(sanitized.prefix(100))
        }
        
        return sanitized
    }
    
    // MARK: - File Management
    
    func cleanupTemporaryFiles() {
        logger.info("🧹 Cleaning up download files")
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
            for fileURL in contents {
                // Skip the cache metadata file
                if fileURL.lastPathComponent == ".download_cache.json" {
                    continue
                }
                try fileManager.removeItem(at: fileURL)
                logger.info("🗑️ Deleted download file: \(fileURL.lastPathComponent)")
            }
            
            // Clear the cache dictionary as well
            downloadCache.removeAll()
            saveDownloadCache()
            
        } catch {
            logger.error("❌ Failed to clean up download files: \(error.localizedDescription)")
        }
    }
    
    func clearExpiredCache() {
        logger.info("🧹 Clearing expired cache entries")
        
        let now = Date()
        var expiredCount = 0
        
        downloadCache = downloadCache.filter { urlString, localPath in
            // Check if file exists
            guard fileManager.fileExists(atPath: localPath.path) else {
                expiredCount += 1
                return false
            }
            
            // Check file age
            do {
                let attributes = try fileManager.attributesOfItem(atPath: localPath.path)
                if let creationDate = attributes[.creationDate] as? Date {
                    if now.timeIntervalSince(creationDate) > cacheExpirationTime {
                        // File is expired, optionally delete it
                        try? fileManager.removeItem(at: localPath)
                        expiredCount += 1
                        return false
                    }
                }
            } catch {
                // If we can't check attributes, remove from cache
                expiredCount += 1
                return false
            }
            
            return true
        }
        
        if expiredCount > 0 {
            saveDownloadCache()
            logger.info("🗑️ Removed \(expiredCount) expired cache entries")
        }
    }
    
    func cleanupFile(at url: URL) {
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                logger.info("🗑️ Deleted file: \(url.lastPathComponent)")
            }
        } catch {
            logger.error("❌ Failed to delete file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func createDownloadsDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("❌ Failed to create downloads directory: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Cache Management
    
    private func loadDownloadCache() {
        guard fileManager.fileExists(atPath: cacheMetadataURL.path) else {
            logger.info("📂 No download cache found, starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: cacheMetadataURL)
            let decoder = JSONDecoder()
            let cacheData = try decoder.decode([String: CacheEntry].self, from: data)
            
            // Filter out expired entries and non-existent files
            let now = Date()
            downloadCache = cacheData.compactMapValues { entry in
                // Check if file still exists and is not expired
                if fileManager.fileExists(atPath: entry.localPath.path) &&
                   now.timeIntervalSince(entry.downloadDate) < cacheExpirationTime {
                    return entry.localPath
                }
                return nil
            }
            
            logger.info("📂 Loaded download cache with \(self.downloadCache.count) valid entries")
        } catch {
            logger.error("❌ Failed to load download cache: \(error.localizedDescription)")
            downloadCache = [:]
        }
    }
    
    private func saveDownloadCache() {
        do {
            let cacheData = downloadCache.mapValues { localPath in
                CacheEntry(localPath: localPath, downloadDate: Date())
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(cacheData)
            try data.write(to: cacheMetadataURL)
            
            logger.info("💾 Saved download cache with \(self.downloadCache.count) entries")
        } catch {
            logger.error("❌ Failed to save download cache: \(error.localizedDescription)")
        }
    }
    
    private func getCachedFile(for url: URL) -> URL? {
        let urlString = url.absoluteString
        
        if let cachedPath = downloadCache[urlString] {
            // Verify the file still exists and is valid
            if fileManager.fileExists(atPath: cachedPath.path) {
                do {
                    // Validate the cached file
                    try validateDownloadedFile(at: cachedPath)
                    logger.info("✅ Found valid cached file for URL: \(url.absoluteString)")
                    return cachedPath
                } catch {
                    logger.warning("⚠️ Cached file validation failed, will re-download: \(error.localizedDescription)")
                    // Remove invalid entry from cache
                    downloadCache.removeValue(forKey: urlString)
                    saveDownloadCache()
                }
            } else {
                // File doesn't exist, remove from cache
                downloadCache.removeValue(forKey: urlString)
                saveDownloadCache()
            }
        }
        
        return nil
    }
    
    private func addToCache(url: URL, localPath: URL) {
        downloadCache[url.absoluteString] = localPath
        saveDownloadCache()
        logger.info("➕ Added to download cache: \(url.absoluteString) -> \(localPath.lastPathComponent)")
    }
    
    fileprivate nonisolated func validateDownloadedFile(at url: URL) throws {
        // Check if file exists and has content
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NetworkDownloadError.fileValidationFailed("Downloaded file does not exist")
        }
        
        // Check file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            guard fileSize > 0 else {
                throw NetworkDownloadError.corruptedFile("Downloaded file is empty (0 bytes)")
            }
            
            // Check if file is suspiciously small (less than 1KB might be an error page)
            guard fileSize > 1024 else {
                throw NetworkDownloadError.corruptedFile("Downloaded file is too small (\(fileSize) bytes) - might be an error response or incomplete download")
            }
            
            // Note: Using print instead of logger since this is nonisolated
            print("📏 File size validation passed: \(ByteCountFormatter().string(fromByteCount: fileSize))")
            
        } catch let error as NetworkDownloadError {
            throw error
        } catch {
            throw NetworkDownloadError.fileValidationFailed("Failed to get file attributes: \(error.localizedDescription)")
        }
        
        // Validate audio format by trying to create AVAudioFile
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.fileFormat
            let duration = Double(audioFile.length) / format.sampleRate
            
            print("🎵 Audio format validation passed:")
            print("  - Format: \(format.commonFormat.rawValue)")
            print("  - Sample Rate: \(format.sampleRate) Hz")
            print("  - Channels: \(format.channelCount)")
            print("  - Duration: \(String(format: "%.2f", duration)) seconds")
            
            // Check for reasonable duration (not 0 and not suspiciously short)
            guard duration > 0.1 else {
                throw NetworkDownloadError.corruptedFile("Audio file duration is too short (\(String(format: "%.2f", duration)) seconds)")
            }
            
        } catch let error as NetworkDownloadError {
            throw error
        } catch {
            // If AVAudioFile fails, the file format is not supported or corrupted
            print("🚫 Audio format validation failed: \(error.localizedDescription)")
            
            // Determine if it's a format issue or corruption based on error type
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("format") || errorString.contains("codec") || errorString.contains("unsupported") {
                throw NetworkDownloadError.unsupportedAudioFormat("The downloaded file format is not supported by AVAudioEngine. Error: \(error.localizedDescription)")
            } else {
                throw NetworkDownloadError.corruptedFile("Downloaded file appears to be corrupted or incomplete. AVAudioEngine error: \(error.localizedDescription)")
            }
        }
    }
    
    private func generateTemporaryFilename(from url: URL) -> String {
        let originalName = url.lastPathComponent
        let timestamp = DateFormatter().string(from: Date())
        
        if originalName.isEmpty || !originalName.contains(".") {
            // Generate a name based on URL hash
            let urlHash = String(url.absoluteString.hashValue)
            return "download_\(urlHash)_\(timestamp).tmp"
        }
        
        return "\(timestamp)_\(originalName)"
    }
}

// MARK: - NetworkFileDownloader + FileTranscriptionCapable

extension NetworkFileDownloader {
    
    /// Downloads a network file and transcribes it using the provided FileTranscriptionManager
    func downloadAndTranscribe(
        from url: URL,
        using transcriptionManager: FileTranscriptionManager,
        withTimestamps: Bool = false,
        deleteAfterTranscription: Bool = true
    ) async throws -> Any {
        
        logger.info("🌐📝 Starting download and transcribe workflow for: \(url.absoluteString)")
        
        // Download the file
        let localURL = try await downloadFile(from: url)
        
        defer {
            if deleteAfterTranscription {
                cleanupFile(at: localURL)
            }
        }
        
        // Transcribe the downloaded file
        do {
            if withTimestamps {
                return try await transcriptionManager.transcribeFileWithTimestamps(at: localURL)
            } else {
                return try await transcriptionManager.transcribeFile(at: localURL)
            }
        } catch {
            logger.error("❌ Transcription failed for downloaded file: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - URLSessionDownloadDelegate

private class NetworkDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var progressCallback: ((Double, Int64, Int64) -> Void)?
    var completion: CheckedContinuation<URL, Error>?
    weak var parentDownloader: NetworkFileDownloader?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Whispera", category: "NetworkDownloadDelegate")
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        logger.info("✅ Download completed, moving file from temporary location")
        
        do {
            // Generate final destination
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let downloadsDir = appSupport.appendingPathComponent("Whispera/Downloads", isDirectory: true)
            
            // Create directory if needed
            try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            
            // Generate unique filename with appropriate extension
            var originalName = downloadTask.originalRequest?.url?.lastPathComponent ?? "download"
            
            // For YouTube downloads, ensure we have an audio extension
            if originalName == "videoplayback" || !originalName.contains(".") {
                // Try to determine format from response headers
                let mimeType = downloadTask.response?.mimeType ?? ""
                let fileExt = extensionForMimeType(mimeType)
                originalName = "audio\(fileExt)"
            }
            
            let timestamp = Int(Date().timeIntervalSince1970)
            let randomSuffix = Int.random(in: 1000...9999)
            let baseName = "\(timestamp)_\(randomSuffix)_\(originalName)"
            
            // Ensure filename is unique by adding counter if needed
            var finalName = baseName
            var finalURL = downloadsDir.appendingPathComponent(finalName)
            var counter = 1
            
            while FileManager.default.fileExists(atPath: finalURL.path) {
                let nameWithoutExtension = (baseName as NSString).deletingPathExtension
                let pathExtension = (baseName as NSString).pathExtension
                
                if pathExtension.isEmpty {
                    finalName = "\(nameWithoutExtension)_\(counter)"
                } else {
                    finalName = "\(nameWithoutExtension)_\(counter).\(pathExtension)"
                }
                
                finalURL = downloadsDir.appendingPathComponent(finalName)
                counter += 1
                
                // Safety check to prevent infinite loop
                if counter > 1000 {
                    throw NetworkDownloadError.fileMoveError("Could not generate unique filename after 1000 attempts")
                }
            }
            
            // Move file to final location
            try FileManager.default.moveItem(at: location, to: finalURL)
            
            logger.info("📁 File saved to: \(finalURL.path)")
            
            // Validate the downloaded file
            do {
                // Get the parent NetworkFileDownloader instance to call validation
                if let parent = session.delegate as? NetworkDownloadDelegate,
                   let parentDownloader = parent.parentDownloader {
                    try parentDownloader.validateDownloadedFile(at: finalURL)
                } else {
                    // Fallback validation if parent not available
                    let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    guard fileSize > 1024 else {
                        throw NetworkDownloadError.corruptedFile("Downloaded file is too small")
                    }
                }
                logger.info("✅ File validation successful: \(finalURL.lastPathComponent)")
                completion?.resume(returning: finalURL)
            } catch {
                logger.error("❌ File validation failed: \(error.localizedDescription)")
                // Clean up invalid file
                try? FileManager.default.removeItem(at: finalURL)
                completion?.resume(throwing: error)
            }
            
        } catch {
            logger.error("❌ Failed to move downloaded file: \(error.localizedDescription)")
            completion?.resume(throwing: NetworkDownloadError.fileMoveError(error.localizedDescription))
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        
        progressCallback?(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logger.error("❌ Download failed with error: \(error.localizedDescription)")
            completion?.resume(throwing: NetworkDownloadError.downloadFailed(error.localizedDescription))
        }
    }
    
    
    private func extensionForMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3":
            return ".mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":
            return ".m4a"
        case "audio/wav", "audio/wave", "audio/x-wav":
            return ".wav"
        case "audio/aac":
            return ".aac"
        case "audio/flac":
            return ".flac"
        case "audio/ogg":
            return ".ogg"
        case "audio/webm":
            return ".webm"
        case "video/mp4":
            return ".mp4"
        case "video/webm":
            return ".webm"
        default:
            // Default to m4a for YouTube audio which often doesn't have proper MIME type
            return ".m4a"
        }
    }
}

// MARK: - Cache Entry

private struct CacheEntry: Codable {
    let localPath: URL
    let downloadDate: Date
}

// MARK: - Error Types

enum NetworkDownloadError: LocalizedError {
    case invalidURL
    case downloadInProgress
    case downloadFailed(String)
    case fileMoveError(String)
    case networkUnavailable
    case fileTooBig(Int64)
    case fileValidationFailed(String)
    case unsupportedAudioFormat(String)
    case corruptedFile(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL. Please provide a valid HTTP or HTTPS URL."
        case .downloadInProgress:
            return "A download is already in progress. Please wait for it to complete."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .fileMoveError(let reason):
            return "Failed to save downloaded file: \(reason)"
        case .networkUnavailable:
            return "Network is unavailable. Please check your internet connection."
        case .fileTooBig(let size):
            return "File is too large (\(ByteCountFormatter().string(fromByteCount: size))). Maximum size limit exceeded."
        case .fileValidationFailed(let reason):
            return "Downloaded file validation failed: \(reason)"
        case .unsupportedAudioFormat(let reason):
            return "Unsupported audio format: \(reason)"
        case .corruptedFile(let reason):
            return "Downloaded file appears to be corrupted: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .invalidURL:
            return "Make sure the URL starts with http:// or https://"
        case .downloadInProgress:
            return "Wait for the current download to finish or cancel it first."
        case .downloadFailed:
            return "Check your internet connection and try again."
        case .fileMoveError:
            return "Make sure you have enough disk space and proper permissions."
        case .networkUnavailable:
            return "Connect to the internet and try again."
        case .fileTooBig:
            return "Try downloading a smaller file or increase the size limit in settings."
        case .fileValidationFailed:
            return "Try downloading the file again or check if the source URL is correct."
        case .unsupportedAudioFormat:
            return "Try a different audio format or URL. Supported formats include MP3, M4A, WAV, and MP4."
        case .corruptedFile:
            return "Try downloading the file again. The source file may be damaged or incomplete."
        }
    }
}

// MARK: - Chunked Download Data Structures

private struct ChunkInfo {
    let index: Int
    let start: Int64
    let end: Int64
}

private struct ChunkData {
    let index: Int
    let data: Data
}