import Foundation
import AVFoundation
import WhisperKit

@MainActor
class RealtimeAudioManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isStreaming = false
    @Published var partialTranscription = ""
    @Published var finalTranscription = ""
    @Published var streamingError: String?
    @Published var audioLevel: Float = 0.0
    
    // MARK: - Private Properties
    private let whisperKitTranscriber = WhisperKitTranscriber.shared
    private var isConfigured = false
    private var isUsingFallback = false
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: CircularAudioBuffer?
    private var processingTimer: Timer?
    
    // MARK: - Configuration
    private let sampleRate: Double = 16000.0
    private let bufferDuration: TimeInterval = 30.0
    private let chunkDuration: TimeInterval = 2.0
    
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// Start real-time streaming transcription using WhisperKit's AudioStreamTranscriber
    func startStreaming() async {
        guard !isStreaming else { 
            print("🚫 Already streaming, ignoring start request")
            return 
        }
        
        print("🎤 Starting real-time streaming transcription with AudioStreamTranscriber...")
        
        do {
            // Initialize WhisperKit if not already done
            if !isConfigured {
                print("🔧 Initializing WhisperKit...")
                await whisperKitTranscriber.startInitialization()
                
                // Wait for initialization to complete
                var attempts = 0
                while !whisperKitTranscriber.isInitialized && attempts < 30 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    attempts += 1
                }
                
                guard whisperKitTranscriber.isInitialized else {
                    throw WhisperKitError.notInitialized
                }
                
                isConfigured = true
                print("✅ WhisperKit initialized for streaming")
            }
            
            // Clear previous state
            clearTranscriptions()
            
            // Try to start WhisperKit's AudioStreamTranscriber
            do {
                try await whisperKitTranscriber.startStreamTranscription { [weak self] result in
                    Task { @MainActor in
                        self?.updateTranscriptions(with: result)
                    }
                }
                
                isStreaming = true
                isUsingFallback = false
                print("✅ Real-time streaming started with WhisperKit AudioStreamTranscriber")
                
            } catch {
                print("⚠️ AudioStreamTranscriber not available, using fallback approach: \(error)")
                
                // Fallback: use manual audio processing
                try startFallbackStreaming()
                isStreaming = true
                isUsingFallback = true
                print("✅ Real-time streaming started with fallback approach")
            }
            
        } catch {
            streamingError = "Failed to start streaming: \(error.localizedDescription)"
            print("❌ Failed to start streaming: \(error)")
        }
    }
    
    /// Stop real-time streaming
    func stopStreaming() async {
        guard isStreaming else { return }
        
        isStreaming = false
        
        // Stop WhisperKit's AudioStreamTranscriber
        await whisperKitTranscriber.stopStreamTranscription()
        
        print("✅ Real-time streaming stopped")
    }
    
    /// Toggle streaming state
    func toggleStreaming() async {
        if isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }
    
    // MARK: - Private Methods
    
    private func updateTranscriptions(with result: StreamingResult) {
        let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedText.isEmpty else { return }
        
        if result.isPartial {
            partialTranscription = trimmedText
            print("📝 Partial: '\(partialTranscription)'")
        } else {
            // This is final text - check if it's new content to paste
            let previousFinalLength = finalTranscription.count
            
            // Extract only the new part by checking what's actually new
            var newContent = trimmedText
            
            // If this result contains our previous final text, extract only the new part
            if trimmedText.hasPrefix(finalTranscription) && trimmedText.count > finalTranscription.count {
                let startIndex = trimmedText.index(trimmedText.startIndex, offsetBy: finalTranscription.count)
                newContent = String(trimmedText[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // If we have genuinely new content, paste it immediately
            if !newContent.isEmpty && newContent != finalTranscription {
                print("🔥 NEW FINAL TEXT to paste immediately: '\(newContent)'")
                
                // Paste this new final text right away
                NotificationCenter.default.post(
                    name: NSNotification.Name("PasteImmediateText"), 
                    object: newContent
                )
            }
            
            // Update our final transcription
            finalTranscription = trimmedText
            partialTranscription = ""
            
            print("📝 Final updated: '\(finalTranscription)'")
        }
    }
    
    private func clearTranscriptions() {
        partialTranscription = ""
        finalTranscription = ""
        streamingError = nil
    }
    
    // MARK: - Audio Level Monitoring
    
    var currentAudioLevel: Float {
        // AudioStreamTranscriber handles audio internally
        // We could expose this through a callback if needed
        return audioLevel
    }
}

// MARK: - Configuration Extensions

extension RealtimeAudioManager {
    /// Check if real-time transcription is enabled in settings
    static var isRealtimeEnabled: Bool {
        // Check if the key exists, if not, default to true
        if UserDefaults.standard.object(forKey: "realtimeTranscription") == nil {
            UserDefaults.standard.set(true, forKey: "realtimeTranscription")
            return true
        }
        return UserDefaults.standard.bool(forKey: "realtimeTranscription")
    }
    
    /// Get transcription text for display
    var displayText: String {
        if !partialTranscription.isEmpty {
            return finalTranscription + (finalTranscription.isEmpty ? "" : " ") + partialTranscription
        }
        return finalTranscription
    }
    
    /// Check if there's any transcribed content
    var hasContent: Bool {
        return !finalTranscription.isEmpty || !partialTranscription.isEmpty
    }
}