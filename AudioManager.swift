import Foundation
import AVFoundation
import AppKit
import SwiftUI

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
    @Published var isStreaming = false
    @Published var transcriptionError: String?
    
    @AppStorage("enableTranslation") var enableTranslation = false
    @AppStorage("enableStreaming") var enableStreaming = true
    
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
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                    } else {
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
        case .denied, .restricted:
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
    
    func toggleRecording() {
		        if enableStreaming {
            Task {
                if isStreaming {
                    await stopStreamingTranscription()
                } else {
                    await startStreamingTranscription()
                }
            }
        } else {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }
    }

    private func stopStreamingTranscription() async {
        let finalTranscription = await whisperKitTranscriber.stopStreaming()
        
        await MainActor.run {
            isStreaming = false
            isTranscribing = false
            lastTranscription = finalTranscription
            
            if !finalTranscription.isEmpty {
                pasteToFocusedApp(finalTranscription)
            }
            
            playFeedbackSound(start: false)
        }
    }
    
    private func startStreamingTranscription() async {
        // Check permissions before streaming
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            await performStreamingTranscription()
        case .notDetermined:
            // Request permission first
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        Task {
                            await self.performStreamingTranscription()
                        }
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
    
    private func performStreamingTranscription() async {
        await MainActor.run {
            isStreaming = true
            isTranscribing = true
            transcriptionError = nil
            playFeedbackSound(start: true)
        }
        
        do {
            try await whisperKitTranscriber.stream()
        } catch {
            await MainActor.run {
                isStreaming = false
                isTranscribing = false
                transcriptionError = error.localizedDescription
                lastTranscription = "Streaming failed: \(error.localizedDescription)"
                playFeedbackSound(start: false)
            }
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
        } catch {
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
            // Use file-based transcription (streaming is handled separately)
            let transcription = try await whisperKitTranscriber.transcribe(audioURL: fileURL, enableTranslation: enableTranslation)
            
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            
            keyDownEvent?.flags = .maskCommand
            keyUpEvent?.flags = .maskCommand
            
            keyDownEvent?.post(tap: .cghidEventTap)
            keyUpEvent?.post(tap: .cghidEventTap)
        }
    }
    
    private func getApplicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("Whispera")
        
        // Ensure app directory exists
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        
        return appDirectory
    }
}
