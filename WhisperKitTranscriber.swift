import Foundation
import AVFoundation
import WhisperKit

@MainActor
class WhisperKitTranscriber: ObservableObject {
    @Published var isInitialized = false
    @Published var availableModels: [String] = []
    @Published var currentModel: String?
    
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
            
            whisperKit = try await WhisperKit()
            
            if let whisperKit = whisperKit {
                // Use default model for now - WhisperKit will download it automatically
                availableModels = ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small"]
                currentModel = "openai_whisper-base"
                isInitialized = true
                
                print("✅ WhisperKit initialized with model: \(currentModel ?? "none")")
                print("📋 Available models: \(availableModels)")
            } else {
                print("❌ Failed to create WhisperKit instance")
                isInitialized = false
            }
        } catch {
            print("❌ Failed to initialize WhisperKit: \(error)")
            isInitialized = false
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
            whisperKit = try await WhisperKit(WhisperKitConfig(modelRepo: model))
            currentModel = model
            print("✅ Switched to model: \(model)")
        } catch {
            print("❌ Failed to switch to model \(model): \(error)")
            throw WhisperKitError.transcriptionFailed("Failed to load model: \(error.localizedDescription)")
        }
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
