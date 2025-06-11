import Foundation
import AVFoundation
import AppKit
import SwiftUI

enum RecordingMode {
	case text    // Speech to text (copy to clipboard)
	case command // Speech to command (execute via LLM)
}

@MainActor
@Observable class AudioManager: NSObject {
     var isRecording = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
        }
    }
     var lastTranscription: String?
     var isTranscribing = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingStateChanged"), object: nil)
        }
    }
	var transcriptionError: String?
	var currentRecordingMode: RecordingMode = .text
	

	@ObservationIgnored
	@AppStorage("enableTranslation") var enableTranslation = false
	
    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    let whisperKitTranscriber = WhisperKitTranscriber.shared
	private let recordingIndicator = RecordingIndicatorManager()
    
    override init() {
        super.init()
        whisperKitTranscriber.startInitialization()
    }
    
	func setupAudio() {
        checkAndRequestMicrophonePermission()
    }
    
    private func checkAndRequestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            print("🎤 Microphone permission not determined, requesting...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Microphone access granted")
                    } else {
                        print("❌ Microphone access denied")
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
        case .denied, .restricted:
            print("❌ Microphone access denied or restricted")
            showMicrophonePermissionAlert()
        case .authorized:
            print("✅ Microphone already authorized")
        @unknown default:
            break
        }
    }
    
    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Whispera needs access to your microphone to transcribe audio. Please grant permission in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    func toggleRecording(mode: RecordingMode = .text) {
		// Set the recording mode before starting
		currentRecordingMode = mode
		print("🎤 Toggle recording - Mode: \(mode)")

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        // Check permissions before recording
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            performStartRecording()
        case .notDetermined:
            // Request permission first
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.performStartRecording()
                    } else {
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
        case .denied, .restricted:
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }
    
    private func performStartRecording() {
        let appSupportPath = getApplicationSupportDirectory()
        let audioFilename = appSupportPath.appendingPathComponent("recordings").appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        audioFileURL = audioFilename
        
        // Ensure recordings directory exists
        try? FileManager.default.createDirectory(at: audioFilename.deletingLastPathComponent(), withIntermediateDirectories: true)
        
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
//            recordingIndicator.showIndicator()
            
            playFeedbackSound(start: true)
            print("🎤 Recording started successfully")
        } catch {
            print("❌ Failed to start recording: \(error)")
            // Show error alert
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = "Failed to start recording: \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
    
	private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        
        // Hide visual indicator
//        recordingIndicator.hideIndicator()
        
        playFeedbackSound(start: false)
        
        if let audioFileURL = audioFileURL {
            Task {
				await transcribeAudio(fileURL: audioFileURL, enableTranslation: self.enableTranslation)
            }
        }
    }
    
    private func playFeedbackSound(start: Bool) {
        guard UserDefaults.standard.bool(forKey: "soundFeedback") else { return }
        
        let soundName = start ? 
            UserDefaults.standard.string(forKey: "startSound") ?? "Tink" :
            UserDefaults.standard.string(forKey: "stopSound") ?? "Pop"
        
        guard soundName != "None" else { return }
        
        NSSound(named: soundName)?.play()
    }
	
    
	private func transcribeAudio(fileURL: URL, enableTranslation: Bool) async {
        isTranscribing = true
        transcriptionError = nil
        
        do {
            // Always use real WhisperKit transcription
            let transcription = try await whisperKitTranscriber.transcribe(audioURL: fileURL, enableTranslation: enableTranslation)
            
            // Update UI on main thread
            await MainActor.run {
                lastTranscription = transcription
                isTranscribing = false
                
                // Route based on recording mode
                switch currentRecordingMode {
                case .text:
                    // Traditional behavior - paste to focused app
                    pasteToFocusedApp(transcription)
                case .command:
                    // Send to LLM for command generation and execution
                    processCommandMode(transcription: transcription)
                }
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
    
    private func getApplicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("Whispera")
        
        // Ensure app directory exists
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        
        return appDirectory
    }
	
	private func processCommandMode(transcription: String) {
		print("🤖 Processing command mode transcription: \(transcription)")
		
		Task {
			// Generate and execute command using LlamaState
			let _ = await LlamaState.shared.generateAndExecuteBashCommand(userRequest: transcription)
		}
	}
}
