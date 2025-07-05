import Foundation
import AppKit
import Observation

enum UpdateError: Error, LocalizedError {
    case networkError
    case invalidResponse
    case noUpdateAvailable
    case downloadFailed
    case installationFailed
    
    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Failed to connect to update server"
        case .invalidResponse:
            return "Invalid response from update server"
        case .noUpdateAvailable:
            return "No update available"
        case .downloadFailed:
            return "Failed to download update"
        case .installationFailed:
            return "Failed to install update"
        }
    }
}

@Observable
class UpdateManager: NSObject {
    
    // MARK: - Notifications
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")
    static let downloadProgressNotification = Notification.Name("DownloadProgress")
    static let updateInstalledNotification = Notification.Name("UpdateInstalled")
    
    // MARK: - Observable Properties
    var isCheckingForUpdates = false
    var isDownloadingUpdate = false
    var downloadProgress: Double = 0.0
    var latestVersion: String?
    var downloadURL: String?
    var releaseNotes: String?
    var downloadingVersion: String?
    var downloadLocation: String?
    
    // MARK: - Private Properties
    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession?
    
    // MARK: - Computed Properties
    var isUpdateDownloaded: Bool {
        guard let latestVersion = latestVersion else { return false }
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return false }
        let localURL = downloadsDir.appendingPathComponent("Whispera-\(latestVersion).dmg")
        return FileManager.default.fileExists(atPath: localURL.path)
    }
    
    // MARK: - Settings
    var autoCheckForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckForUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckForUpdates") }
    }
    
    var autoDownloadUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "autoDownloadUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoDownloadUpdates") }
    }
    
    var autoInstallUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "autoInstallUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoInstallUpdates") }
    }
    
    // MARK: - Testing Properties
    var mockLatestVersion: String?
    var mockDownloadURL: String?
    var mockError: Error?
    
    override init() {
        super.init()
        setupDefaultSettings()
        setupURLSession()
    }
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    private func setupDefaultSettings() {
        if UserDefaults.standard.object(forKey: "autoCheckForUpdates") == nil {
            UserDefaults.standard.set(true, forKey: "autoCheckForUpdates")
        }
        if UserDefaults.standard.object(forKey: "autoDownloadUpdates") == nil {
            UserDefaults.standard.set(false, forKey: "autoDownloadUpdates")
        }
        if UserDefaults.standard.object(forKey: "autoInstallUpdates") == nil {
            UserDefaults.standard.set(false, forKey: "autoInstallUpdates")
        }
    }
    
    // MARK: - Update Checking
    
    @MainActor
    func checkForUpdates() async throws -> Bool {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        
        // Handle test mocks
        if let error = mockError {
            throw error
        }
        
        if let mockVersion = mockLatestVersion {
            latestVersion = mockVersion
            return AppVersion(mockVersion) > AppVersion.current
        }
        
        do {
            let release = try await fetchLatestRelease()
            latestVersion = release.tagName.replacingOccurrences(of: "v", with: "")
            downloadURL = release.assets.first { $0.name.hasSuffix(".dmg") }?.downloadURL
            releaseNotes = release.body
            
            let hasUpdate = AppVersion(latestVersion!) > AppVersion.current
            
            if hasUpdate {
                postUpdateAvailableNotification(
                    version: latestVersion!,
                    downloadURL: downloadURL ?? ""
                )
                
                if autoDownloadUpdates {
                    Task {
                        try await downloadUpdate()
                    }
                }
            }
            
            return hasUpdate
            
        } catch {
            throw UpdateError.networkError
        }
    }
    
    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: AppVersion.Constants.updateURL) else {
            throw UpdateError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.networkError
        }
        
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return release
    }
    
    // MARK: - Update Download
    
    @MainActor
    func downloadUpdate() async throws {
        guard let downloadURL = downloadURL,
              let url = URL(string: downloadURL) else {
            throw UpdateError.downloadFailed
        }
        
        // Prevent concurrent downloads
        guard !isDownloadingUpdate else {
            print("⚠️ Download already in progress")
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let localURL = documentsPath.appendingPathComponent("Whispera-\(latestVersion ?? "latest").dmg")
        
        // Check if file already exists
        if FileManager.default.fileExists(atPath: localURL.path) {
            print("✅ Update file already exists at: \(localURL.path)")
            downloadLocation = localURL.path
            
            // Auto-install if enabled
            if autoInstallUpdates {
                let success = await installUpdate(from: localURL.path)
                if !success {
                    throw UpdateError.installationFailed
                }
            } else {
                // Show notification to user
                showInstallUpdateNotification(dmgPath: localURL.path)
            }
            return
        }
        
        isDownloadingUpdate = true
        downloadProgress = 0.0
        downloadingVersion = latestVersion
        downloadLocation = localURL.path
        
        return try await withCheckedThrowingContinuation { continuation in
            downloadTask = urlSession?.downloadTask(with: url) { [weak self] tempURL, response, error in
                Task { @MainActor in
                    self?.isDownloadingUpdate = false
                    self?.downloadingVersion = nil
                    
                    if let error = error {
                        print("❌ Download failed: \(error)")
                        continuation.resume(throwing: UpdateError.downloadFailed)
                        return
                    }
                    
                    guard let tempURL = tempURL else {
                        print("❌ No temp URL for download")
                        continuation.resume(throwing: UpdateError.downloadFailed)
                        return
                    }
                    
                    do {
                        // Move downloaded file to Downloads folder
                        if FileManager.default.fileExists(atPath: localURL.path) {
                            try FileManager.default.removeItem(at: localURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: localURL)
                        
                        print("✅ Update downloaded to: \(localURL.path)")
                        
                        // Auto-install if enabled
                        if self?.autoInstallUpdates == true {
                            let success = await self?.installUpdate(from: localURL.path) ?? false
                            if !success {
                                continuation.resume(throwing: UpdateError.installationFailed)
                                return
                            }
                        } else {
                            // Show notification to user
                            self?.showInstallUpdateNotification(dmgPath: localURL.path)
                        }
                        
                        continuation.resume()
                        
                    } catch {
                        print("❌ Failed to move downloaded file: \(error)")
                        continuation.resume(throwing: UpdateError.downloadFailed)
                    }
                }
            }
            
            downloadTask?.resume()
        }
    }
    
    @MainActor
    func cancelDownload() {
        downloadTask?.cancel()
        isDownloadingUpdate = false
        downloadingVersion = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func installDownloadedUpdate() async throws {
        guard let latestVersion = latestVersion else {
            throw UpdateError.downloadFailed
        }
        
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw UpdateError.downloadFailed
        }
        
        let localURL = downloadsDir.appendingPathComponent("Whispera-\(latestVersion).dmg")
        
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw UpdateError.downloadFailed
        }
        
        let success = await installUpdate(from: localURL.path)
        if !success {
            throw UpdateError.installationFailed
        }
    }
    
    
    // MARK: - Update Installation
    
    @MainActor
    func installUpdate(from dmgPath: String) async -> Bool {
        do {
            // Mount the DMG
            let mountResult = try await mountDMG(at: dmgPath)
            guard let mountPoint = mountResult else {
                throw UpdateError.installationFailed
            }
            
            // Find the app bundle in the mounted DMG
            let appPath = mountPoint.appendingPathComponent("Whispera.app")
            guard FileManager.default.fileExists(atPath: appPath.path) else {
                try unmountDMG(at: mountPoint)
                throw UpdateError.installationFailed
            }
            
            // Copy to Applications folder
            let applicationsURL = URL(fileURLWithPath: "/Applications")
            let destinationURL = applicationsURL.appendingPathComponent("Whispera.app")
            
            // Remove existing app if it exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            // Copy new version
            try FileManager.default.copyItem(at: appPath, to: destinationURL)
            
            // Unmount DMG
            try unmountDMG(at: mountPoint)
            
            // Clean up downloaded DMG
            try FileManager.default.removeItem(atPath: dmgPath)
            
            // Post notification
            NotificationCenter.default.post(name: UpdateManager.updateInstalledNotification, object: nil)
            
            // Restart app
            restartApp()
            
            return true
            
        } catch {
            print("❌ Failed to install update: \(error)")
            return false
        }
    }
    
    private func mountDMG(at path: String) async throws -> URL? {
        // Use hdiutil to mount the DMG
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-quiet"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Parse mount point from output
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("/Volumes/") {
                let components = line.components(separatedBy: "\t")
                if let mountPoint = components.last?.trimmingCharacters(in: .whitespaces) {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        }
        
        return nil
    }
    
    private func unmountDMG(at mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        
        try process.run()
        process.waitUntilExit()
    }
    
    private func restartApp() {
        let appURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        
        try? process.run()
        NSApp.terminate(nil)
    }
    
    // MARK: - Notifications
    
    @MainActor
    func postUpdateAvailableNotification(version: String, downloadURL: String) {
        NotificationCenter.default.post(
            name: UpdateManager.updateAvailableNotification,
            object: nil,
            userInfo: ["version": version, "downloadURL": downloadURL]
        )
    }
    
    @MainActor
    private func showInstallUpdateNotification(dmgPath: String) {
        let alert = NSAlert()
        alert.messageText = "Update Downloaded"
        alert.informativeText = "Whispera \(latestVersion ?? "latest") has been downloaded. Would you like to install it now?"
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Install Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                await installUpdate(from: dmgPath)
            }
        }
    }
}

// MARK: - GitHub API Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let assets: [GitHubAsset]
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let downloadURL: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        guard totalBytesExpectedToWrite > 0 else { return }
        
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        Task { @MainActor in
            downloadProgress = progress
            
            NotificationCenter.default.post(
                name: UpdateManager.downloadProgressNotification,
                object: nil,
                userInfo: ["progress": progress]
            )
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The download completion is handled in the downloadTask completion handler
        // This delegate method is just for progress tracking
    }
}