import Foundation
import AVFoundation
import WhisperKit

@MainActor
class WhisperKitTranscriber: ObservableObject {
    @Published var isInitialized = false
    @Published var availableModels: [String] = []
    @Published var currentModel: String?
    @Published var downloadedModels: Set<String> = []
    
    private var whisperKit: WhisperKit?
    private var initializationTask: Task<Void, Never>?
    
    static let shared = WhisperKitTranscriber()
    
    private init() {
        // Don't start initialization in init - wait for explicit call
    }
    
    func startInitialization() {
        guard initializationTask == nil else { 
            print("📋 WhisperKit initialization already in progress...")
            return 
        }
        
        initializationTask = Task {
            await initialize()
        }
    }
    
    private func initialize() async {
        guard !isInitialized else {
            print("📋 WhisperKit already initialized")
            return
        }
        
        do {
            print("🔄 Initializing WhisperKit...")
            
            // Get the user's selected model from settings
            let selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"
            print("📋 User selected model: \(selectedModel)")
            
            // Initialize WhisperKit with the selected model
            whisperKit = try await WhisperKit(WhisperKitConfig(model: selectedModel))
            
            if whisperKit != nil {
                // Get available models
                do {
                    availableModels = try await WhisperKit.fetchAvailableModels()
                } catch {
                    print("Failed to get the available models")
                }
                
                // Set current model to what was actually loaded
                currentModel = selectedModel
                
                // Mark the current model as downloaded since WhisperKit successfully initialized with it
                if let currentModel = currentModel {
                    downloadedModels.insert(currentModel)
                }
                
                isInitialized = true
                
                print("✅ WhisperKit initialized with model: \(currentModel ?? "none")")
                print("📋 Available models: \(availableModels)")
                print("💾 Downloaded models: \(downloadedModels)")
            } else {
                print("❌ Failed to create WhisperKit instance")
                isInitialized = false
            }
        } catch {
            print("❌ Failed to initialize WhisperKit with selected model, falling back to default: \(error)")
            
            // Fall back to default if selected model fails
            do {
                whisperKit = try await WhisperKit()
                if whisperKit != nil {
                    do {
                        availableModels = try await WhisperKit.fetchAvailableModels()
                    } catch {
                        print("Failed to get the available models")
                    }
                    currentModel = "openai_whisper-base"
                    
                    if let currentModel = currentModel {
                        downloadedModels.insert(currentModel)
                    }
                    
                    isInitialized = true
                    print("✅ WhisperKit initialized with fallback model: \(currentModel ?? "none")")
                }
            } catch {
                print("❌ Failed to initialize WhisperKit even with fallback: \(error)")
                isInitialized = false
            }
        }
        
        initializationTask = nil
    }
    
    func transcribe(audioURL: URL) async throws -> String {
        guard isInitialized else {
            throw WhisperKitError.notInitialized
        }
        
        print("🎤 Starting transcription of: \(audioURL.lastPathComponent)")
        
        // Convert to format WhisperKit expects if needed
        let processedURL = try await prepareAudioForWhisperKit(audioURL)
        
        guard let whisperKit = whisperKit else {
            throw WhisperKitError.notInitialized
        }
        
        do {
            print("🎤 Starting real WhisperKit transcription...")
            
            let result = try await whisperKit.transcribe(audioPath: processedURL.path)
            let transcription = result.first?.text ?? "No speech detected"
            
            print("✅ WhisperKit transcription completed: \(transcription)")
            
            // Clean up processed file if different from original
            if processedURL != audioURL {
                try? FileManager.default.removeItem(at: processedURL)
            }
            
            return transcription
            
        } catch {
            print("❌ WhisperKit transcription failed: \(error)")
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }
    
    func switchModel(to model: String) async throws {
        guard availableModels.contains(model) else {
            throw WhisperKitError.modelNotFound(model)
        }
        
        print("🔄 Switching to model: \(model)")
        
        do {
            let recommendedModels = WhisperKit.recommendedModels()
            print("👂🏼 Recommended models: \(recommendedModels)")
			whisperKit = try await WhisperKit(WhisperKitConfig(model: model))
            currentModel = model
            
            // Add to downloaded models set
            downloadedModels.insert(model)
            
            print("✅ Switched to model: \(model)")
        } catch {
            print("❌ Failed to switch to model \(model): \(error)")
            throw WhisperKitError.transcriptionFailed("Failed to load model: \(error.localizedDescription)")
        }
    }
    
    func getDownloadedModels() async throws -> Set<String> {
        // For now, we'll use a simple approach - check if models exist locally
        // In a real implementation, you might want to check the WhisperKit model cache directory
        return downloadedModels
    }
    
    func refreshAvailableModels() async throws {
        do {
            availableModels = try await WhisperKit.fetchAvailableModels()
            print("✅ Refreshed available models: \(availableModels)")
        } catch {
            print("❌ Failed to refresh available models: \(error)")
            throw error
        }
    }
    
    func getRecommendedModels() -> (default: String, supported: [String]) {
        let recommended = WhisperKit.recommendedModels()
        return (default: recommended.default, supported: recommended.supported)
    }
    
    private func prepareAudioForWhisperKit(_ audioURL: URL) async throws -> URL {
        // WhisperKit works with various formats, but let's ensure it's in a good format
        // For now, just return the original URL
        return audioURL
    }
    
    private func getAudioDuration(_ audioURL: URL) async throws -> Double {
        let asset = AVAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    func downloadModel(_ modelName: String) async throws {
        guard whisperKit != nil else {
            throw WhisperKitError.notInitialized
        }
        
        print("📥 Downloading model: \(modelName)")
        
        do {
            // Download the model without switching to it
            let _ = try await WhisperKit.download(variant: modelName)
            downloadedModels.insert(modelName)
            print("✅ Successfully downloaded model: \(modelName)")
        } catch {
            print("❌ Failed to download model \(modelName): \(error)")
            throw error
        }
    }
    
}

enum WhisperKitError: LocalizedError {
    case notInitialized
    case modelNotFound(String)
    case audioConversionFailed
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit not initialized. Please wait for startup to complete."
        case .modelNotFound(let model):
            return "Model '\(model)' not found in available models."
        case .audioConversionFailed:
            return "Failed to convert audio to required format."
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error)"
        }
    }
}
