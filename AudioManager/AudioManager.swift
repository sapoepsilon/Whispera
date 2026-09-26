import AVFoundation
import AppKit
import CoreAudio
import Foundation
import SwiftUI

enum RecordingMode {
	case text
	case liveTranscription
}

enum CapturePath {
	case live
	case file
	case stream
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
	private var sessionID = 0
	@ObservationIgnored
	private var sessionsHoldingModel: Set<Int> = []
	@ObservationIgnored
	private var activeCapturePath: CapturePath?
	@ObservationIgnored
	private var transcriptionTask: Task<Void, Never>?
	@ObservationIgnored
	private var transcribingSession: Int?
	@ObservationIgnored
	private var cancelledSessions: Set<Int> = []
	@ObservationIgnored
	private var pendingStopAfterStart = false
	@ObservationIgnored
	private let tailStop = DeferredAction()
	@ObservationIgnored
	private var isFinalizingStop = false
	@ObservationIgnored
	private let lazyStreamClose = DeferredAction()
	@ObservationIgnored
	private var isCapturingStream = false
	@ObservationIgnored
	private var openStreamDeviceID: AudioDeviceID?
	@ObservationIgnored
	private var warmStreamTask: Task<Void, Never>?
	@ObservationIgnored
	private var streamPolicyObservers: [NSObjectProtocol] = []
	@ObservationIgnored
	private var lastStreamPolicySnapshot: String?

	@ObservationIgnored
	let whisperKitTranscriber = WhisperKitTranscriber.shared

	// MARK: - Initialization

	override init() {
		super.init()
		whisperKitTranscriber.startInitialization()
		whisperKitTranscriber.onLiveAudioSamples = { [weak self] samples in
			// WhisperKit delivers per-buffer chunks; cap the window so level
			// math stays cheap even if a large backlog arrives at once
			self?.levelMonitor.update(from: Array(samples.suffix(4800)))
		}
		observeMicStreamPolicy()
	}

	func setupAudio() {
		checkAndRequestMicrophonePermission()
	}

	// MARK: - Public API

	/// True from the moment a recording is requested until its audio is finalized,
	/// including microphone startup.
	var isSessionActive: Bool {
		isRecording || isMicrophoneInitializing
	}

	func toggleRecording() {
		if isSessionActive {
			requestStop()
		} else {
			startRecordingSession()
		}
	}

	func startRecordingSession() {
		guard !isSessionActive else { return }
		pendingStopAfterStart = false
		currentRecordingMode = enableStreaming ? .liveTranscription : .text
		startRecording()
	}

	/// Stops the active recording and transcribes it. A stop that arrives while the
	/// microphone is still starting is deferred until capture begins, so a short
	/// push-to-talk press is never lost.
	func requestStop() {
		guard !isFinalizingStop else { return }
		if currentRecordingMode != .liveTranscription && isMicrophoneInitializing && !isRecording {
			pendingStopAfterStart = true
			return
		}
		guard isRecording else { return }

		let tail = RecordingControlSettings().extraRecordingBuffer
		guard tail > 0 else {
			// Keep the mode the session started with: re-reading enableStreaming here
			// would route stop to the wrong path if the setting changed mid-recording.
			stopRecording()
			return
		}
		// Capture a little past the stop press so the last syllable is not clipped.
		isFinalizingStop = true
		AppLogger.shared.audioManager.debug("Capturing \(Int(tail * 1000)) ms tail before stopping")
		tailStop.schedule(after: tail) { [weak self] in
			self?.finishTailStop()
		}
	}

	private func finishTailStop() {
		guard isFinalizingStop else { return }
		isFinalizingStop = false
		stopRecording()
	}

	fileprivate func applyPendingStopIfNeeded() {
		guard pendingStopAfterStart else { return }
		pendingStopAfterStart = false
		AppLogger.shared.audioManager.info("Applying stop requested during microphone startup")
		requestStop()
	}

