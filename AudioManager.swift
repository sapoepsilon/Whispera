import Foundation
import AVFoundation
import AppKit

@MainActor
class AudioManager: NSObject, ObservableObject {
    @Published var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
        }
    }
    @Published var lastTranscription: String?
    @Published var isTranscribing = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
        }
    }
    @Published var transcriptionError: String?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    private let whisperKitTranscriber = WhisperKitTranscriber.shared
	private let recordingIndicator = RecordingIndicatorManager()
    
    override init() {
        super.init()
        setupAudio()
        
        // Initialize WhisperKit once
        whisperKitTranscriber.startInitialization()
    }
    
    private func setupAudio() {
        // macOS doesn't use AVAudioSession - permissions are handled at the system level
        // Request microphone permission if needed
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("Microphone access denied")
                }
            }
        case .denied, .restricted:
            print("Microphone access denied or restricted")
        case .authorized:
            break
        @unknown default:
            break
        }
    }
    
    func toggleRecording() {
        print("🎙️ toggleRecording called, current state: \(isRecording)")
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        audioFileURL = audioFilename
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            isRecording = true
            
            // Show visual indicator
            recordingIndicator.showIndicator()
            
            playFeedbackSound(start: true)
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        
        // Hide visual indicator
        recordingIndicator.hideIndicator()
        
        playFeedbackSound(start: false)
        
        if let audioFileURL = audioFileURL {
            Task {
                await transcribeAudio(fileURL: audioFileURL)
            }
        }
    }
    
    private func playFeedbackSound(start: Bool) {
        if UserDefaults.standard.bool(forKey: "soundFeedback") {
            if start {
                NSSound(named: "Tink")?.play()
            } else {
                NSSound(named: "Pop")?.play()
            }
        }
    }
    
    private func transcribeAudio(fileURL: URL) async {
        isTranscribing = true
        transcriptionError = nil
        
        do {
            // Use WhisperKit for transcription (much simpler!)
            let transcription = try await whisperKitTranscriber.transcribe(audioURL: fileURL)
            
            // Update UI on main thread
            await MainActor.run {
                lastTranscription = transcription
                isTranscribing = false
                
                // Paste to focused app
                pasteToFocusedApp(transcription)
            }
            
        } catch {
            await MainActor.run {
                transcriptionError = error.localizedDescription
                lastTranscription = "Transcription failed: \(error.localizedDescription)"
                isTranscribing = false
            }
        }
        
        // Clean up audio file
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    private func pasteToFocusedApp(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Simulate Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
}
