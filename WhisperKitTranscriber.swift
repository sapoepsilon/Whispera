import Foundation
import AVFoundation
import WhisperKit

@MainActor
class WhisperKitTranscriber: ObservableObject {
    @Published var isInitialized = false
    @Published var isInitializing = false
    @Published var initializationProgress: Double = 0.0
    @Published var initializationStatus = "Starting..."
    @Published var availableModels: [String] = []
    @Published var currentModel: String?
    @Published var downloadedModels: Set<String> = [] {
        didSet {
            // Persist downloaded models to UserDefaults
            UserDefaults.standard.set(Array(downloadedModels), forKey: "downloadedModels")
        }
    }
    
    // WhisperKit model state tracking
    @Published var modelState: String = "unloaded"
    @Published var isModelLoading: Bool = false
    @Published var isModelLoaded: Bool = false
    
	private func modelCacheDirectory(for modelName: String) -> URL? {
		guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera/Models/\(modelName)")
	}
	
    @Published var isDownloadingModel = false {
        didSet {
            // Notify observers when download state changes
            if isDownloadingModel != oldValue {
                NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
            }
        }
    }
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    
    @MainActor var whisperKit: WhisperKit?
    @MainActor private var initializationTask: Task<Void, Never>?
    
    // Swift 6 compliant singleton pattern
    static let shared: WhisperKitTranscriber = {
        let instance = WhisperKitTranscriber()
        return instance
    }()
    
    private init() {
        // Load persisted downloaded models from UserDefaults
        if let savedModels = UserDefaults.standard.array(forKey: "downloadedModels") as? [String] {
            downloadedModels = Set(savedModels)
            print("📚 Restored \(downloadedModels.count) downloaded models from storage: \(downloadedModels)")
        }
        
        // Setup model directory
        setupModelDirectory()
        
        // Don't start initialization in init - wait for explicit call
    }
    
    func startInitialization() {
        guard initializationTask == nil else { 
            print("📋 WhisperKit initialization already in progress...")
            return 
        }
        
        isInitializing = true
        initializationProgress = 0.0
        initializationStatus = "Preparing to load AI models..."
        
        initializationTask = Task { @MainActor in
            await initialize()
        }
    }
    
    func syncDownloadedModelsCache() async {
        // Load previously saved models from UserDefaults
        // Since WhisperKit doesn't provide API to check disk, we trust our cache
        print("🔄 Loaded downloaded models cache: \(downloadedModels)")
    }
    