	/// Discards the current recording: no transcription, no paste. A transcription
	/// that is already running is abandoned and its result dropped.
	func cancelRecording() {
		let capturing = isRecording || isMicrophoneInitializing
		guard capturing || isTranscribing else { return }

		pendingStopAfterStart = false
		tailStop.cancel()
		isFinalizingStop = false
		deviceActivationTask?.cancel()
		deviceActivationTask = nil

		if capturing {
			cancelledSessions.insert(sessionID)
			switch activeCapturePath {
			case .live:
				whisperKitTranscriber.cancelLiveStream()
			case .file:
				stopMeteringTimer()
				audioRecorder?.stop()
				audioRecorder = nil
				if let audioFileURL {
					try? FileManager.default.removeItem(at: audioFileURL)
				}
				audioFileURL = nil
			case .stream:
				isCapturingStream = false
				audioBuffer.removeAll()
				releaseStreamingEngine()
			case nil:
				break
			}
			activeCapturePath = nil
			deviceManager.restoreSystemDefault()
			releaseModel(for: sessionID)
			playFeedbackSound(start: false)
		}

		if let transcribingSession {
			cancelledSessions.insert(transcribingSession)
			transcriptionTask?.cancel()
			transcriptionTask = nil
			releaseModel(for: transcribingSession)
			self.transcribingSession = nil
		}

		isMicrophoneInitializing = false
		isRecording = false
		isTranscribing = false
		timer.stop()
		levelMonitor.reset()
		scheduleTimerReset()
		AppLogger.shared.audioManager.info("Recording cancelled; audio discarded")
	}

