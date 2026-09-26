import AVFoundation
import AppKit
import Foundation
import SwiftUI
import WhisperKit

enum RecordingMode {
	case text
	case liveTranscription
}

enum AudioState {
	case idle
	case initializing
	case recording
	case transcribing
}

// Both recording windows route through this policy so they can never disagree
// via separate preferences: exactly one surface is eligible per recording mode.
enum RecordingWindowPolicy {
	static func shouldShowListeningWindow(state: AudioState, mode: RecordingMode) -> Bool {
		state != .idle && mode == .text
	}

	static func shouldShowLiveTranscriptionWindow(
		mode: RecordingMode, transcriberWantsWindow: Bool
	) -> Bool {
		mode == .liveTranscription && transcriberWantsWindow
	}
}

@MainActor
@Observable
final class AudioManager: NSObject {
	// MARK: - Observable State

	var isRecording = false {
		didSet {
			NotificationCenter.default.post(
				name: NSNotification.Name("RecordingStateChanged"), object: nil)
		}
	}
	var isTranscribing = false {
		didSet {
			NotificationCenter.default.post(
				name: NSNotification.Name("RecordingStateChanged"), object: nil)
		}
	}
	var lastTranscription: String?
	var transcriptionError: String?
	/// Shown on the listening pill when the recording had to change microphones.
	var inputNotice: String?
	var currentRecordingMode: RecordingMode = .text
	var isMicrophoneInitializing = false {
		didSet {
			NotificationCenter.default.post(
				name: NSNotification.Name("RecordingStateChanged"), object: nil)
		}
	}

	var currentState: AudioState {
		if isMicrophoneInitializing {
			return .initializing
		} else if isTranscribing {
			return .transcribing
		} else if isRecording {
			return .recording
		} else {
			return .idle
		}
	}

	// MARK: - Composed Components

	let timer = RecordingTimer()
	let levelMonitor = AudioLevelMonitor()
	let deviceManager = AudioDeviceManager.shared

	@ObservationIgnored
	private let engineController = AudioEngineController()

	// MARK: - Settings

	@ObservationIgnored
	@AppStorage("enableTranslation") var enableTranslation = false
	@ObservationIgnored
	@AppStorage("useStreamingTranscription") var useStreamingTranscription = true
	@ObservationIgnored
	@AppStorage("enableStreaming") var enableStreaming = Constants.enableStreamingDefault
	@ObservationIgnored
	@AppStorage("autoDetectLanguageFromKeyboard") var autoDetectLanguageFromKeyboard = false
	@ObservationIgnored
	@AppStorage("selectedLanguage") var selectedLanguage = Constants.defaultLanguageName

	// MARK: - Private Properties

	@ObservationIgnored
	private var audioRecorder: AVAudioRecorder?
	@ObservationIgnored
	private var audioFileURL: URL?
	@ObservationIgnored
	private var audioBuffer: [Float] = []
	@ObservationIgnored
	private let maxBufferSize = 16000 * 1800
	@ObservationIgnored
	private var meteringTimer: Timer?
	@ObservationIgnored
	private var deviceActivationTask: Task<Void, Never>?
	@ObservationIgnored
	private var outputMuteTask: Task<Void, Never>?
	@ObservationIgnored
	private var deviceLostObserver: NSObjectProtocol?
	@ObservationIgnored
	private var inputChannelSelection = InputChannelSelection.mixAllChannels

	@ObservationIgnored
	let whisperKitTranscriber = WhisperKitTranscriber.shared

	// MARK: - Initialization

	override init() {
		super.init()
		SystemOutputMuter.shared.recoverFromUncleanExit()
		whisperKitTranscriber.startInitialization()
		whisperKitTranscriber.onLiveAudioSamples = { [weak self] samples in
			// WhisperKit delivers per-buffer chunks; cap the window so level
			// math stays cheap even if a large backlog arrives at once
			self?.levelMonitor.update(from: Array(samples.suffix(4800)))
		}
		deviceLostObserver = NotificationCenter.default.addObserver(
			forName: .activeInputDeviceLost, object: nil, queue: .main
		) { [weak self] notification in
			let name = notification.userInfo?["name"] as? String ?? "Microphone"
			MainActor.assumeIsolated {
				self?.handleInputDeviceLost(name: name)
			}
		}
	}

