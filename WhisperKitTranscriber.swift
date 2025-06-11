import Foundation
import AVFoundation
import WhisperKit
import SwiftUI
import AppKit

@MainActor
@Observable class WhisperKitTranscriber {
     var isInitialized = false
     var isInitializing = false
	 var shouldStreamAudio: Bool = true
     var initializationProgress: Double = 0.0
     var initializationStatus = "Starting..."
     var availableModels: [String] = []
     var currentModel: String?
     var downloadedModels: Set<String> = []
	 var currentText: String = ""
	 
	 // Live transcription state
	 var pendingText: String = ""
	 var lastPendingText: String = ""
	 var shouldShowWindow: Bool = false
	 var isTranscribing: Bool = false
	 
	 // Debug confirmed text state
	 var confirmedText: String = ""
	 var shouldShowDebugWindow: Bool = false
	 var decodingOptions: DecodingOptions?
	 // Get the display text for the window - use pending text
	 var displayText: String {
	 	return pendingText
	 }
	 
	 // Get the latest word from pending text
	 var latestWord: String {
	 	let words = pendingText.split(separator: " ")
	 	return words.last?.description ?? ""
	 }
	 
	 // Clear live transcription state
	 func clearLiveTranscriptionState() {
	 	pendingText = ""
	 	lastPendingText = ""
	 	shouldShowWindow = false
	 	isTranscribing = false
	 	shouldShowDebugWindow = false
	 }
    
    private var selectedLanguage: String {
        get {
            UserDefaults.standard.string(forKey: "selectedLanguage") ?? Constants.defaultLanguageName
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedLanguage")
        }
    }
        
    // WhisperKit model state tracking
    var modelState: String = "unloaded"
    var isModelLoading: Bool = false
    var isModelLoaded: Bool = false
    
	private func modelCacheDirectory(for modelName: String) -> URL? {
		guard let appSupport = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera/Models/\(modelName)")
	}
	
	var baseModelCacheDirectory: URL? {
		guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera")
	}
	