	func switchInputDevice(to uid: String) {
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		deviceManager.selectDevice(uid: uid)

		guard isRecording || isMicrophoneInitializing else {
			if engineController.isRunning {
				shutdownStreamingEngine()
				applyMicStreamPolicy()
			}
			return
		}

		isMicrophoneInitializing = true
		deviceActivationTask = Task {
			if currentRecordingMode == .liveTranscription {
				await whisperKitTranscriber.switchLiveStreamDevice()
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
			} else if useStreamingTranscription {
				let savedBuffer = audioBuffer
				shutdownStreamingEngine()

				do {
					await deviceManager.activateSelectedDevice()
					guard !Task.isCancelled else { return }
					try await openStreamingEngine()
					audioBuffer = savedBuffer
					isCapturingStream = true
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.info("Switched input device while recording")
				} catch {
					guard !Task.isCancelled else { return }
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.error("Failed to switch device: \(error)")
					isRecording = false
					timer.stop()
					releaseModel(for: sessionID)
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
		sessionID += 1
		if currentRecordingMode != .liveTranscription {
			holdModel(for: sessionID)
		}
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
		activeCapturePath = .file
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
				startMeteringTimer()
				AppLogger.shared.audioManager.debug("File-based recording started")
				applyPendingStopIfNeeded()
			} catch {
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start recording: \(error)")
				pendingStopAfterStart = false
				releaseModel(for: sessionID)
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
		playFeedbackSound(start: false)
		deviceManager.restoreSystemDefault()

		activeCapturePath = nil
		let session = sessionID
		if let audioFileURL {
			transcriptionTask = Task {
				await transcribeAudio(
					fileURL: audioFileURL, enableTranslation: enableTranslation, session: session)
			}
		} else {
			releaseModel(for: session)
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
		activeCapturePath = .stream
		audioBuffer.removeAll()
		lazyStreamClose.cancel()
		warmStreamTask?.cancel()
		warmStreamTask = nil

		if resumeOpenStream() {
			return
		}

		isMicrophoneInitializing = true
		deviceActivationTask = Task {
			do {
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled else { return }
				try await openStreamingEngine()
				guard !Task.isCancelled else {
					shutdownStreamingEngine()
					return
				}

				isCapturingStream = true
				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				applyPendingStopIfNeeded()

			} catch {
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start streaming: \(error)")
				shutdownStreamingEngine()
				useStreamingTranscription = false
				startFileBasedRecording()
			}
		}
	}

	fileprivate func stopStreamingRecording() {
		isCapturingStream = false
		isRecording = false
		timer.stop()
		playFeedbackSound(start: false)

		let capturedAudio = audioBuffer
		audioBuffer.removeAll()
		levelMonitor.reset()

		releaseStreamingEngine()
		deviceManager.restoreSystemDefault()

		AppLogger.shared.audioManager.info("Streaming recording stopped")

		activeCapturePath = nil
		let session = sessionID
		if !capturedAudio.isEmpty {
			transcriptionTask = Task {
				await transcribeAudioBuffer(
					audioArray: capturedAudio, enableTranslation: enableTranslation, session: session)
			}
		} else {
			AppLogger.shared.audioManager.info("No audio captured")
			releaseModel(for: session)
		}

		scheduleTimerReset()
	}
	fileprivate func processAudioBuffer(_ buffer: AVAudioPCMBuffer, originalFormat: AVAudioFormat) {
		// The stream can stay open between recordings; drop audio nobody asked for.
		guard isCapturingStream else { return }
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

// MARK: - Open Microphone Stream
extension AudioManager {
	fileprivate func openStreamingEngine() async throws {
		let deviceID = deviceManager.resolveActiveDeviceID()
		_ = try await engineController.setup(deviceID: deviceID)
		try engineController.installTap { [weak self] buffer, format in
			self?.processAudioBuffer(buffer, originalFormat: format)
		}
		openStreamDeviceID = deviceID
		engineController.onRouteChange = { [weak self] in
			self?.handleStreamRouteChange()
		}
	}

	/// Starts capturing on a stream left open by the lazy-close or always-on policy,
	/// skipping engine and device setup entirely.
	fileprivate func resumeOpenStream() -> Bool {
		guard engineController.isRunning else { return false }
		guard engineController.isEngineRunning,
			openStreamDeviceID == deviceManager.resolveActiveDeviceID()
		else {
			shutdownStreamingEngine()
			return false
		}
		isCapturingStream = true
		isRecording = true
		timer.start()
		playFeedbackSound(start: true)
		AppLogger.shared.audioManager.info("Recording on already-open microphone stream")
		return true
	}

	fileprivate func releaseStreamingEngine() {
		let settings = RecordingControlSettings()
		switch settings.micStreamPolicy {
		case .onDemand:
			shutdownStreamingEngine()
		case .lazyClose:
			guard engineController.isRunning else { return }
			lazyStreamClose.schedule(after: settings.lazyStreamCloseDelay) { [weak self] in
				guard let self, !self.isSessionActive else { return }
				AppLogger.shared.audioManager.info("Closing idle microphone stream")
				self.shutdownStreamingEngine()
			}
		case .alwaysOn:
			if !canKeepStreamOpen {
				shutdownStreamingEngine()
			}
		}
	}

	fileprivate func shutdownStreamingEngine() {
		lazyStreamClose.cancel()
		warmStreamTask?.cancel()
		warmStreamTask = nil
		isCapturingStream = false
		engineController.onRouteChange = nil
		engineController.cleanup()
		openStreamDeviceID = nil
	}

	/// The open-stream policies only apply to the buffered streaming path; live
	/// transcription captures through WhisperKit's own audio processor.
	fileprivate var canKeepStreamOpen: Bool {
		!enableStreaming && useStreamingTranscription
			&& AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
	}

	func applyMicStreamPolicy() {
		guard !isSessionActive else { return }
		switch RecordingControlSettings().micStreamPolicy {
		case .alwaysOn:
			guard canKeepStreamOpen else {
				if engineController.isRunning { shutdownStreamingEngine() }
				return
			}
			guard !engineController.isEngineRunning, warmStreamTask == nil else { return }
			warmStreamTask = Task { [weak self] in
				guard let self else { return }
				defer { self.warmStreamTask = nil }
				guard !Task.isCancelled, !self.isSessionActive else { return }
				do {
					try await self.openStreamingEngine()
					guard !Task.isCancelled, !self.isSessionActive else { return }
					AppLogger.shared.audioManager.info("Microphone stream kept open (always on)")
				} catch {
					AppLogger.shared.audioManager.error("Failed to keep microphone open: \(error)")
					self.shutdownStreamingEngine()
				}
			}
		case .lazyClose:
			if engineController.isRunning && !lazyStreamClose.isScheduled {
				shutdownStreamingEngine()
			}
		case .onDemand:
			if engineController.isRunning {
				shutdownStreamingEngine()
			}
		}
	}

	private func handleStreamRouteChange() {
		guard !isSessionActive else { return }
		AppLogger.shared.audioManager.info("Audio route changed while stream idle; reopening per policy")
		shutdownStreamingEngine()
		applyMicStreamPolicy()
	}

	fileprivate func observeMicStreamPolicy() {
		lastStreamPolicySnapshot = streamPolicySnapshot()
		let center = NotificationCenter.default
		streamPolicyObservers.append(
			center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
				[weak self] _ in
				Task { @MainActor in
					guard let self else { return }
					let snapshot = self.streamPolicySnapshot()
					guard snapshot != self.lastStreamPolicySnapshot else { return }
					self.lastStreamPolicySnapshot = snapshot
					self.applyMicStreamPolicy()
				}
			})
		streamPolicyObservers.append(
			center.addObserver(forName: .audioInputDeviceChanged, object: nil, queue: .main) {
				[weak self] _ in
				Task { @MainActor in
					guard let self, !self.isSessionActive, self.engineController.isRunning else { return }
					self.shutdownStreamingEngine()
					self.applyMicStreamPolicy()
				}
			})
		Task { @MainActor [weak self] in
			self?.applyMicStreamPolicy()
		}
	}

	private func streamPolicySnapshot() -> String {
		let settings = RecordingControlSettings()
		return "\(settings.micStreamPolicy.rawValue)|\(enableStreaming)|\(useStreamingTranscription)"
	}
}

// MARK: - Live Transcription
extension AudioManager {
	fileprivate func startLiveTranscription() {
		activeCapturePath = .live
		isMicrophoneInitializing = true
		isRecording = true
		timer.start()
		playFeedbackSound(start: true)
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
		playFeedbackSound(start: false)

		activeCapturePath = nil
		whisperKitTranscriber.stopLiveStream()
		levelMonitor.reset()
		AppLogger.shared.audioManager.info("Live transcription stopped")

		let session = whisperKitTranscriber.takeLastLiveSession()
		if !session.text.isEmpty {
			recordHistory(
				text: session.text,
				audio: session.samples.isEmpty ? nil : .samples(session.samples, sampleRate: 16000),
				source: .liveDictation)
		}

		scheduleTimerReset()
	}
}

// MARK: - Transcription
extension AudioManager {
	fileprivate func transcribeAudioBuffer(audioArray: [Float], enableTranslation: Bool, session: Int)
		async
	{
		await runTranscription(session: session, historyAudio: .samples(audioArray, sampleRate: 16000)) {
			try await self.whisperKitTranscriber.transcribeAudioArray(
				audioArray, enableTranslation: enableTranslation)
		}
	}

	fileprivate func transcribeAudio(fileURL: URL, enableTranslation: Bool, session: Int) async {
		await runTranscription(session: session, historyAudio: .file(fileURL)) {
			try await self.whisperKitTranscriber.transcribe(
				audioURL: fileURL, enableTranslation: enableTranslation)
		}
		// No-op when history already moved the recording into its own folder
		try? FileManager.default.removeItem(at: fileURL)
	}

	private func runTranscription(
		session: Int, historyAudio: TranscriptionHistoryAudio, _ work: () async throws -> String
	) async {
		defer {
			releaseModel(for: session)
			cancelledSessions.remove(session)
			if transcribingSession == session {
				transcribingSession = nil
				transcriptionTask = nil
			}
		}
		transcribingSession = session
		isTranscribing = true
		transcriptionError = nil

		do {
			let transcription = try await work()
			guard !cancelledSessions.contains(session) else {
				AppLogger.shared.audioManager.info("Discarding transcription of a cancelled recording")
				return
			}
			lastTranscription = transcription
			isTranscribing = false

			if currentRecordingMode == .text {
				pasteToFocusedApp(transcription)
			}
			// After the paste so saving the recording never delays the text
			recordHistory(text: transcription, audio: historyAudio)
		} catch {
			guard !cancelledSessions.contains(session) else { return }
			transcriptionError = error.localizedDescription
			lastTranscription = "Transcription failed: \(error.localizedDescription)"
			isTranscribing = false
			recordHistory(text: "", audio: historyAudio, errorMessage: error.localizedDescription)
		}
	}

	fileprivate func recordHistory(
		text: String, audio: TranscriptionHistoryAudio?,
		source: TranscriptionHistorySource = .dictation, errorMessage: String? = nil
	) {
		TranscriptionHistoryStore.shared.record(
			text: text,
			audio: audio,
			source: source,
			modelName: whisperKitTranscriber.currentModel ?? whisperKitTranscriber.selectedModel,
			language: selectedLanguage,
			errorMessage: errorMessage
		)
	}
}

// MARK: - Model Hold
extension AudioManager {
	/// Keeps the idle-unload timer from releasing the model between the start of a
	/// recording and the end of its transcription, and reloads it if it was released.
	fileprivate func holdModel(for session: Int) {
		guard sessionsHoldingModel.insert(session).inserted else { return }
		whisperKitTranscriber.beginModelUse()
		whisperKitTranscriber.preloadModelIfIdleUnloaded()
	}

	fileprivate func releaseModel(for session: Int) {
		guard sessionsHoldingModel.remove(session) != nil else { return }
		whisperKitTranscriber.endModelUse()
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