	func setupAudio() {
		checkAndRequestMicrophonePermission()
	}

	// MARK: - Public API

	func toggleRecording() {
		if isRecording {
			// Keep the mode the session started with: re-reading enableStreaming here
			// would route stop to the wrong path if the setting changed mid-recording.
			stopRecording()
		} else {
			currentRecordingMode = enableStreaming ? .liveTranscription : .text
			startRecording()
		}
	}

	func switchInputDevice(to uid: String) {
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		deviceManager.selectDevice(uid: uid)
		reactivateInputDuringRecording()
	}

	/// Keeps the recording alive on the system default input when its microphone
	/// is unplugged; audio captured so far is kept.
	func handleInputDeviceLost(name: String) {
		guard isRecording || isMicrophoneInitializing else { return }
		AppLogger.shared.audioManager.info("Falling back to system default input after losing \(name)")
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		deviceManager.beginFallbackToSystemDefault()
		inputNotice = "\(name) disconnected. Using the system default microphone."
		reactivateInputDuringRecording()
	}

	private func reactivateInputDuringRecording() {
		guard isRecording || isMicrophoneInitializing else { return }

		isMicrophoneInitializing = true
		deviceActivationTask = Task {
			if currentRecordingMode == .liveTranscription {
				await whisperKitTranscriber.switchLiveStreamDevice()
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
			} else if useStreamingTranscription {
				let savedBuffer = audioBuffer
				engineController.cleanup()

				do {
					await deviceManager.activateSelectedDevice()
					guard !Task.isCancelled else { return }
					let _ = try await engineController.setup(deviceID: deviceManager.resolveActiveDeviceID())
					try engineController.installTap { [weak self] buffer, format in
						self?.processAudioBuffer(buffer, originalFormat: format)
					}
					audioBuffer = savedBuffer
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.info("Switched input device while recording")
				} catch {
					guard !Task.isCancelled else { return }
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.error("Failed to switch device: \(error)")
					isRecording = false
					timer.stop()
					restoreSystemOutput()
				}
			} else {
				deviceManager.restoreSystemDefault()
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
			}
			deviceActivationTask = nil
		}
	}

	// MARK: - Deprecated Compatibility

	var audioLevels: [Float] {
		levelMonitor.levels
	}

	var recordingDuration: TimeInterval {
		timer.duration
	}

	func formattedRecordingDuration() -> String {
		timer.formatted
	}
}

// MARK: - Recording Control

extension AudioManager {
	fileprivate func startRecording() {
		detectAndSetKeyboardLanguage()
		inputNotice = nil

		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			beginRecording()
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						self.beginRecording()
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
	fileprivate func beginRecording() {
		if currentRecordingMode == .liveTranscription {
			startLiveTranscription()
		} else if useStreamingTranscription {
			startStreamingRecording()
		} else {
			startFileBasedRecording()
		}
	}
	fileprivate func stopRecording() {
		if currentRecordingMode == .liveTranscription {
			stopLiveTranscription()
		} else if useStreamingTranscription {
			stopStreamingRecording()
		} else {
			stopFileBasedRecording()
		}
	}
}

// MARK: - File-Based Recording

extension AudioManager {
	fileprivate func startFileBasedRecording() {
		isMicrophoneInitializing = true

		deviceActivationTask = Task {
			await deviceManager.activateSelectedDevice()
			guard !Task.isCancelled else { return }

			let appSupportPath = getApplicationSupportDirectory()
			let audioFilename =
				appSupportPath
				.appendingPathComponent("recordings")
				.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
			audioFileURL = audioFilename

			try? FileManager.default.createDirectory(
				at: audioFilename.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)

			let settings: [String: Any] = [
				AVFormatIDKey: Int(kAudioFormatLinearPCM),
				AVSampleRateKey: 16000.0,
				AVNumberOfChannelsKey: 1,
				AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
			]

			do {
				audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
				audioRecorder?.isMeteringEnabled = true
				audioRecorder?.record()
				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				muteOutputAfterStartSound()
				startMeteringTimer()
				AppLogger.shared.audioManager.debug("File-based recording started")
			} catch {
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start recording: \(error)")
				showRecordingErrorAlert(error)
			}
		}
	}
	fileprivate func stopFileBasedRecording() {
		stopMeteringTimer()
		audioRecorder?.stop()
		audioRecorder = nil
		isRecording = false
		timer.stop()
		restoreSystemOutput()
		playFeedbackSound(start: false)
		deviceManager.restoreSystemDefault()
		deviceManager.endRecordingSession()

		if let audioFileURL {
			Task {
				await transcribeAudio(fileURL: audioFileURL, enableTranslation: enableTranslation)
			}
		}

		scheduleTimerReset()
	}