    private func setupModelDirectory() {
		guard let modelDir = modelCacheDirectory(for: "modelName") else { return }

        // Create the base directory if it doesn't exist
        // WhisperKit will create subdirectories as needed
        do {
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true, attributes: nil)
            print("✅ Model directory ready at: \(modelDir.path)")
            
        } catch {
            print("❌ Failed to create model directory: \(error)")
        }
    }
    
    private func initialize() async {
        guard !isInitialized else {
            print("📋 WhisperKit already initialized")
            isInitializing = false
            return
        }
        await updateProgress(0.1, "Loading WhisperKit framework...")
        try? await Task.sleep(nanoseconds: 500_000_000) // Small delay for UI feedback
        
        print("🔄 Initializing WhisperKit framework...")
        await updateProgress(0.3, "Setting up AI framework...")
        
        // Sync our cache with what's actually on disk
        await updateProgress(0.6, "Checking for existing models...")
        await syncDownloadedModelsCache()
	
        if !downloadedModels.isEmpty {
            // Try to initialize WhisperKit with default configuration
            await updateProgress(0.8, "Loading existing model...")
            
            do {
                // Try to load with custom model directory
                whisperKit = try await Task { @MainActor in
                    let whisperKitInstance = try await WhisperKit(downloadBase: .applicationSupportDirectory)
                    self.setupModelStateCallback(for: whisperKitInstance)
                    return whisperKitInstance
                }.value
                
                print("✅ WhisperKit initialized with existing models")
            } catch {
                print("⚠️ Failed to initialize with existing models: \(error)")
                print("📋 Will initialize WhisperKit when first model is downloaded")
            }
        } else {
            // No models downloaded yet - we'll initialize when first model is downloaded
            print("📋 No models downloaded yet - WhisperKit will be initialized with first model download")
        }
        
        await updateProgress(1.0, "Ready for model selection!")
        isInitialized = true
        isInitializing = false
        
        print("✅ WhisperKit framework initialized - ready for transcription")
        
        initializationTask = nil
    }
    
    private func updateProgress(_ progress: Double, _ status: String) async {
        await MainActor.run {
            self.initializationProgress = progress
            self.initializationStatus = status
        }
    }
    
    func transcribe(audioURL: URL) async throws -> String {
        guard isInitialized else {
            throw WhisperKitError.notInitialized
        }
        
        guard whisperKit != nil else {
            throw WhisperKitError.noModelLoaded
        }
        
        // Additional readiness check to ensure WhisperKit is truly ready
        guard await isWhisperKitReady() else {
            throw WhisperKitError.notReady
        }
        
        print("🎤 Starting transcription of: \(audioURL.lastPathComponent)")
        
        // Implement retry mechanism for MPS resource loading failures
        let maxRetries = 3
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                // Ensure transcription happens on MainActor for Swift 6 compliance
                let result = try await Task { @MainActor in
                    guard let whisperKitInstance = self.whisperKit else {
                        throw WhisperKitError.notInitialized
                    }
					if whisperKitInstance.modelState == .loading {
						print("Model isn't loaded yet. \(whisperKitInstance.modelState )")
					}
                    
                    // Additional MPS readiness check before transcription
                    if attempt > 1 {
                        print("🔄 Re-checking MPS readiness before retry...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s for MPS
                    }
                    
                    return try await whisperKitInstance.transcribe(audioPath: audioURL.path)
                }.value
                
                if !result.isEmpty {
                    let transcription = result.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !transcription.isEmpty {
                        print("✅ WhisperKit transcription completed: \(transcription)")
                        
                        // Clean up processed file if different from original
                        if audioURL != audioURL {
                            try? FileManager.default.removeItem(at: audioURL)
                        }
                        
                        return transcription
                    } else {
                        print("⚠️ Transcription returned empty text")
                        return "No speech detected"
                    }
                } else {
                    print("⚠️ No transcription segments returned")
                    return "No speech detected"
                }
                
            } catch {
                lastError = error
                let errorString = error.localizedDescription
                
                // Check if this is an MPS resource loading error that we can retry
                if errorString.contains("Failed to open resource file") || 
                   errorString.contains("MPSGraphComputePackage") ||
                   errorString.contains("Metal") {
                    
                    print("⚠️ Attempt \(attempt)/\(maxRetries) failed with MPS error: \(error)")
                    
                    if attempt < maxRetries {
                        // Exponential backoff: 1s, 2s, 4s
                        let delayNanoseconds = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                        print("⏳ Waiting \(delayNanoseconds / 1_000_000_000)s before retry...")
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                        
                        // Force MPS to reinitialize by giving it more time
                        print("🔄 Allowing MPS to reinitialize...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // Additional 1s for MPS
                    }
                } else {
                    // Non-MPS error, don't retry
                    print("❌ WhisperKit transcription failed with non-retryable error: \(error)")
                    break
                }
            }
        }
        
        // Clean up processed file if different from original
        if audioURL != audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        // All retries failed, throw the last error
        if let error = lastError {
            let errorString = error.localizedDescription
            if errorString.contains("Failed to open resource file") || 
               errorString.contains("MPSGraphComputePackage") ||
               errorString.contains("Metal") {
                throw WhisperKitError.transcriptionFailed("Metal Performance Shaders failed to load resources after \(maxRetries) attempts. Please restart the app.")
            } else {
                throw WhisperKitError.transcriptionFailed(error.localizedDescription)
            }
        } else {
            throw WhisperKitError.transcriptionFailed("Transcription failed for unknown reason")
        }
    }
    
    func switchModel(to model: String) async throws {
        // Refresh available models first to ensure we have the latest list
        if availableModels.isEmpty {
            try await refreshAvailableModels()
        }
        
        guard availableModels.contains(model) else {
            throw WhisperKitError.modelNotFound(model)
        }
        
        print("🔄 Switching to model: \(model)")
        
        // Check if model is already downloaded
        let currentlyDownloadedModels = try await getDownloadedModels()
        
        if !currentlyDownloadedModels.contains(model) {
            print("📥 Model \(model) not found locally, downloading first...")
            try await downloadModel(model)
            return // downloadModel already creates the WhisperKit instance
        }
        
        isDownloadingModel = true
        downloadingModelName = model
        downloadProgress = 0.0
        
        do {
            await updateDownloadProgress(0.2, "Preparing to load \(model)...")
            
            let recommendedModels = WhisperKit.recommendedModels()
            print("👂🏼 Recommended models: \(recommendedModels)")
            
            await updateDownloadProgress(0.6, "Loading \(model)...")
            // Use WhisperKit with specific model and custom model directory
            whisperKit = try await Task { @MainActor in
                let config = WhisperKitConfig(model: model, downloadBase: .applicationSupportDirectory)
                let whisperKitInstance = try await WhisperKit(config)
                self.setupModelStateCallback(for: whisperKitInstance)
                return whisperKitInstance
            }.value
            
            await updateDownloadProgress(0.9, "Finalizing model setup...")
            currentModel = model
            
            // Add to downloaded models set
            self.addModelToCache(model)
            
            await updateDownloadProgress(1.0, "Model ready!")
            isDownloadingModel = false
            downloadingModelName = nil
            
            print("✅ Switched to model: \(model)")
        } catch {
            isDownloadingModel = false
            downloadingModelName = nil
            downloadProgress = 0.0
            
            print("❌ Failed to switch to model \(model): \(error)")
            throw WhisperKitError.transcriptionFailed("Failed to load model: \(error.localizedDescription)")
        }
    }
    
    private func updateDownloadProgress(_ progress: Double, _ status: String) async {
        await MainActor.run {
            self.downloadProgress = progress
            // You could also update a download status message if needed
        }
    }
    
    func getDownloadedModels() async throws -> Set<String> {
        // For now, return our cached downloaded models
        // WhisperKit doesn't provide a public API to check downloaded models on disk
        // TODO: In the future, we could check the actual model directory if needed
        print("📝 Using cached models: \(downloadedModels)")
        return downloadedModels
    }
    
    func refreshAvailableModels() async throws {
        do {
            // Add timeout to prevent hanging
            let fetchedModels = try await withTimeout(seconds: 10) {
                try await WhisperKit.fetchAvailableModels()
            }
            
            // Remove duplicates using Set
            let uniqueModels = Array(Set(fetchedModels)).sorted()
            availableModels = uniqueModels
            
            print("✅ Refreshed available models: \(availableModels.count) unique models")
        } catch {
            print("❌ Failed to refresh available models, using defaults: \(error)")
            // Fallback to defaults instead of throwing
            availableModels = ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en"]
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            
            group.cancelAll()
            return result
        }
    }
    
    private struct TimeoutError: Error {}
    
    func getRecommendedModels() -> (default: String, supported: [String]) {
        let recommended = WhisperKit.recommendedModels()
        return (default: recommended.default, supported: recommended.supported)
    }
    
    private func getAudioDuration(_ audioURL: URL) async throws -> Double {
        let asset = AVAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    func downloadModel(_ modelName: String) async throws {
        isDownloadingModel = true
        downloadingModelName = modelName
        downloadProgress = 0.0
        
        do {
            await updateDownloadProgress(0.2, "Starting download...")
            
            await updateDownloadProgress(0.6, "Downloading model...")
            
            // Use WhisperKit's download method with default location
			let downloadedFolder = try await WhisperKit.download(variant: modelName, downloadBase: .applicationSupportDirectory)
            print("📥 Model downloaded to: \(downloadedFolder)")
            addModelToCache(modelName)
            
            await updateDownloadProgress(0.8, "Initializing model...")
            
            // Initialize WhisperKit with the specific model name and custom model directory
            whisperKit = try await Task { @MainActor in
                let config = WhisperKitConfig(model: modelName, downloadBase: .applicationSupportDirectory)
                let whisperKitInstance = try await WhisperKit(config)
                self.setupModelStateCallback(for: whisperKitInstance)
                return whisperKitInstance
            }.value
            currentModel = modelName
            print("✅ WhisperKit initialized with model: \(modelName)")
            
            await updateDownloadProgress(1.0, "Model ready!")
            print("✅ Successfully downloaded model: \(modelName)")
            
        } catch {
            print("❌ Failed to download model \(modelName): \(error)")
            throw error
        }
        
        isDownloadingModel = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    private func createSilentAudioFile() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "mps_prewarm_\(UUID().uuidString).wav"
        let audioURL = tempDir.appendingPathComponent(fileName)
        
        // Create a 0.5 second silent WAV file
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
            let frameCount = AVAudioFrameCount(16000 * 0.5) // 0.5 seconds
            let silentBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
            silentBuffer.frameLength = frameCount
            // Buffer is already zeroed (silent)
            try audioFile.write(from: silentBuffer)
        } catch {
            print("⚠️ Failed to create silent audio file: \(error)")
        }
        
        return audioURL
    }
    
    private func isWhisperKitReady() async -> Bool {
        // Give WhisperKit a moment to fully settle after initialization
        if !isInitialized {
            return false
        }
        
        // Since we've pre-warmed MPS, we can reduce the wait time
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        return whisperKit != nil && isInitialized
    }
    
    func isReadyForTranscription() -> Bool {
        return isInitialized && whisperKit != nil
    }
    
    func hasAnyModel() -> Bool {
        return whisperKit != nil
    }
    
    private func getApplicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("Whispera")
        
        // Ensure app directory exists
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        
        return appDirectory
    }
    
    // MARK: - Model Management
    
    func clearDownloadedModelsCache() {
        downloadedModels.removeAll()
        UserDefaults.standard.removeObject(forKey: "downloadedModels")
        print("🗑️ Cleared downloaded models cache")
    }
    
    func addModelToCache(_ modelName: String) {
        downloadedModels.insert(modelName)
        print("📥 Added \(modelName) to downloaded models cache")
    }

    
    // MARK: - WhisperKit Model State Management
    
    private func setupModelStateCallback(for whisperKitInstance: WhisperKit) {
        whisperKitInstance.modelStateCallback = { [weak self] oldState, newState in
            DispatchQueue.main.async {
                self?.handleModelStateChange(from: oldState, to: newState)
            }
        }
        
        // Set initial state
        handleModelStateChange(from: nil, to: whisperKitInstance.modelState)
    }
    
    private func handleModelStateChange(from oldState: ModelState?, to newState: ModelState) {
        let stateString = String(describing: newState)
        modelState = stateString
        isModelLoading = (newState == .loading || newState == .prewarming)
        isModelLoaded = (newState == .loaded || newState == .prewarmed)
        
        print("🎯 WhisperKit model state changed: \(oldState.map(String.init(describing:)) ?? "nil") -> \(stateString)")
        
        // Post notification for other parts of the app
        NotificationCenter.default.post(
            name: NSNotification.Name("WhisperKitModelStateChanged"),
            object: nil,
            userInfo: [
                "oldState": oldState.map(String.init(describing:)) ?? "unknown",
                "newState": stateString,
                "isLoading": isModelLoading,
                "isLoaded": isModelLoaded
            ]
        )
    }
    
    func getCurrentModelState() -> String {
        guard let whisperKit = whisperKit else { return "unloaded" }
        return String(describing: whisperKit.modelState)
    }
    
    func isCurrentlyLoadingModel() -> Bool {
        guard let whisperKit = whisperKit else { return false }
        return whisperKit.modelState == .loading || whisperKit.modelState == .prewarming
    }
    
    func isCurrentModelLoaded() -> Bool {
        guard let whisperKit = whisperKit else { return false }
        return whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed
    }
	
}

enum WhisperKitError: LocalizedError {
    case notInitialized
    case notReady
    case noModelLoaded
    case modelNotFound(String)
    case audioConversionFailed
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit not initialized. Please wait for startup to complete."
        case .notReady:
            return "WhisperKit not ready for transcription. Please wait a moment and try again."
        case .noModelLoaded:
            return "No AI model loaded. Please download a model first."
        case .modelNotFound(let model):
            return "Model '\(model)' not found in available models."
        case .audioConversionFailed:
            return "Failed to convert audio to required format."
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error)"
        }
    }
}