	private func whisperKitModelDirectory(for modelName: String?) -> URL? {
		let name = modelName ?? ""
		return baseModelCacheDirectory?.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)")
	}
	
    var isDownloadingModel = false {
        didSet {
            // Notify observers when download state changes
            if isDownloadingModel != oldValue {
                NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
            }
        }
    }
    var downloadProgress: Double = 0.0
    var downloadingModelName: String?
    
    @MainActor var whisperKit: WhisperKit?
	@MainActor var audioStreamer: AudioStreamTranscriber?
    @MainActor private var initializationTask: Task<Void, Never>?
    
    // Manual streaming properties (WhisperAX approach)
    @MainActor private var transcriptionTask: Task<Void, Never>?
    private var lastBufferSize: Int = 0
    private var realtimeDelayInterval: Double = 1.0
    private var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    
    // Swift 6 compliant singleton pattern
    static let shared: WhisperKitTranscriber = {
        let instance = WhisperKitTranscriber()
        return instance
    }()
    
	private init() {
		Task{
			downloadedModels = try await getDownloadedModels()
		}
    }
    
    func startInitialization() {
        guard initializationTask == nil else { 
            return 
        }
        
        isInitializing = true
        initializationProgress = 0.0
        initializationStatus = "Preparing to load AI models..."
        
        initializationTask = Task { @MainActor in
            await initialize()
        }
    }
    
    private func initialize() async {
        guard !isInitialized else {
            isInitializing = false
            return
        }
        await updateProgress(0.1, "Loading WhisperKit framework...")
        try? await Task.sleep(nanoseconds: 500_000_000) // Small delay for UI feedback
        
        await updateProgress(0.3, "Setting up AI framework...")
        
        // Sync our cache with what's actually on disk
        await updateProgress(0.6, "Checking for existing models...")
	
        if !downloadedModels.isEmpty {
            // Try to initialize WhisperKit with default configuration
            await updateProgress(0.8, "Loading existing model...")
            
            do {
                // Try to load with custom model directory
                whisperKit = try await Task { @MainActor in
                    let whisperKitInstance = try await WhisperKit(downloadBase: baseModelCacheDirectory)
                    self.setupModelStateCallback(for: whisperKitInstance)
                    return whisperKitInstance
                }.value
            } catch {
            }
        } else {
            // No models downloaded yet - we'll initialize when first model is downloaded
        }
        
        await updateProgress(1.0, "Ready for model selection!")
        isInitialized = true
        isInitializing = false
        
        initializationTask = nil
    }
	private func showModelNotLoadedAlert() {
		Task { @MainActor in
			let alert = NSAlert()
			alert.messageText = "Model Not Loaded"
			alert.informativeText = "Please load a Whisper model first before using streaming mode. You can do this in Settings."
			alert.alertStyle = .warning
			alert.addButton(withTitle: "OK")
			alert.runModal()
		}
	}
	
	private func initializeStreamer() async {
		// Return early if already initialized
		guard audioStreamer == nil else { 
			return 
		}
		
		guard let whisperKit = whisperKit else {
			showModelNotLoadedAlert()
			return
		}
		
		guard let tokenizer = whisperKit.tokenizer else {
			showModelNotLoadedAlert()
			return
		}
		
		// Get textDecoder (model should be loaded)
		let textDecoder = whisperKit.textDecoder
		
		guard let decodingOptions else {
			print("Decoding options not set yet, waiting...")
			return
		}
		
		audioStreamer = AudioStreamTranscriber(
			audioEncoder: whisperKit.audioEncoder,
			featureExtractor: whisperKit.featureExtractor,
			segmentSeeker: whisperKit.segmentSeeker,
			textDecoder: textDecoder,
			tokenizer: tokenizer,
			audioProcessor: whisperKit.audioProcessor,
			decodingOptions: decodingOptions,
			requiredSegmentsForConfirmation: 1,
			stateChangeCallback: { [weak self] oldState, newState in
				Task { @MainActor in
					guard let self = self else { return }
					
					let formatter = DateFormatter()
					formatter.dateFormat = "HH:mm:ss.SSS"
					let timestamp = formatter.string(from: Date())
					let newUnconfirmedText = if !newState.unconfirmedSegments.isEmpty {
						newState.unconfirmedSegments
							.map { $0.text.trimmingCharacters(in: .whitespaces) }
							.joined(separator: " ")
						
						
					} else {
						""
					}
					// Only update pending text if it actually changed
					if newUnconfirmedText != self.lastPendingText {
						self.lastPendingText = self.pendingText
						self.pendingText = newUnconfirmedText
						self.checkForFinalConfirmation()
					}
					
					// Show window when we have pending text
					let shouldShow = !self.pendingText.isEmpty
					
					if shouldShow != self.shouldShowWindow {
						self.shouldShowWindow = shouldShow
					}
					
					// Keep current text for backward compatibility
					let hasCurrentText = !newState.currentText.isEmpty &&
					!newState.currentText.contains("Waiting for speech")
					
					if hasCurrentText && newState.currentText != oldState.currentText {
						self.currentText = newState.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
					}
					// Handle confirmed segments for debug window
					if !newState.confirmedSegments.isEmpty &&
						newState.confirmedSegments.count != oldState.confirmedSegments.count {
						let newConfirmedText = newState.confirmedSegments
							.map { $0.text.trimmingCharacters(in: .whitespaces) }
							.joined(separator: " ")
						
						if newConfirmedText != self.confirmedText {
							self.confirmedText = newConfirmedText
							self.shouldShowDebugWindow = !newConfirmedText.isEmpty
							
							// Check if we're waiting for confirmation
							self.checkForFinalConfirmation()
						}
					}
					
					// When recording stops, add any remaining unconfirmed text
					if !newState.isRecording {
						let unconfirmedText = newState.unconfirmedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
						if !unconfirmedText.isEmpty && !self.confirmedText.hasSuffix(unconfirmedText) {
							// Split into words for better overlap detection
							let confirmedWords = self.confirmedText.split(separator: " ").map(String.init)
							let unconfirmedWords = unconfirmedText.split(separator: " ").map(String.init)
							
							var textToAppend = unconfirmedText
							
							// Check for word-level overlap
							if !confirmedWords.isEmpty && !unconfirmedWords.isEmpty {
								// Try to find overlap starting from the end of confirmed text
								for overlapSize in (1...min(confirmedWords.count, unconfirmedWords.count)).reversed() {
									let confirmedTail = confirmedWords.suffix(overlapSize)
									let unconfirmedHead = unconfirmedWords.prefix(overlapSize)
									
									if confirmedTail.elementsEqual(unconfirmedHead) {
										// Found word-level overlap, append only the non-overlapping part
										let remainingWords = unconfirmedWords.dropFirst(overlapSize)
										textToAppend = remainingWords.joined(separator: " ")
										break
									}
								}
							}
							
							if !textToAppend.isEmpty {
								self.confirmedText += " " + textToAppend
							}
						}
						self.clearLiveTranscriptionState()
					} else if !newState.isRecording && newState.unconfirmedText.isEmpty {
						self.clearLiveTranscriptionState()
					}
				}
			}
		)
		
	}
	
    private func updateProgress(_ progress: Double, _ status: String) async {
        await MainActor.run {
            self.initializationProgress = progress
            self.initializationStatus = status
        }
    }
	
	func checkIfWhisperKitIsAvailable() async throws {
		guard isInitialized else {
			throw WhisperKitError.notInitialized
		}
		guard let whisperKit = whisperKit else {
			throw WhisperKitError.noModelLoaded
		}
		guard whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed else {
			throw WhisperKitError.notReady
		}
	}
	
	func stream() async throws {
		try await checkIfWhisperKitIsAvailable()
		await initializeStreamer()
		confirmedText = ""
		isTranscribing = true
		try await audioStreamer?.startStreamTranscription()
	}
	
	private var isWaitingForConfirmation = false
	private var confirmationContinuation: CheckedContinuation<Void, Never>?
	
	func stopStreaming() async -> String {
		await audioStreamer?.stopStreamTranscription()
		
		// Wait until transcription is complete
		while isTranscribing {
			try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
		}
		
		return confirmedText
	}
	
	private func waitForFinalConfirmation() async {
		// If there are no unconfirmed segments, return immediately
		guard audioStreamer != nil else { return }
		
		// Set up waiting state
		isWaitingForConfirmation = true
		
		// Wait for confirmation or timeout after 3 seconds
		await withTimeout(seconds: 3.0) {
			await withCheckedContinuation { continuation in
				self.confirmationContinuation = continuation
				
				// Check immediately if already confirmed
				Task { @MainActor in
					self.checkForFinalConfirmation()
				}
			}
		}
		
		// Clean up
		isWaitingForConfirmation = false
		confirmationContinuation = nil
	}
	
	private func checkForFinalConfirmation() {
		// If we're waiting and there are no unconfirmed segments, we're done
		if isWaitingForConfirmation && pendingText.isEmpty {
			confirmationContinuation?.resume()
			confirmationContinuation = nil
		}
	}
	
	private func withTimeout(seconds: TimeInterval, operation: @escaping () async -> Void) async {
		await withTaskGroup(of: Void.self) { group in
			group.addTask {
				await operation()
			}
			
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			}
			
			// Wait for first task to complete, then cancel all
			await group.next()
			group.cancelAll()
		}
	}
	
	// MARK: - Manual Streaming Methods (WhisperAX approach)
	
	private func realtimeLoop() {
		transcriptionTask = Task {
			while isTranscribing {
				do {
					try await transcribeCurrentBuffer(delayInterval: Float(realtimeDelayInterval))
				} catch {
					print("Error in realtime loop: \(error.localizedDescription)")
					break
				}
			}
		}
	}
	
	private func stopRealtimeTranscription() {
		isTranscribing = false
		transcriptionTask?.cancel()
		transcriptionTask = nil
	}
	
	private func transcribeCurrentBuffer(delayInterval: Float = 1.0) async throws {
		guard let whisperKit = whisperKit else { return }
		
		// Check if model is actually loaded
		guard whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed else {
			await MainActor.run {
				pendingText = "Model not loaded..."
			}
			try await Task.sleep(nanoseconds: 500_000_000) // Wait 500ms
			return
		}
		
		// Retrieve the current audio buffer from the audio processor
		let currentBuffer = whisperKit.audioProcessor.audioSamples
		
		// Calculate the size and duration of the next buffer segment
		let nextBufferSize = currentBuffer.count - lastBufferSize
		let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
		
		// Only run the transcribe if the next buffer has at least `delayInterval` seconds of audio
		guard nextBufferSeconds > delayInterval else {
			await MainActor.run {
				if pendingText.isEmpty {
					pendingText = "Waiting for speech..."
				}
			}
			try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
			return
		}
		
		// Store this for next iterations
		lastBufferSize = currentBuffer.count
		
		// Transcribe the current buffer
		let transcription = try await transcribeAudioSamples(Array(currentBuffer))
		
		await MainActor.run {
			guard let segments = transcription?.segments else {
				return
			}
			
			// Update confirmed segments and pending text like the original approach
			if segments.count > 1 { // Using 2 for confirmation like WhisperAX default
				let numberOfSegmentsToConfirm = segments.count - 1
				let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
				let remainingSegments = Array(segments.suffix(1))
				
				// Add new confirmed text
				let newConfirmedText = confirmedSegmentsArray
					.map { $0.text.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
				
				if !newConfirmedText.isEmpty && !confirmedText.hasSuffix(newConfirmedText) {
					if !confirmedText.isEmpty {
						confirmedText += " " + newConfirmedText
					} else {
						confirmedText = newConfirmedText
					}
				}
				
				// Update pending text with unconfirmed segments
				pendingText = remainingSegments
					.map { $0.text.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
			} else {
				// All segments are unconfirmed
				pendingText = segments
					.map { $0.text.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
			}
			
			// Show window when we have pending text
			shouldShowWindow = !pendingText.isEmpty
		}
	}
	
	private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
		guard let whisperKit = whisperKit else { return nil }
		
		let languageCode = Constants.languageCode(for: selectedLanguage)
		let task: DecodingTask = .transcribe // Always transcribe for streaming
		
		let options = DecodingOptions(
			verbose: false,
			task: task,
			language: languageCode,
			temperature: 0.0,
			temperatureFallbackCount: 3, // More fallbacks for better accuracy
			sampleLength: 448, // Larger context window
			usePrefillPrompt: true,
			usePrefillCache: true,
			skipSpecialTokens: true,
			withoutTimestamps: false,
			wordTimestamps: true,
			clipTimestamps: [0]
		)
		
		// Decoding callback for real-time updates
		let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
			Task { @MainActor in
				// Update current text for decoder preview
				self.currentText = progress.text
			}
			return nil // Continue transcription
		}
		
		let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
			audioArray: samples,
			decodeOptions: options,
			callback: decodingCallback
		)
		
		return transcriptionResults.first
	}
    
	func transcribe(audioURL: URL, enableTranslation: Bool) async throws -> String {
		try await checkIfWhisperKitIsAvailable()
        
        // Implement retry mechanism for MPS resource loading failures
        let maxRetries = 3
        var lastError: Error?
		let task: DecodingTask = enableTranslation ? .transcribe : .translate // For some reason this gets reversed
		let languageCode = Constants.languageCode(for: selectedLanguage)

		decodingOptions = DecodingOptions(
				verbose: false,
				task: task,
				language: languageCode,
				temperature: 0.0,
				temperatureFallbackCount: 1,
				sampleLength: 224,
				usePrefillPrompt: true,
				usePrefillCache: true,
				detectLanguage: enableTranslation,
				skipSpecialTokens: true,
				withoutTimestamps: false,
				wordTimestamps: true,
				clipTimestamps: [0]
			)

        
        for attempt in 1...maxRetries {
            do {
                // Ensure transcription happens on MainActor for Swift 6 compliance
                let result = try await Task { @MainActor in
                    guard let whisperKitInstance = self.whisperKit else {
                        throw WhisperKitError.notInitialized
                    }
					if whisperKitInstance.modelState == .loading {
					}
                    
                    if attempt > 1 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s for MPS
                    }
					return try await whisperKitInstance.transcribe(audioPath: audioURL.path, decodeOptions: decodingOptions)
                }.value
                
                if !result.isEmpty {
                    let transcription = result.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !transcription.isEmpty {
                        
                        // Clean up processed file if different from original
                        if audioURL != audioURL {
                            try? FileManager.default.removeItem(at: audioURL)
                        }
                        
                        return transcription
                    } else {
                        return "No speech detected"
                    }
                } else {
                    return "No speech detected"
                }
                
            } catch {
                lastError = error
                let errorString = error.localizedDescription
                
                // Check if this is an MPS resource loading error that we can retry
                if errorString.contains("Failed to open resource file") || 
                   errorString.contains("MPSGraphComputePackage") ||
                   errorString.contains("Metal") {
                    
                    
                    if attempt < maxRetries {
                        // Exponential backoff: 1s, 2s, 4s
                        let delayNanoseconds = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                        
                        // Force MPS to reinitialize by giving it more time
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // Additional 1s for MPS
                    }
                } else {
                    // Non-MPS error, don't retry
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
        
        
        // Check if model is already downloaded
        let currentlyDownloadedModels = try await getDownloadedModels()
        
        if !currentlyDownloadedModels.contains(model) {
            try await downloadModel(model)
            return // downloadModel already creates the WhisperKit instance
        }
        
        isDownloadingModel = true
        downloadingModelName = model
        downloadProgress = 0.0
        
        do {
            await updateDownloadProgress(0.2, "Preparing to load \(model)...")
            
            _ = WhisperKit.recommendedModels()
            
            await updateDownloadProgress(0.6, "Loading \(model)...")
            // Use WhisperKit with specific model and custom model directory
            whisperKit = try await Task { @MainActor in
                let config = WhisperKitConfig(model: model, downloadBase: baseModelCacheDirectory)
                let whisperKitInstance = try await WhisperKit(config)
                self.setupModelStateCallback(for: whisperKitInstance)
                return whisperKitInstance
            }.value
            
            await updateDownloadProgress(0.9, "Finalizing model setup...")
            currentModel = model
            
            await updateDownloadProgress(1.0, "Model ready!")
            isDownloadingModel = false
            downloadingModelName = nil
            
        } catch {
            isDownloadingModel = false
            downloadingModelName = nil
            downloadProgress = 0.0
            
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
		// Get the WhisperKit models base directory (without specific model name)
		guard let baseDir = baseModelCacheDirectory?.appendingPathComponent("models/argmaxinc/whisperkit-coreml") else {
			throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access WhisperKit models directory"])
		}
		
		// Check if the models directory exists
		guard FileManager.default.fileExists(atPath: baseDir.path) else {
			return Set<String>()
		}
		
		do {
			let contents = try FileManager.default.contentsOfDirectory(
				at: baseDir,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)
		
			let modelDirectories = try contents.filter { url in
				let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
				return resourceValues.isDirectory == true
			}
		
			let modelNames = Set(modelDirectories.map { $0.lastPathComponent })
			return modelNames
			
		} catch {
			throw error
		}
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
            
        } catch {
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
			await updateDownloadProgress(0.2, "Downloading model...")

			// Use WhisperKit's download method with default location
			_ = try await WhisperKit.download(variant: modelName, downloadBase: baseModelCacheDirectory	)
            
            await updateDownloadProgress(0.8, "Initializing model...")
            
            // Initialize WhisperKit with the specific model name and custom model directory
            whisperKit = try await Task { @MainActor in
				let config = WhisperKitConfig(model: modelName, downloadBase: baseModelCacheDirectory)
                let whisperKitInstance = try await WhisperKit(config)
                self.setupModelStateCallback(for: whisperKitInstance)
                return whisperKitInstance
            }.value
            currentModel = modelName
            
            await updateDownloadProgress(1.0, "Model ready!")
            
        } catch {
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
        let appSupport = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
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