	private func startMeteringTimer() {
		meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self, let recorder = self.audioRecorder else { return }
				recorder.updateMeters()
				let power = recorder.averagePower(forChannel: 0)
				let linear = pow(10, power / 20)
				let samples = (0..<700).map { _ in linear + Float.random(in: -0.02...0.02) }
				self.levelMonitor.update(from: samples)
			}
		}
	}

	private func stopMeteringTimer() {
		meteringTimer?.invalidate()
		meteringTimer = nil
		levelMonitor.reset()
	}
}

// MARK: - Streaming Recording
extension AudioManager {
	fileprivate func startStreamingRecording() {
		AppLogger.shared.audioManager.info("Starting streaming recording")
		audioBuffer.removeAll()
		inputChannelSelection = InputChannelSelection.stored(in: .standard)
		isMicrophoneInitializing = true

		deviceActivationTask = Task {
			do {
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled else { return }
				let _ = try await engineController.setup(deviceID: deviceManager.resolveActiveDeviceID())
				try engineController.installTap { [weak self] buffer, format in
					self?.processAudioBuffer(buffer, originalFormat: format)
				}

				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				muteOutputAfterStartSound()

			} catch {
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start streaming: \(error)")
				useStreamingTranscription = false
				startFileBasedRecording()
			}
		}
	}

	fileprivate func stopStreamingRecording() {
		isRecording = false
		timer.stop()
		restoreSystemOutput()
		playFeedbackSound(start: false)

		let capturedAudio = audioBuffer
		audioBuffer.removeAll()
		levelMonitor.reset()

		engineController.cleanup()
		deviceManager.restoreSystemDefault()
		deviceManager.endRecordingSession()

		AppLogger.shared.audioManager.info("Streaming recording stopped")

		if !capturedAudio.isEmpty {
			Task {
				await transcribeAudioBuffer(audioArray: capturedAudio, enableTranslation: enableTranslation)
			}
		} else {
			AppLogger.shared.audioManager.info("No audio captured")
		}

		scheduleTimerReset()
	}
	fileprivate func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer, originalFormat inputFormat: AVAudioFormat) {
		let buffer = InputChannelSelection.isolate(inputBuffer, selected: inputChannelSelection)
		let originalFormat = buffer === inputBuffer ? inputFormat : buffer.format

		guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
			return
		}

		if originalFormat != targetFormat {
			guard let converter = AVAudioConverter(from: originalFormat, to: targetFormat) else {
				return
			}

			let ratio = targetFormat.sampleRate / originalFormat.sampleRate
			let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

			guard
				let convertedBuffer = AVAudioPCMBuffer(
					pcmFormat: targetFormat, frameCapacity: outputFrameCount)
			else {
				return
			}

			var error: NSError?
			converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
				outStatus.pointee = .haveData
				return buffer
			}

			if error == nil {
				extractFloatData(from: convertedBuffer)
			}
		} else {
			extractFloatData(from: buffer)
		}
	}
	fileprivate func extractFloatData(from buffer: AVAudioPCMBuffer) {
		guard let channelData = buffer.floatChannelData?[0] else { return }
		let frameCount = Int(buffer.frameLength)
		let audioData = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

		audioBuffer.append(contentsOf: audioData)
		if audioBuffer.count > maxBufferSize {
			let excessCount = audioBuffer.count - maxBufferSize
			audioBuffer.removeFirst(excessCount)
		}

		Task { @MainActor in
			levelMonitor.update(from: audioData)
		}
	}
}

