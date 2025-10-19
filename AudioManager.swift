import Foundation
import AVFoundation
import AppKit
import SwiftUI

enum RecordingMode {
	case text
	case liveTranscription
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

	// Recording duration tracking
	var recordingDuration: TimeInterval = 0.0
	private var recordingStartTime: Date?
	private var recordingTimer: Timer?

	// Audio level tracking for visualizations
	var audioLevels: [Float] = Array(repeating: 0.0, count: 7)
	
	
	@ObservationIgnored
	@AppStorage("enableTranslation") var enableTranslation = false
	@ObservationIgnored
	@AppStorage("useStreamingTranscription") var useStreamingTranscription = true
	@ObservationIgnored
	@AppStorage("enableStreaming") var enableStreaming = true
	@ObservationIgnored
	@AppStorage("autoDetectLanguageFromKeyboard") var autoDetectLanguageFromKeyboard = false
	@ObservationIgnored
	@AppStorage("selectedLanguage") var selectedLanguage = Constants.defaultLanguageName
	
	private var audioRecorder: AVAudioRecorder?
	private var audioFileURL: URL?
	
	// Streaming audio properties
	private var audioEngine: AVAudioEngine?
	private var inputNode: AVAudioInputNode?
	private var audioBuffer: [Float] = []
	private let maxBufferSize = 16000 * 1800 // 30 minutes at 16kHz
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
			cleanupAudioEngine()
		}
	}
	
	// MARK: - Recording Duration Management
	private func startRecordingTimer() {
		recordingStartTime = Date()
		recordingDuration = 0.0
		
		recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self, let startTime = self.recordingStartTime else { return }
				self.recordingDuration = Date().timeIntervalSince(startTime)
			}
		}
	}
	
	private func stopRecordingTimer() {
		recordingTimer?.invalidate()
		recordingTimer = nil
		recordingStartTime = nil
	}
	
	private func resetRecordingTimer() {
		recordingDuration = 0.0
		recordingStartTime = nil
	}
	
	func formattedRecordingDuration() -> String {
		let minutes = Int(recordingDuration) / 60
		let seconds = Int(recordingDuration) % 60
		let milliseconds = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
		return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
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

		updateAudioLevels(from: audioData)
	}

	private func updateAudioLevels(from audioData: [Float]) {
		let bandCount = audioLevels.count
		let samplesPerBand = max(1, audioData.count / bandCount)

		Task { @MainActor in
			var newLevels: [Float] = []

			for i in 0..<bandCount {
				let startIndex = i * samplesPerBand
				let endIndex = min(startIndex + samplesPerBand, audioData.count)

				guard startIndex < audioData.count else {
					newLevels.append(0.0)
					continue
				}

				let bandSamples = Array(audioData[startIndex..<endIndex])
				let rms = sqrt(bandSamples.map { $0 * $0 }.reduce(0, +) / Float(bandSamples.count))
				let normalizedLevel = min(1.0, rms * 5.0)

				newLevels.append(normalizedLevel)
			}

			self.audioLevels = newLevels
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
	
	func toggleRecording() {
		// Set the recording mode based on settings
		currentRecordingMode = enableStreaming ? .liveTranscription : .text
		
		if isRecording {
			stopRecording()
		} else {
			startRecording()
		}
	}
	
	private func detectAndSetKeyboardLanguage() {
		let detectedLanguage = KeyboardInputSourceManager.shared.getLanguageForRecording(
			autoDetectEnabled: autoDetectLanguageFromKeyboard,
			manualLanguage: selectedLanguage
		)

		if detectedLanguage != selectedLanguage {
			AppLogger.shared.audioManager.info("🔄 Updating language from \(selectedLanguage) to \(detectedLanguage)")
			selectedLanguage = detectedLanguage
		}
	}

	private func startRecording() {
		detectAndSetKeyboardLanguage()

		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			if currentRecordingMode == .liveTranscription {
				startLiveTranscription()
			} else if useStreamingTranscription {
				startStreamingRecording()
			} else {
				performStartRecording()
			}
		case .notDetermined:
			// Request permission first
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						if self.currentRecordingMode == .liveTranscription {
							self.startLiveTranscription()
						} else if self.useStreamingTranscription {
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
			startRecordingTimer()
			
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
		if currentRecordingMode == .liveTranscription {
			stopLiveTranscription()
		} else if useStreamingTranscription {
			stopStreamingRecording()
		} else {
			stopFileBasedRecording()
		}
	}
	
	private func stopFileBasedRecording() {
		audioRecorder?.stop()
		audioRecorder = nil
		isRecording = false
		stopRecordingTimer()
		
		// Hide visual indicator
		//        recordingIndicator.hideIndicator()
		
		playFeedbackSound(start: false)
		
		if let audioFileURL = audioFileURL {
			Task {
				await transcribeAudio(fileURL: audioFileURL, enableTranslation: self.enableTranslation)
			}
		}
		
		// Reset timer after a brief delay to allow UI to show final duration
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.resetRecordingTimer()
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
			AppLogger.shared.audioManager.debug("🎤 Installing microphone tap for streaming recording")
			inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
				self?.processAudioBuffer(buffer, originalFormat: inputFormat)
			}
			AppLogger.shared.audioManager.info("✅ Microphone tap installed - mic indicator should be ON")
		}
		
		isRecording = true
		startRecordingTimer()
		playFeedbackSound(start: true)
		print("🎤 Streaming recording started")
	}
	
	private func stopStreamingRecording() {
		isRecording = false
		stopRecordingTimer()
		playFeedbackSound(start: false)
		
		let capturedAudio = audioBuffer
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
		
		// Reset timer after a brief delay to allow UI to show final duration
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.resetRecordingTimer()
		}
	}
	
	// MARK: - Live Transcription Methods
	private func startLiveTranscription() {
		isRecording = true
		startRecordingTimer()
		playFeedbackSound(start: true)
		whisperKitTranscriber.clearLiveTranscriptionState()
		
		Task {
			do {
				try await whisperKitTranscriber.liveStream()
				AppLogger.shared.audioManager.info("🎤 Live transcription started")
			} catch {
				await MainActor.run {
					self.isRecording = false
					self.stopRecordingTimer()
					print("❌ Failed to start live transcription: \(error)")
				}
			}
		}
	}
	
	private func stopLiveTranscription() {
		isRecording = false
		stopRecordingTimer()
		playFeedbackSound(start: false)
		
		whisperKitTranscriber.stopLiveStream()
		AppLogger.shared.audioManager.info("🛑 Live transcription stopped")
		
		// Reset timer after a brief delay to allow UI to show final duration
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.resetRecordingTimer()
		}
	}
	
	private func transcribeAudioBuffer(audioArray: [Float], enableTranslation: Bool) async {
		isTranscribing = true
		transcriptionError = nil
		
		do {
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
				case .liveTranscription:
					// Live transcription mode - no automatic pasting
					break
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
				case .liveTranscription:
					// Live transcription mode - no automatic pasting
					break
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
		
			print("Pasting to the focused app: \(text)")
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
	

