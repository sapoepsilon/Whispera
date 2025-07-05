import Foundation
import AVFoundation
import AppKit
import SwiftUI

enum RecordingMode {
	case text
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
	@ObservationIgnored
	@AppStorage("useStreamingTranscription") var useStreamingTranscription = true
	
	private var audioRecorder: AVAudioRecorder?
	private var audioFileURL: URL?
	
	// Streaming audio properties
	private var audioEngine: AVAudioEngine?
	private var inputNode: AVAudioInputNode?
	private var audioBuffer: [Float] = []
	private let maxBufferSize = 16000 * 30 // 30 seconds at 16kHz
	private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
	let whisperKitTranscriber = WhisperKitTranscriber.shared
	private let recordingIndicator = RecordingIndicatorManager()
	
	override init() {
		super.init()
		whisperKitTranscriber.startInitialization()
	}
	
	
	func setupAudio() {
		checkAndRequestMicrophonePermission()
		if useStreamingTranscription {
			setupAudioEngine()
		} else {
			// If switching to file mode, clean up streaming resources
			cleanupAudioEngine()
		}
	}
	
	private func cleanupAudioEngine() {
		guard audioEngine != nil else { return }
		stopAudioEngine()
	}
	
	private func setupAudioEngine() {
		if audioEngine == nil {
			audioEngine = AVAudioEngine()
		}
		
		guard let audioEngine = audioEngine else {
			AppLogger.shared.audioManager.error("❌ Failed to create audio engine")
			return
		}
		
		// Only setup if not already running
		if !audioEngine.isRunning {
			inputNode = audioEngine.inputNode
			guard let inputNode = inputNode else {
				print("❌ Failed to get input node")
				return
			}
			
			let inputFormat = inputNode.outputFormat(forBus: 0)
			AppLogger.shared.audioManager.log("🎤 Input format: \(inputFormat)")
			AppLogger.shared.audioManager.log("🎤 Installing initial microphone tap for streaming setup")
			inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
				self?.processAudioBuffer(buffer, originalFormat: inputFormat)
			}
			print("✅ Initial microphone tap installed - mic indicator should be ON")
			
			do {
				try audioEngine.start()
				print("✅ Audio engine started successfully for streaming")
			} catch {
				print("❌ Failed to start audio engine: \(error)")
				print("⚠️ Falling back to file-based recording")
				// Automatically switch to file-based mode if streaming fails
				useStreamingTranscription = false
			}
		}
	}
	
	private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, originalFormat: AVAudioFormat) {
		guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
			print("❌ Failed to create target format")
			return
		}
		
		if originalFormat != targetFormat {
			guard let converter = AVAudioConverter(from: originalFormat, to: targetFormat) else {
				print("❌ Failed to create audio converter")
				return
			}
			
			let ratio = targetFormat.sampleRate / originalFormat.sampleRate
			let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
			
			guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
				print("❌ Failed to create converted buffer")
				return
			}
			
			var error: NSError?
			converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
				outStatus.pointee = .haveData
				return buffer
			}
			
			if let error = error {
				print("❌ Audio conversion error: \(error)")
				return
			}
			
			// Process converted buffer
			extractFloatData(from: convertedBuffer)
		} else {
			// No conversion needed
			extractFloatData(from: buffer)
		}
	}
	
	private func extractFloatData(from buffer: AVAudioPCMBuffer) {
		guard let channelData = buffer.floatChannelData?[0] else { return }
		let frameCount = Int(buffer.frameLength)
		
		let audioData = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
		
		audioBuffer.append(contentsOf: audioData)
		
		if audioBuffer.count > maxBufferSize {
			let excessCount = audioBuffer.count - maxBufferSize
			audioBuffer.removeFirst(excessCount)
		}
	}
	
	private func stopAudioEngine() {
		if let inputNode = inputNode {
			print("🔇 Removing microphone tap during engine cleanup")
			inputNode.removeTap(onBus: 0)
			print("✅ Microphone tap removed during cleanup")
		}
		audioEngine?.stop()
		audioEngine = nil
		inputNode = nil
		print("🛑 Audio engine stopped and cleaned up")
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
			if useStreamingTranscription {
				startStreamingRecording()
			} else {
				performStartRecording()
			}
		case .notDetermined:
			// Request permission first
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						if self.useStreamingTranscription {
							self.startStreamingRecording()
						} else {
							self.performStartRecording()
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
		if useStreamingTranscription {
			stopStreamingRecording()
		} else {
			stopFileBasedRecording()
		}
	}
	
	private func stopFileBasedRecording() {
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
	
	// MARK: - Streaming Recording Methods
	
	private func startStreamingRecording() {
		audioBuffer.removeAll()
		
		if audioEngine?.isRunning != true {
			setupAudioEngine()
		} else {
			// Engine is running, just reinstall the tap for microphone access
			guard let inputNode = inputNode else { 
				print("❌ No input node available for tap installation")
				return 
			}
			let inputFormat = inputNode.outputFormat(forBus: 0)
			print("🎤 Installing microphone tap for streaming recording")
			inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
				self?.processAudioBuffer(buffer, originalFormat: inputFormat)
			}
			print("✅ Microphone tap installed - mic indicator should be ON")
		}
		
		isRecording = true
		playFeedbackSound(start: true)
		print("🎤 Streaming recording started")
	}
	
	private func stopStreamingRecording() {
		isRecording = false
		playFeedbackSound(start: false)
		
		// Get the accumulated audio buffer
		let capturedAudio = audioBuffer
		
		// Clear buffer for next recording
		audioBuffer.removeAll()
		
		if !capturedAudio.isEmpty {
			Task {
				await transcribeAudioBuffer(audioArray: capturedAudio, enableTranslation: self.enableTranslation)
			}
		} else {
			print("⚠️ No audio captured during streaming recording")
		}
		
		if let inputNode = inputNode {
			inputNode.removeTap(onBus: 0)
			print("🔇 Tap removed")
		}
		audioEngine?.stop()
		audioEngine?.reset()
		AppLogger.shared.audioManager.log("🛑 Streaming recording stopped, microphone released")
	}
	
	private func transcribeAudioBuffer(audioArray: [Float], enableTranslation: Bool) async {
		isTranscribing = true
		transcriptionError = nil
		
		do {
			// Use the new audio array transcription method
			let transcription = try await whisperKitTranscriber.transcribeAudioArray(audioArray, enableTranslation: enableTranslation)
			
			// Update UI on main thread
			await MainActor.run {
				lastTranscription = transcription
				isTranscribing = false
				
				// Route based on recording mode
				switch currentRecordingMode {
				case .text:
					// Traditional behavior - paste to focused app
					pasteToFocusedApp(transcription)
				}
			}
		} catch {
			await MainActor.run {
				transcriptionError = error.localizedDescription
				lastTranscription = "Transcription failed: \(error.localizedDescription)"
				isTranscribing = false
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
		
		func getApplicationSupportDirectory() -> URL {
			let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			let appDirectory = appSupport.appendingPathComponent("Whispera")
			
			// Ensure app directory exists
			try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
			
			return appDirectory
		}
		
	}
	