// MARK: - Live Transcription
extension AudioManager {
	fileprivate func startLiveTranscription() {
		isMicrophoneInitializing = true
		isRecording = true
		timer.start()
		playFeedbackSound(start: true)
		muteOutputAfterStartSound()
		whisperKitTranscriber.clearLiveTranscriptionState()
		whisperKitTranscriber.beginLiveTranscriptionWaitingUI()

		deviceActivationTask = Task {
			do {
				try await whisperKitTranscriber.liveStream()
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.info("Live transcription started")
			} catch {
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
				isRecording = false
				timer.stop()
				restoreSystemOutput()
				AppLogger.shared.audioManager.error("Failed to start live transcription: \(error)")
			}
		}
	}
	fileprivate func stopLiveTranscription() {
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		isMicrophoneInitializing = false
		isRecording = false
		timer.stop()
		restoreSystemOutput()
		playFeedbackSound(start: false)

		whisperKitTranscriber.stopLiveStream()
		deviceManager.endRecordingSession()
		levelMonitor.reset()
		AppLogger.shared.audioManager.info("Live transcription stopped")

		scheduleTimerReset()
	}
}

// MARK: - Transcription
extension AudioManager {
	/// Returns the clip trimmed to its speech, or nil when it holds no speech and
	/// must not be transcribed.
	fileprivate func applyVoiceActivityDetection(_ samples: [Float]) async -> [Float]? {
		let settings = VoiceActivitySettings(defaults: .standard)
		guard settings.enabled else { return samples }

		let trimmer = VoiceActivityTrimmer(sensitivity: settings.sensitivity)
		let result = await Task.detached(priority: .userInitiated) {
			trimmer.process(samples)
		}.value

		switch result {
		case .noSpeech:
			AppLogger.shared.audioManager.info(
				"VAD found no speech in \(samples.count) samples, skipping transcription")
			return nil
		case .speech(let trimmed):
			AppLogger.shared.audioManager.debug(
				"VAD trimmed clip from \(samples.count) to \(trimmed.count) samples")
			return trimmed
		}
	}

