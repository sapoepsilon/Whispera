import AVFoundation
import AppKit
import CoreAudio
import Foundation
import SwiftUI
import WhisperKit

enum RecordingMode {
	case text
	case liveTranscription
}

enum CapturePath {
	case live
	case file
	case stream

	/// The path a stop must tear down. It is always the one the session started on: the
	/// streaming setting can change mid-recording, and a failed stream start falls back to file.
	static func toStop(active: CapturePath?, mode: RecordingMode) -> CapturePath {
		if let active { return active }
		// Nothing is capturing; the stream path only finishes the ledger and resets state
		return mode == .liveTranscription ? .live : .stream
	}
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
		// A new recording can start while the previous one is still transcribing;
		// the live capture is what the user is looking at.
		if isMicrophoneInitializing {
			return .initializing
		} else if isRecording {
			return .recording
		} else if isTranscribing {
			return .transcribing
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
	@AppStorage("autoDetectLanguageFromKeyboard") var autoDetectLanguageFromKeyboard = Constants
		.autoDetectLanguageFromKeyboardDefault
	@ObservationIgnored
	@AppStorage("selectedLanguage") var selectedLanguage = Constants.defaultLanguageName

	// MARK: - Private Properties

	@ObservationIgnored
	private var audioRecorder: AVAudioRecorder?
	@ObservationIgnored
	private var audioFileURL: URL?
	@ObservationIgnored
	private var fileCaptureChannel = InputChannelSelection.mixAllChannels
	@ObservationIgnored
	private let captureBuffer = StreamCaptureBuffer()
	@ObservationIgnored
	private var meteringTimer: Timer?
	@ObservationIgnored
	private var deviceActivationTask: Task<Void, Never>?
	@ObservationIgnored
	private var ledger = DictationSessionLedger()
	@ObservationIgnored
	private var sessionsHoldingModel: Set<Int> = []
	@ObservationIgnored
	private var activeCapturePath: CapturePath?
	@ObservationIgnored
	private var transcriptionTasks: [Int: Task<Void, Never>] = [:]
	@ObservationIgnored
	private var pendingStopAfterStart = false
	@ObservationIgnored
	private let tailStop = TailStopCoordinator()
	@ObservationIgnored
	private let lazyStreamClose = DeferredAction()
	@ObservationIgnored
	private var openStreamDeviceID: AudioDeviceID?
	/// The input a recording should use as of when the stream opened; the watchdog follows changes.
	@ObservationIgnored
	private var openStreamExpectedDeviceID: AudioDeviceID?
	@ObservationIgnored
	private var warmStreamTask: Task<Void, Never>?
	@ObservationIgnored
	private var streamPolicyObservers: [NSObjectProtocol] = []
	@ObservationIgnored
	private var streamPolicyDefaultsObserver: DefaultsKeyObserver?
	@ObservationIgnored
	private var lastStreamPolicySnapshot: String?
	@ObservationIgnored
	private var micStreamSuspension = MicStreamSuspension()
	@ObservationIgnored
	private var powerStateObservers: [(NotificationCenter, NSObjectProtocol)] = []
	@ObservationIgnored
	private var outputMuteTask: Task<Void, Never>?
	@ObservationIgnored
	private var deviceLostObserver: NSObjectProtocol?
	@ObservationIgnored
	private var interruptionPolicy = CaptureInterruptionPolicy()
	@ObservationIgnored
	private var captureWatchdog: Timer?
	/// Why the recording being stopped right now ended early; moved onto its session at finish.
	@ObservationIgnored
	private var pendingStopNotice: String?
	@ObservationIgnored
	private var stopNotices: [Int: String] = [:]

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
		captureBuffer.onLimitReached = { [weak self] in
			Task { @MainActor in
				_ = self?.handleCaptureInterruption(.captureLimitReached)
			}
		}
		observeMicStreamPolicy()
		observePowerState()
		TextInserter.shared.onProblem = { [weak self] problem in
			self?.transcriptionError = problem.message
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

	/// True from the moment a recording is requested until its audio is finalized,
	/// including microphone startup.
	var isSessionActive: Bool {
		isRecording || isMicrophoneInitializing
	}

	func toggleRecording(postProcess: Bool = false) {
		if isSessionActive {
			requestStop()
		} else {
			startRecordingSession(postProcess: postProcess)
		}
	}

	func startRecordingSession(postProcess: Bool = false) {
		guard !isSessionActive else { return }
		pendingStopAfterStart = false
		let postProcessing = PostProcessingSettings()
		// Post-processing rewrites the whole transcript, so that session must run in text mode.
		let forceTextMode = postProcess && postProcessing.isEnabled
		let mode: RecordingMode =
			enableStreaming && whisperKitTranscriber.supportsLiveTranscription && !forceTextMode
			? .liveTranscription : .text
		currentRecordingMode = mode
		let shouldPostProcess = postProcessing.shouldPostProcess(
			requestedByShortcut: postProcess, isLiveMode: mode == .liveTranscription)
		startRecording(mode: mode, postProcess: shouldPostProcess)
	}

	/// Stops the active recording and transcribes it. A stop that arrives while the
	/// microphone is still starting is deferred until capture begins, so a short
	/// push-to-talk press is never lost.
	func requestStop() {
		guard !tailStop.isFinalizing else { return }
		if currentRecordingMode != .liveTranscription && isMicrophoneInitializing && !isRecording {
			pendingStopAfterStart = true
			return
		}
		guard isRecording else { return }

		let tail = RecordingControlSettings().extraRecordingBuffer
		if tail > 0 {
			AppLogger.shared.audioManager.debug("Capturing \(Int(tail * 1000)) ms tail before stopping")
		}
		// Keep the mode the session started with: re-reading enableStreaming here
		// would route stop to the wrong path if the setting changed mid-recording.
		tailStop.requestStop(tail: tail) { [weak self] in
			self?.stopRecording()
		}
	}

	fileprivate func applyPendingStopIfNeeded() {
		guard pendingStopAfterStart else { return }
		pendingStopAfterStart = false
		AppLogger.shared.audioManager.info("Applying stop requested during microphone startup")
		requestStop()
	}

	/// Discards the current recording: no transcription, no paste. With no recording
	/// running, transcriptions still in flight (including VAD) are abandoned instead.
	func cancelRecording() {
		let capturing = isRecording || isMicrophoneInitializing
		guard capturing || ledger.isTranscribing else { return }

		// Only the capture is cancelled while one runs, so an earlier dictation that is
		// still transcribing is not thrown away with it.
		let cancelled = capturing && ledger.capturing == nil ? [] : ledger.cancel()
		for session in cancelled {
			transcriptionTasks.removeValue(forKey: session.id)?.cancel()
			releaseModel(for: session.id)
			stopNotices[session.id] = nil
		}

		if capturing {
			pendingStopAfterStart = false
			tailStop.cancel()
			deviceActivationTask?.cancel()
			deviceActivationTask = nil
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
				captureBuffer.discard()
				releaseStreamingEngine()
			case nil:
				break
			}
			activeCapturePath = nil
			restoreSystemOutput()
			deviceManager.restoreSystemDefault()
			deviceManager.endRecordingSession()
			playFeedbackSound(start: false)
			isMicrophoneInitializing = false
			isRecording = false
			timer.stop()
			levelMonitor.reset()
			scheduleTimerReset()
		}

		syncTranscribingState()
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
		if isStartingCapture {
			restartCaptureStartup()
		} else {
			reactivateInputDuringRecording()
		}
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
		if isStartingCapture {
			restartCaptureStartup()
		} else {
			reactivateInputDuringRecording()
		}
	}

	/// The recording was requested but its microphone is not capturing yet. Live mode
	/// is excluded because it reports recording from the start.
	private var isStartingCapture: Bool {
		isMicrophoneInitializing && !isRecording && currentRecordingMode != .liveTranscription
	}

	/// A device change during startup restarts startup on the new device instead of
	/// cancelling it, so the session, its model hold and any pending stop survive.
	private func restartCaptureStartup() {
		AppLogger.shared.audioManager.info("Input changed during microphone startup; restarting on the new device")
		switch activeCapturePath {
		case .stream:
			shutdownStreamingEngine()
			startStreamingRecording()
		case .file:
			startFileBasedRecording()
		case .live, nil:
			reactivateInputDuringRecording()
		}
	}

	/// Stop paths call this so a device activation still in flight can neither reopen
	/// the microphone nor leave the session looking like it is starting.
	private func abortDeviceActivation() {
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		isMicrophoneInitializing = false
	}

	private func reactivateInputDuringRecording() {
		guard isRecording || isMicrophoneInitializing else { return }

		isMicrophoneInitializing = true
		let session = ledger.capturing?.id
		deviceActivationTask = Task {
			if currentRecordingMode == .liveTranscription {
				await whisperKitTranscriber.switchLiveStreamDevice()
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				isMicrophoneInitializing = false
			} else if activeCapturePath == .stream {
				// Samples captured so far stay in the buffer across the switch
				shutdownStreamingEngine()

				do {
					await deviceManager.activateSelectedDevice()
					guard !Task.isCancelled, isCurrentCapture(session) else { return }
					try await openStreamingEngine()
					guard !Task.isCancelled, isCurrentCapture(session) else {
						shutdownStreamingEngine()
						return
					}
					captureBuffer.setCapturing(true)
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.info("Switched input device while recording")
				} catch {
					guard !Task.isCancelled, isCurrentCapture(session) else { return }
					AppLogger.shared.audioManager.error("Failed to switch device: \(error)")
					// The audio captured before the switch is still worth transcribing
					deviceActivationTask = nil
					finishInterruptedRecording(
						notice: String(
							localized: "The microphone stopped working, so the recording was stopped early. What was captured was transcribed."
						))
					return
				}
			} else {
				deviceManager.restoreSystemDefault()
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				isMicrophoneInitializing = false
			}
			deviceActivationTask = nil
		}
	}

	private func isCurrentCapture(_ session: Int?) -> Bool {
		guard let session else { return false }
		return ledger.isCapturing(session) && isSessionActive
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
	fileprivate func startRecording(mode: RecordingMode, postProcess: Bool) {
		detectAndSetKeyboardLanguage()
		inputNotice = nil

		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			beginRecording(mode: mode, postProcess: postProcess)
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						self.beginRecording(mode: mode, postProcess: postProcess)
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
	fileprivate func beginRecording(mode: RecordingMode, postProcess: Bool) {
		guard !isSessionActive else { return }
		currentRecordingMode = mode
		let (session, abandoned) = ledger.beginCapture(mode: mode, postProcess: postProcess)
		if let abandoned {
			AppLogger.shared.audioManager.error("Releasing session \(abandoned.id) whose capture never finished")
			releaseModel(for: abandoned.id)
		}
		if mode != .liveTranscription {
			holdModel(for: session.id)
		}
		interruptionPolicy.reset()
		startCaptureWatchdog()
		if mode == .liveTranscription {
			startLiveTranscription()
		} else if useStreamingTranscription {
			startStreamingRecording()
		} else {
			startFileBasedRecording()
		}
	}
	fileprivate func stopRecording() {
		switch CapturePath.toStop(active: activeCapturePath, mode: currentRecordingMode) {
		case .live:
			stopLiveTranscription()
		case .stream:
			stopStreamingRecording()
		case .file:
			stopFileBasedRecording()
		}
	}
}

// MARK: - File-Based Recording

extension AudioManager {
	fileprivate func startFileBasedRecording() {
		activeCapturePath = .file
		isMicrophoneInitializing = true
		let session = ledger.capturing?.id

		deviceActivationTask = Task {
			await deviceManager.activateSelectedDevice()
			guard !Task.isCancelled, isCurrentCapture(session) else { return }

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

			let selectedChannel = InputChannelSelection.stored(in: .standard)
			let recordedChannels = InputChannelSelection.fileRecordingChannelCount(
				selected: selectedChannel, deviceChannels: deviceManager.effectiveInputChannelCount)
			fileCaptureChannel = recordedChannels > 1 ? selectedChannel : InputChannelSelection.mixAllChannels

			let settings: [String: Any] = [
				AVFormatIDKey: Int(kAudioFormatLinearPCM),
				AVSampleRateKey: 16000.0,
				AVNumberOfChannelsKey: recordedChannels,
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
				applyPendingStopIfNeeded()
			} catch {
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start recording: \(error)")
				pendingStopAfterStart = false
				activeCapturePath = nil
				if let dropped = ledger.dropCapture() {
					releaseModel(for: dropped.id)
				}
				deviceManager.restoreSystemDefault()
				deviceManager.endRecordingSession()
				showRecordingErrorAlert(error)
			}
		}
	}
	fileprivate func stopFileBasedRecording() {
		abortDeviceActivation()
		stopMeteringTimer()
		audioRecorder?.stop()
		audioRecorder = nil
		isRecording = false
		timer.stop()
		restoreSystemOutput()
		playFeedbackSound(start: false)
		deviceManager.restoreSystemDefault()
		deviceManager.endRecordingSession()

		activeCapturePath = nil
		if let audioFileURL, let session = ledger.finishCapture() {
			attachStopNotice(to: session)
			let translate = enableTranslation
			let channel = fileCaptureChannel
			startTranscription(session) { manager in
				await manager.transcribeAudio(
					fileURL: audioFileURL, channel: channel, enableTranslation: translate, session: session)
			}
		} else if let dropped = ledger.dropCapture() {
			releaseModel(for: dropped.id)
		}
		audioFileURL = nil

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
		captureBuffer.discard()
		lazyStreamClose.cancel()
		warmStreamTask?.cancel()
		warmStreamTask = nil
		let channelSelection = InputChannelSelection.stored(in: .standard)

		if resumeOpenStream(channelSelection: channelSelection) {
			return
		}

		isMicrophoneInitializing = true
		let session = ledger.capturing?.id
		deviceActivationTask = Task {
			do {
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				try await openStreamingEngine()
				guard !Task.isCancelled, isCurrentCapture(session) else {
					shutdownStreamingEngine()
					return
				}

				captureBuffer.beginCapture(channelSelection: channelSelection)
				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				muteOutputAfterStartSound()
				applyPendingStopIfNeeded()

			} catch {
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				isMicrophoneInitializing = false
				// Only this session falls back: turning the setting off would also silently
				// disable the kept-open microphone policies for good
				AppLogger.shared.audioManager.error(
					"Failed to start streaming, recording to a file instead: \(error)")
				shutdownStreamingEngine()
				startFileBasedRecording()
			}
		}
	}

	fileprivate func stopStreamingRecording() {
		abortDeviceActivation()
		let capturedAudio = captureBuffer.finishCapture()
		isRecording = false
		timer.stop()
		restoreSystemOutput()
		playFeedbackSound(start: false)
		levelMonitor.reset()

		releaseStreamingEngine()
		deviceManager.restoreSystemDefault()
		deviceManager.endRecordingSession()

		AppLogger.shared.audioManager.info("Streaming recording stopped")

		activeCapturePath = nil
		if !capturedAudio.isEmpty, let session = ledger.finishCapture() {
			attachStopNotice(to: session)
			let translate = enableTranslation
			startTranscription(session) { manager in
				await manager.transcribeAudioBuffer(
					audioArray: capturedAudio, enableTranslation: translate, session: session)
			}
		} else {
			AppLogger.shared.audioManager.info("No audio captured")
			if let dropped = ledger.dropCapture() {
				releaseModel(for: dropped.id)
			}
		}

		scheduleTimerReset()
	}
}

// MARK: - Open Microphone Stream
extension AudioManager {
	fileprivate func openStreamingEngine() async throws {
		let deviceID = deviceManager.resolveActiveDeviceID()
		_ = try await engineController.setup(deviceID: deviceID)
		let captureBuffer = captureBuffer
		try engineController.installTap { [weak self] buffer, format in
			guard let samples = captureBuffer.ingest(buffer, format: format) else { return }
			Task { @MainActor [weak self] in
				self?.levelMonitor.update(from: samples)
			}
		}
		openStreamDeviceID = deviceID
		openStreamExpectedDeviceID = deviceManager.expectedInputDeviceID()
		engineController.onRouteChange = { [weak self] in
			self?.handleStreamRouteChange()
		}
	}

	/// Starts capturing on a stream left open by the lazy-close or always-on policy,
	/// skipping engine and device setup entirely.
	fileprivate func resumeOpenStream(channelSelection: Int) -> Bool {
		guard engineController.isRunning else { return false }
		guard engineController.isEngineRunning,
			openStreamDeviceID == deviceManager.resolveActiveDeviceID()
		else {
			shutdownStreamingEngine()
			return false
		}
		captureBuffer.beginCapture(channelSelection: channelSelection)
		isRecording = true
		timer.start()
		playFeedbackSound(start: true)
		muteOutputAfterStartSound()
		AppLogger.shared.audioManager.info("Recording on already-open microphone stream")
		return true
	}

	fileprivate func releaseStreamingEngine() {
		let settings = RecordingControlSettings()
		guard !micStreamSuspension.isSuspended else {
			shutdownStreamingEngine()
			return
		}
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
		captureBuffer.setCapturing(false)
		engineController.onRouteChange = nil
		engineController.cleanup()
		openStreamDeviceID = nil
		openStreamExpectedDeviceID = nil
	}

	/// The open-stream policies only apply to the buffered streaming path; live
	/// transcription captures through WhisperKit's own audio processor.
	fileprivate var captureRoute: CaptureRoute {
		CaptureRoute.resolve(
			liveTranscriptionEnabled: enableStreaming,
			modelSupportsLive: whisperKitTranscriber.supportsLiveTranscription,
			useStreamingTranscription: useStreamingTranscription)
	}

	fileprivate var canKeepStreamOpen: Bool {
		captureRoute.canKeepMicrophoneOpen
			&& AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
	}

	func applyMicStreamPolicy() {
		guard !isSessionActive else { return }
		switch RecordingControlSettings().micStreamPolicy {
		case .alwaysOn:
			guard canKeepStreamOpen, !micStreamSuspension.isSuspended else {
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
		guard !isSessionActive else {
			// The engine has stopped itself; without a restart the recording keeps "running" on silence
			handleCaptureInterruption(.engineStopped)
			return
		}
		AppLogger.shared.audioManager.info("Audio route changed while stream idle; reopening per policy")
		shutdownStreamingEngine()
		applyMicStreamPolicy()
	}

	fileprivate func observeMicStreamPolicy() {
		lastStreamPolicySnapshot = streamPolicySnapshot()
		let center = NotificationCenter.default
		streamPolicyDefaultsObserver = DefaultsKeyObserver(
			keys: [RecordingControlSettings.Key.micStreamPolicy, "enableStreaming", "useStreamingTranscription"]
		) { [weak self] in
			guard let self else { return }
			let snapshot = self.streamPolicySnapshot()
			guard snapshot != self.lastStreamPolicySnapshot else { return }
			self.lastStreamPolicySnapshot = snapshot
			self.applyMicStreamPolicy()
		}
		// Switching to or from Parakeet changes the capture route without touching a setting
		streamPolicyObservers.append(
			center.addObserver(
				forName: NSNotification.Name("WhisperKitModelStateChanged"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
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

	/// Kept-open streams hold an IO power assertion that blocks idle sleep, so they
	/// close whenever the Mac sleeps, locks, switches user or enters Low Power Mode.
	fileprivate func observePowerState() {
		let workspace = NSWorkspace.shared.notificationCenter
		let pairs: [(Notification.Name, MicStreamSuspension.Reason, Bool)] = [
			(NSWorkspace.willSleepNotification, .systemSleep, true),
			(NSWorkspace.screensDidSleepNotification, .displaySleep, true),
			(NSWorkspace.screensDidWakeNotification, .displaySleep, false),
			(NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
			(NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
		]
		for (name, reason, begins) in pairs {
			let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.updateStreamSuspension(reason, active: begins)
				}
			}
			powerStateObservers.append((workspace, token))
		}
		for (name, interruption) in [
			(NSWorkspace.willSleepNotification, CaptureInterruption.systemSleep),
			(NSWorkspace.sessionDidResignActiveNotification, CaptureInterruption.sessionResigned),
		] {
			let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					_ = self?.handleCaptureInterruption(interruption)
				}
			}
			powerStateObservers.append((workspace, token))
		}
		let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
			[weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.micStreamSuspension.endAfterWake() else { return }
				self.applyMicStreamPolicy()
			}
		}
		powerStateObservers.append((workspace, wake))

		let distributed = DistributedNotificationCenter.default()
		for (name, begins) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
			let token = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated {
					self?.updateStreamSuspension(.screenLocked, active: begins)
				}
			}
			powerStateObservers.append((distributed, token))
		}

		let power = NotificationCenter.default.addObserver(
			forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.updateStreamSuspension(
					.lowPowerMode, active: ProcessInfo.processInfo.isLowPowerModeEnabled)
			}
		}
		powerStateObservers.append((NotificationCenter.default, power))
		if ProcessInfo.processInfo.isLowPowerModeEnabled {
			micStreamSuspension.begin(.lowPowerMode)
		}
	}

	private func updateStreamSuspension(_ reason: MicStreamSuspension.Reason, active: Bool) {
		if active {
			guard micStreamSuspension.begin(reason) else { return }
			AppLogger.shared.audioManager.info("Suspending kept-open microphone stream: \(reason.rawValue)")
			// An active recording keeps its stream; releaseStreamingEngine closes it on stop
			guard !isSessionActive, engineController.isRunning else { return }
			shutdownStreamingEngine()
		} else {
			guard micStreamSuspension.end(reason) else { return }
			AppLogger.shared.audioManager.info("Microphone stream suspension lifted")
			applyMicStreamPolicy()
		}
	}

	private func streamPolicySnapshot() -> String {
		let settings = RecordingControlSettings()
		return "\(settings.micStreamPolicy.rawValue)|\(captureRoute)"
	}
}

// MARK: - Interruptions
extension AudioManager {
	@discardableResult
	func handleCaptureInterruption(_ interruption: CaptureInterruption) -> CaptureInterruptionResponse {
		let response = interruptionPolicy.respond(
			to: interruption, isRecording: isRecording, isStarting: isMicrophoneInitializing && !isRecording,
			path: activeCapturePath, isRestarting: deviceActivationTask != nil)
		switch response {
		case .ignore:
			break
		case .restartInput:
			AppLogger.shared.audioManager.info("Restarting the microphone mid-recording after \(interruption)")
			reactivateInputDuringRecording()
		case .finish(let notice):
			AppLogger.shared.audioManager.info("Stopping the recording early after \(interruption)")
			finishInterruptedRecording(notice: notice)
		case .cancelStartup:
			AppLogger.shared.audioManager.info("Abandoning microphone startup after \(interruption)")
			cancelRecording()
		}
		return response
	}

	/// Stops without the tail and transcribes what was captured, telling the user why it ended.
	fileprivate func finishInterruptedRecording(notice: String) {
		tailStop.cancel()
		pendingStopNotice = notice
		stopRecording()
		// Live mode and empty recordings have no session to carry the notice
		if let unclaimed = pendingStopNotice {
			transcriptionError = unclaimed
			pendingStopNotice = nil
		}
	}

	fileprivate func attachStopNotice(to session: DictationSession) {
		guard let notice = pendingStopNotice else { return }
		stopNotices[session.id] = notice
		pendingStopNotice = nil
	}

	/// AVAudioEngine does not always announce that it stopped (a wake from sleep, a device that
	/// vanished mid-reconfiguration), and a closed lid does not change the open device by itself,
	/// so a recording checks its own stream once a second.
	fileprivate func startCaptureWatchdog() {
		captureWatchdog?.invalidate()
		captureWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
			MainActor.assumeIsolated {
				guard let self, self.isSessionActive else {
					timer.invalidate()
					return
				}
				self.checkCaptureHealth()
			}
		}
	}

	private func checkCaptureHealth() {
		guard activeCapturePath == .stream, isRecording, !isMicrophoneInitializing, deviceActivationTask == nil
		else { return }
		if !engineController.isEngineRunning {
			handleCaptureInterruption(.engineStopped)
			return
		}
		// Compared with what was expected when the stream opened, not with what the audio unit
		// reports, so a device that reports a different ID cannot trigger endless restarts
		guard let expected = deviceManager.expectedInputDeviceID(), expected != openStreamExpectedDeviceID
		else { return }
		let name = deviceManager.deviceName(forID: expected) ?? String(localized: "the new microphone")
		AppLogger.shared.audioManager.info("Recording input moved to \(name); following it")
		if handleCaptureInterruption(.inputDeviceChanged) == .restartInput {
			inputNotice = String(localized: "Switched to \(name).")
		}
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
		muteOutputAfterStartSound()
		whisperKitTranscriber.clearLiveTranscriptionState()
		whisperKitTranscriber.beginLiveTranscriptionWaitingUI()
		let session = ledger.capturing?.id

		deviceActivationTask = Task {
			do {
				try await whisperKitTranscriber.liveStream()
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.info("Live transcription started")
			} catch {
				// A stop, cancel or newer session already owns the state
				guard !Task.isCancelled, !(error is CancellationError), isCurrentCapture(session) else {
					return
				}
				deviceActivationTask = nil
				isMicrophoneInitializing = false
				isRecording = false
				timer.stop()
				restoreSystemOutput()
				activeCapturePath = nil
				ledger.dropCapture()
				deviceManager.restoreSystemDefault()
				deviceManager.endRecordingSession()
				levelMonitor.reset()
				scheduleTimerReset()
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

		activeCapturePath = nil
		ledger.dropCapture()
		whisperKitTranscriber.stopLiveStream()
		deviceManager.endRecordingSession()
		levelMonitor.reset()
		AppLogger.shared.audioManager.info("Live transcription stopped")

		let session = whisperKitTranscriber.takeLastLiveSession()
		if session.text.isEmpty, VoiceActivitySettings(defaults: .standard).enabled {
			transcriptionError = VoiceActivitySettings.noSpeechNotice
		}
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
	/// Returns the clip trimmed to its speech, or nil when it holds no speech and
	/// must not be transcribed.
	fileprivate func applyVoiceActivityDetection(_ samples: [Float]) async -> [Float]? {
		let settings = VoiceActivitySettings(defaults: .standard)
		guard settings.enabled else { return samples }

		var neuralResult: VoiceActivityResult?
		if settings.engine == .neural {
			do {
				neuralResult = try await NeuralVoiceActivityDetector.shared.process(
					samples, sensitivity: settings.sensitivity)
			} catch {
				AppLogger.shared.audioManager.error("Neural VAD failed, using the energy detector: \(error)")
			}
		}
		let result: VoiceActivityResult
		if let neuralResult {
			result = neuralResult
		} else {
			let trimmer = VoiceActivityTrimmer(sensitivity: settings.sensitivity)
			result = await Task.detached(priority: .userInitiated) {
				trimmer.process(samples)
			}.value
		}

		switch result {
		case .noSpeech:
			AppLogger.shared.audioManager.info(
				"VAD found no speech in \(samples.count) samples, skipping transcription")
			transcriptionError = VoiceActivitySettings.noSpeechNotice
			return nil
		case .speech(let trimmed):
			AppLogger.shared.audioManager.debug(
				"VAD trimmed clip from \(samples.count) to \(trimmed.count) samples")
			return trimmed
		}
	}

	/// Registers the transcription so cancel can reach it from the moment capture stops.
	fileprivate func startTranscription(
		_ session: DictationSession, _ work: @escaping @MainActor (AudioManager) async -> Void
	) {
		syncTranscribingState()
		transcriptionTasks[session.id] = Task { [weak self] in
			guard let self else { return }
			await work(self)
			self.finishTranscription(session.id)
		}
	}

	fileprivate func finishTranscription(_ id: Int) {
		ledger.completeTranscription(id)
		transcriptionTasks[id] = nil
		releaseModel(for: id)
		syncTranscribingState()
		if let notice = stopNotices.removeValue(forKey: id) {
			transcriptionError = [notice, transcriptionError].compactMap { $0 }.joined(separator: "\n")
		}
	}

	fileprivate func syncTranscribingState() {
		let transcribing = ledger.isTranscribing
		if isTranscribing != transcribing {
			isTranscribing = transcribing
		}
	}

	fileprivate func transcribeAudioBuffer(
		audioArray: [Float], enableTranslation: Bool, session: DictationSession
	) async {
		guard let audioArray = await applyVoiceActivityDetection(audioArray) else { return }
		await runTranscription(session: session, historyAudio: .samples(audioArray, sampleRate: 16000)) {
			try await self.whisperKitTranscriber.transcribeAudioArray(
				audioArray, enableTranslation: enableTranslation)
		}
	}

	fileprivate func transcribeAudio(
		fileURL: URL, channel: Int, enableTranslation: Bool, session: DictationSession
	) async {
		// A single-channel pick needs the samples in hand to drop the other channels
		if VoiceActivitySettings(defaults: .standard).enabled || channel != InputChannelSelection.mixAllChannels {
			let path = fileURL.path
			let samples = await Task.detached(priority: .userInitiated) {
				try? InputChannelSelection.loadSamples(fromPath: path, selected: channel)
			}.value
			if let samples {
				try? FileManager.default.removeItem(at: fileURL)
				await transcribeAudioBuffer(
					audioArray: samples, enableTranslation: enableTranslation, session: session)
				return
			}
			AppLogger.shared.audioManager.error("VAD could not load recording, transcribing untrimmed file")
		}

		await runTranscription(session: session, historyAudio: .file(fileURL)) {
			try await self.whisperKitTranscriber.transcribe(
				audioURL: fileURL, enableTranslation: enableTranslation)
		}
		// No-op when history already moved the recording into its own folder
		try? FileManager.default.removeItem(at: fileURL)
	}

	private func runTranscription(
		session: DictationSession, historyAudio: TranscriptionHistoryAudio,
		_ work: () async throws -> String
	) async {
		let id = session.id
		guard !ledger.isCancelled(id), !Task.isCancelled else {
			AppLogger.shared.audioManager.info("Skipping transcription of a cancelled recording")
			return
		}
		transcriptionError = nil

		do {
			let rawTranscription = try await work()
			guard !ledger.isCancelled(id) else {
				AppLogger.shared.audioManager.info("Discarding transcription of a cancelled recording")
				return
			}
			guard !Self.isEmptyTranscript(rawTranscription) else {
				// Nothing to paste, post-process or keep in history
				AppLogger.shared.audioManager.info("No speech in the recording; skipping paste and history")
				lastTranscription = nil
				finishTranscription(id)
				return
			}
			let secureBeforeProcessing = SecureDictation.isSecureInputActive
			let processed = await postProcessIfRequested(
				rawTranscription,
				requested: SecureDictationPolicy.resolve(
					postProcessRequested: session.postProcess, secureInput: secureBeforeProcessing
				).postProcess)
			let transcription = processed.text
			guard !ledger.isCancelled(id) else {
				AppLogger.shared.audioManager.info("Discarding post-processed text of a cancelled recording")
				return
			}
			let policy = SecureDictationPolicy.resolve(
				postProcessRequested: session.postProcess,
				secureInput: secureBeforeProcessing || SecureDictation.isSecureInputActive)
			if let notice = SecureDictationPolicy.skippedPostProcessingNotice(
				postProcessRequested: session.postProcess,
				secureInput: secureBeforeProcessing || SecureDictation.isSecureInputActive)
			{
				transcriptionError = notice
			}
			if policy.rememberAsLastTranscription {
				lastTranscription = transcription
			} else {
				AppLogger.shared.audioManager.info(
					"Secure input is on; the dictation is pasted but not kept in history or post-processed")
			}
			finishTranscription(id)

			if session.mode == .text {
				pasteToFocusedApp(transcription, concealed: policy.concealClipboard)
			}
			// After the paste so saving the recording never delays the text
			if policy.saveToHistory {
				recordHistory(text: rawTranscription, audio: historyAudio, postProcessing: processed.history)
			}
		} catch {
			guard !ledger.isCancelled(id) else { return }
			transcriptionError = error.localizedDescription
			lastTranscription = "Transcription failed: \(error.localizedDescription)"
			finishTranscription(id)
			// Keeps the request so a retry from history post-processes like the original would have
			recordHistory(
				text: "", audio: historyAudio, errorMessage: error.localizedDescription,
				postProcessRequested: session.postProcess)
		}
	}

	nonisolated static func isEmptyTranscript(_ text: String) -> Bool {
		text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	fileprivate func recordHistory(
		text: String, audio: TranscriptionHistoryAudio?,
		source: TranscriptionHistorySource = .dictation, errorMessage: String? = nil,
		postProcessing: HistoryPostProcessing? = nil, postProcessRequested: Bool = false
	) {
		// Also covers live dictation, whose segments were typed into whatever field has focus
		guard !SecureDictation.isSecureInputActive else {
			AppLogger.shared.audioManager.info("Secure input is on; not saving this dictation to history")
			return
		}
		TranscriptionHistoryStore.shared.record(
			text: text,
			audio: audio,
			source: source,
			modelName: whisperKitTranscriber.currentModel ?? whisperKitTranscriber.selectedModel,
			language: selectedLanguage,
			errorMessage: errorMessage,
			postProcessing: postProcessing,
			postProcessRequested: postProcessRequested
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
		FeedbackSoundPlayer.shared.duration(start: true)
	}
	fileprivate func playFeedbackSound(start: Bool) {
		FeedbackSoundPlayer.shared.play(start: start)
	}
	fileprivate func pasteToFocusedApp(_ text: String, concealed: Bool = false) {
		TextInserter.shared.insert(text, context: .finalTranscript, concealed: concealed)
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