	fileprivate func transcribeAudioBuffer(audioArray: [Float], enableTranslation: Bool) async {
		guard let audioArray = await applyVoiceActivityDetection(audioArray) else { return }

		isTranscribing = true
		transcriptionError = nil

		do {
			let transcription = try await whisperKitTranscriber.transcribeAudioArray(
				audioArray, enableTranslation: enableTranslation)

			await MainActor.run {
				lastTranscription = transcription
				isTranscribing = false

				if currentRecordingMode == .text {
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
	fileprivate func transcribeAudio(fileURL: URL, enableTranslation: Bool) async {
		if VoiceActivitySettings(defaults: .standard).enabled {
			let path = fileURL.path
			let samples = await Task.detached(priority: .userInitiated) {
				try? AudioProcessor.loadAudioAsFloatArray(fromPath: path)
			}.value
			if let samples {
				try? FileManager.default.removeItem(at: fileURL)
				await transcribeAudioBuffer(audioArray: samples, enableTranslation: enableTranslation)
				return
			}
			AppLogger.shared.audioManager.error("VAD could not load recording, transcribing untrimmed file")
		}

		isTranscribing = true
		transcriptionError = nil

		do {
			let transcription = try await whisperKitTranscriber.transcribe(
				audioURL: fileURL, enableTranslation: enableTranslation)

			await MainActor.run {
				lastTranscription = transcription
				isTranscribing = false

				if currentRecordingMode == .text {
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

		try? FileManager.default.removeItem(at: fileURL)
	}
}

// MARK: - Utilities
extension AudioManager {
	fileprivate func detectAndSetKeyboardLanguage() {
		let detectedLanguage = KeyboardInputSourceManager.shared.getLanguageForRecording(
			autoDetectEnabled: autoDetectLanguageFromKeyboard,
			manualLanguage: selectedLanguage
		)

		if detectedLanguage != selectedLanguage {
			AppLogger.shared.audioManager.info(
				"Updating language from \(selectedLanguage) to \(detectedLanguage)")
			selectedLanguage = detectedLanguage
		}
	}
	fileprivate func scheduleTimerReset() {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.timer.reset()
		}
	}
	/// Mutes system output once the start sound has had time to play, so the
	/// user still hears the cue before their speakers go quiet.
	fileprivate func muteOutputAfterStartSound() {
		guard SystemOutputMuter.shared.isEnabled else { return }
		outputMuteTask?.cancel()
		let delay = startSoundDuration()
		outputMuteTask = Task { [weak self] in
			if delay > 0 {
				try? await Task.sleep(for: .seconds(delay))
			}
			guard let self, !Task.isCancelled, self.isRecording || self.isMicrophoneInitializing else {
				return
			}
			SystemOutputMuter.shared.mute()
		}
	}
	fileprivate func restoreSystemOutput() {
		outputMuteTask?.cancel()
		outputMuteTask = nil
		SystemOutputMuter.shared.restore()
	}
	fileprivate func startSoundDuration() -> TimeInterval {
		guard UserDefaults.standard.bool(forKey: "soundFeedback") else { return 0 }
		let name = UserDefaults.standard.string(forKey: "startSound") ?? "Tink"
		guard name != "None" else { return 0 }
		return NSSound(named: name)?.duration ?? 0
	}
	fileprivate func playFeedbackSound(start: Bool) {
		guard UserDefaults.standard.bool(forKey: "soundFeedback") else { return }

		let soundName =
			start
			? UserDefaults.standard.string(forKey: "startSound") ?? "Tink"
			: UserDefaults.standard.string(forKey: "stopSound") ?? "Pop"

		guard soundName != "None" else { return }

		NSSound(named: soundName)?.play()
	}
	fileprivate func pasteToFocusedApp(_ text: String) {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)

		let source = CGEventSource(stateID: .combinedSessionState)
		let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
		let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

		keyDownEvent?.flags = .maskCommand
		keyUpEvent?.flags = .maskCommand

		keyDownEvent?.post(tap: .cghidEventTap)
		keyUpEvent?.post(tap: .cghidEventTap)
	}
	fileprivate func checkAndRequestMicrophonePermission() {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .notDetermined:
			AppLogger.shared.audioManager.debug("Requesting microphone permission")
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						AppLogger.shared.audioManager.debug("Microphone access granted")
					} else {
						AppLogger.shared.audioManager.debug("Microphone access denied")
						self.showMicrophonePermissionAlert()
					}
				}
			}
		case .denied, .restricted:
			AppLogger.shared.audioManager.info("Microphone access denied or restricted")
			showMicrophonePermissionAlert()
		case .authorized:
			AppLogger.shared.audioManager.debug("Microphone already authorized")
		@unknown default:
			break
		}
	}
	fileprivate func showMicrophonePermissionAlert() {
		let alert = NSAlert()
		alert.messageText = "Microphone Access Required"
		alert.informativeText =
			"Whispera needs access to your microphone to transcribe audio. Please grant permission in System Settings > Privacy & Security > Microphone."
		alert.alertStyle = .warning
		alert.addButton(withTitle: "Open System Settings")
		alert.addButton(withTitle: "Cancel")

		if alert.runModal() == .alertFirstButtonReturn {
			if let url = URL(
				string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
			{
				NSWorkspace.shared.open(url)
			}
		}
	}
	fileprivate func showRecordingErrorAlert(_ error: Error) {
		let alert = NSAlert()
		alert.messageText = "Recording Error"
		alert.informativeText = "Failed to start recording: \(error.localizedDescription)"
		alert.alertStyle = .critical
		alert.runModal()
	}
	fileprivate func getApplicationSupportDirectory() -> URL {
		let appSupport = FileManager.default.urls(
			for: .applicationSupportDirectory, in: .userDomainMask)[0]
		let appDirectory = appSupport.appendingPathComponent("Whispera")

		try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

		return appDirectory
	}
}
