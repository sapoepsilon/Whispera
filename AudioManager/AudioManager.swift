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

/// What a recording does when its microphone disappears.
enum InputLossResponse: Equatable {
	/// Nothing is capturing yet, so startup simply runs again on the fallback input.
	case restartStartup
	/// The capture reopens on the fallback input and keeps the audio it already has.
	case followFallbackInput
	/// AVAudioRecorder stays bound to the device it opened and cannot be moved, so the file
	/// is finished and what was captured is transcribed.
	case finishRecording

	static func decide(path: CapturePath?, isStartingCapture: Bool) -> InputLossResponse {
		if isStartingCapture { return .restartStartup }
		return path == .file ? .finishRecording : .followFallbackInput
	}

	/// The pill is the only place the notice shows during a text recording; live mode has no pill
	/// and no session result to carry it.
	static func fallbackNoticeNeedsNotification(isLive: Bool, overlay: RecordingOverlayStyle) -> Bool {
		isLive || overlay != .pill
	}

	static func fallbackNotice(lostDevice name: String) -> String {
		String(localized: "\(name) disconnected. Using the system default microphone.")
	}

	static func finishedNotice(lostDevice name: String) -> String {
		String(
			localized:
				"\(name) disconnected, so the recording was stopped. What was captured was transcribed.")
	}
}

enum AudioState {
	case idle
	case initializing
	case recording
	case transcribing
}

// Both recording windows route through this policy so they can never disagree
// via separate preferences. The listening pill is the persistent home for
// recording/transcribing status in both modes; the live-transcription window
// layers above it and only shows in live mode, and only once there is
// something transient to say (words, a waiting-for-model status, or an
// error) — see PillAnchor for how the two stay glued together on screen.
enum RecordingWindowPolicy {
	static func shouldShowListeningWindow(state: AudioState) -> Bool {
		state != .idle
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
	var transcriptionError: String? {
		didSet {
			transcriptionErrorIsNotice = transcriptionError != nil && isPostingNotice
			transcriptionErrorNotifiesWhenHidden =
				transcriptionError != nil && (!isPostingNotice || isPostingNotifyingNotice)
		}
	}
	/// True when `transcriptionError` is routine information (no speech heard, a recording that
	/// stopped early, Secure Input skipping post-processing) rather than a failure needing the user,
	/// so it is shown in the menu bar without a system notification.
	private(set) var transcriptionErrorIsNotice = false
	/// Failures always raise a system notification when the menu bar is closed; notices only when
	/// nothing else on screen could have shown them.
	private(set) var transcriptionErrorNotifiesWhenHidden = false
	@ObservationIgnored
	private var isPostingNotice = false
	@ObservationIgnored
	private var isPostingNotifyingNotice = false
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

	/// Observed so the popover's mode control, caption and header follow changes made in Settings.
	@ObservationIgnored
	private let translationSetting = ObservedDefaultsFlag(key: "enableTranslation", defaultValue: false)
	var enableTranslation: Bool {
		get { translationSetting.value }
		set { translationSetting.set(newValue) }
	}
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
	private var fileSegments = FileRecordingSegments()
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

	/// The engine the user selected. Resolved per call rather than cached so a
	/// change in Settings applies to the next dictation without a restart, and
	/// so remote and on-device reach AudioManager through one interface instead
	/// of a branch. See WHI-58.
	@ObservationIgnored
	var transcriberProvider: () -> SpeechTranscribing = { TranscriptionRouter.shared.active }

	private var transcriber: SpeechTranscribing { transcriberProvider() }

	/// The engine the current dictation started on. Keeping it means a change in
	/// Settings mid-recording cannot route stop, or a device switch, at an
	/// engine that never started — the same reason a session keeps the mode it
	/// began with.
	@ObservationIgnored
	private var sessionTranscriber: SpeechTranscribing?

	/// Options for one dictation. The language is passed for engines that need
	/// telling; WhisperKit reads its own persisted language, as it always has.
	fileprivate func dictationOptions(translate: Bool) -> TranscriptionOptions {
		TranscriptionOptions(
			mode: translate ? .translate : .transcribe,
			language: Constants.languageCode(for: selectedLanguage))
	}

	/// Transforms a finished transcription before it is pasted (recipe matching
	/// + execution; the Bool asks for Clean up). Returns nil to paste nothing.
	/// Injected by the app so AudioManager stays free of recipe/network
	/// dependencies. WHI-41.
	@ObservationIgnored
	var dictationProcessor: ((String, Bool) async -> DictationResult?)?

	// MARK: - Initialization

	override init() {
		super.init()
		SystemOutputMuter.shared.recoverFromUncleanExit()
		whisperKitTranscriber.startInitialization()
		whisperKitTranscriber.onLiveAudioSamples = liveAudioSampleHandler()
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

	private func liveAudioSampleHandler() -> @MainActor ([Float]) -> Void {
		{ [weak self] samples in
			// Engines deliver per-buffer chunks; cap the window so level
			// math stays cheap even if a large backlog arrives at once
			self?.levelMonitor.update(from: Array(samples.suffix(4800)))
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
		// Clean up rewrites the whole transcript, so a session that asks for it runs in text mode.
		let cleanUp = postProcess && CleanUpSettings().isOnRequestEnabled
		let mode: RecordingMode =
			enableStreaming && whisperKitTranscriber.supportsLiveTranscription && !cleanUp
			? .liveTranscription : .text
		currentRecordingMode = mode
		startRecording(mode: mode, postProcess: cleanUp)
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
		abandon(cancelled)

		if capturing {
			discardCapture()
		}

		syncTranscribingState()
		AppLogger.shared.audioManager.info("Recording cancelled; audio discarded")
	}

	/// The capture being recorded now, if any.
	var captureSessionID: Int? {
		ledger.capturing?.id
	}

	/// Discards one capture and nothing else. Unlike `cancelRecording`, it never falls back to
	/// abandoning the transcriptions in flight when that capture has already ended or never got
	/// going, so a key press that turned out to be a shortcut cannot throw away earlier dictations.
	func cancelCapture(sessionID: Int) {
		guard isSessionActive, let session = ledger.cancelCapture(id: sessionID) else { return }
		abandon([session])
		discardCapture()
		syncTranscribingState()
		AppLogger.shared.audioManager.info("Recording \(sessionID) cancelled; audio discarded")
	}

	private func discardCapture() {
		pendingStopAfterStart = false
		tailStop.cancel()
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		switch activeCapturePath {
		case .live:
			let engine = sessionTranscriber ?? transcriber
			sessionTranscriber = nil
			if engine === whisperKitTranscriber {
				whisperKitTranscriber.cancelLiveStream()
			} else {
				Task { await engine.stopStreaming() }
			}
		case .file:
			stopMeteringTimer()
			audioRecorder?.stop()
			audioRecorder = nil
			if let audioFileURL {
				try? FileManager.default.removeItem(at: audioFileURL)
			}
			audioFileURL = nil
			FileRecordingSegments.removeFiles(of: fileSegments.takeAll(current: nil))
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

	/// Abandons the dictations still transcribing. Unlike `cancelRecording`, a recording that is
	/// running keeps going, so "Cancel Transcription" never throws away what is being dictated now.
	func cancelTranscriptions() {
		let cancelled = ledger.cancelTranscriptions()
		guard !cancelled.isEmpty else { return }
		abandon(cancelled)
		syncTranscribingState()
		AppLogger.shared.audioManager.info("Cancelled \(cancelled.count) transcription(s) in flight")
	}

	private func abandon(_ sessions: [DictationSession]) {
		for session in sessions {
			transcriptionTasks.removeValue(forKey: session.id)?.cancel()
			releaseModel(for: session.id)
			stopNotices[session.id] = nil
		}
	}

	func postNotice(_ notice: String, notifyWhenHidden: Bool = false) {
		isPostingNotice = true
		isPostingNotifyingNotice = notifyWhenHidden
		defer {
			isPostingNotice = false
			isPostingNotifyingNotice = false
		}
		transcriptionError = notice
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
		let response = InputLossResponse.decide(path: activeCapturePath, isStartingCapture: isStartingCapture)
		AppLogger.shared.audioManager.info("Lost input \(name) while recording; response: \(String(describing: response))")
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		if response == .finishRecording {
			finishInterruptedRecording(notice: InputLossResponse.finishedNotice(lostDevice: name))
			return
		}
		deviceManager.beginFallbackToSystemDefault()
		let notice = InputLossResponse.fallbackNotice(lostDevice: name)
		inputNotice = notice
		// Only the pill shows the notice while recording, so without it the user hears about the
		// switch now, as a system notification when the menu bar is closed; with the pill it comes
		// with the text
		if InputLossResponse.fallbackNoticeNeedsNotification(
			isLive: activeCapturePath == .live, overlay: RecordingOverlayStyle.stored())
		{
			postNotice(notice, notifyWhenHidden: true)
		} else if pendingStopNotice == nil {
			pendingStopNotice = notice
		}
		if response == .restartStartup {
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
				await (sessionTranscriber ?? transcriber).switchStreamingDevice()
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
			} else if activeCapturePath == .file {
				// AVAudioRecorder cannot move to another input: finish this part of the file and
				// record the next one on the new microphone; stopping joins the parts
				finishCurrentFileSegment()
				deviceManager.restoreSystemDefault()
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				do {
					try openFileRecorder()
					isMicrophoneInitializing = false
					AppLogger.shared.audioManager.info("Switched input device while recording to a file")
				} catch {
					AppLogger.shared.audioManager.error("Failed to reopen the recording on the new device: \(error)")
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
		// Auto-clear the previous glance so a new recording never displays a stale
		// result or error underneath it.
		lastTranscription = nil
		transcriptionError = nil
		pendingStopNotice = nil
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

			do {
				try openFileRecorder()
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
	/// Opens a new recording file on the current system input.
	private func openFileRecorder() throws {
		let audioFilename = getApplicationSupportDirectory()
			.appendingPathComponent("recordings")
			.appendingPathComponent("recording_\(Date().timeIntervalSince1970)_\(UUID().uuidString.prefix(8)).wav")
		try? FileManager.default.createDirectory(
			at: audioFilename.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		let selectedChannel = InputChannelSelection.stored(in: .standard)
		let recordedChannels = InputChannelSelection.fileRecordingChannelCount(
			selected: selectedChannel, deviceChannels: deviceManager.effectiveInputChannelCount)
		let channel = recordedChannels > 1 ? selectedChannel : InputChannelSelection.mixAllChannels

		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: recordedChannels,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
		]
		let recorder = try AVAudioRecorder(url: audioFilename, settings: settings)
		recorder.isMeteringEnabled = true
		recorder.record()
		audioRecorder = recorder
		audioFileURL = audioFilename
		fileCaptureChannel = channel
	}

	/// Closes the file being recorded and keeps it as a finished part of this recording.
	private func finishCurrentFileSegment() {
		audioRecorder?.stop()
		audioRecorder = nil
		if let audioFileURL {
			fileSegments.finish(.init(url: audioFileURL, channel: fileCaptureChannel))
		}
		audioFileURL = nil
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
		let segments = fileSegments.takeAll(
			current: audioFileURL.map { .init(url: $0, channel: fileCaptureChannel) })
		if !segments.isEmpty, let session = ledger.finishCapture() {
			attachStopNotice(to: session)
			let translate = enableTranslation
			startTranscription(session) { manager in
				if segments.count == 1, let only = segments.first {
					await manager.transcribeAudio(
						fileURL: only.url, channel: only.channel, enableTranslation: translate, session: session)
				} else {
					await manager.transcribeAudio(segments: segments, enableTranslation: translate, session: session)
				}
			}
		} else {
			FileRecordingSegments.removeFiles(of: segments)
			if let dropped = ledger.dropCapture() {
				releaseModel(for: dropped.id)
			}
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
			postNotice(unclaimed)
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
		let engine = transcriber
		sessionTranscriber = engine
		engine.onLiveAudioSamples = liveAudioSampleHandler()
		engine.resetStreamingSession()
		LiveTranscriptionState.shared.beginWaiting()
		let session = ledger.capturing?.id

		deviceActivationTask = Task {
			do {
				try await engine.startStreaming(options: dictationOptions(translate: enableTranslation))
				guard !Task.isCancelled, isCurrentCapture(session) else { return }
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.info("Live transcription started")
			} catch {
				// A stop, cancel or newer session already owns the state
				guard !Task.isCancelled, !(error is CancellationError), isCurrentCapture(session) else {
					return
				}
				deviceActivationTask = nil
				sessionTranscriber = nil
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
				transcriptionError = error.localizedDescription
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
		let engine = sessionTranscriber ?? transcriber
		sessionTranscriber = nil
		deviceManager.endRecordingSession()
		levelMonitor.reset()
		AppLogger.shared.audioManager.info("Live transcription stopped")
		scheduleTimerReset()

		// The on-device engine typed its words as they were confirmed; a remote
		// engine pastes its finished transcript once, here. See WHI-58.
		guard engine === whisperKitTranscriber else {
			finishRemoteLiveDictation(engine)
			return
		}
		let finishing = whisperKitTranscriber.stopLiveStream()
		// The words said after the newest live pass are decoded before the session is complete
		Task { @MainActor [weak self] in
			guard await finishing.value, let self else { return }
			let session = self.whisperKitTranscriber.takeLastLiveSession()
			if session.text.isEmpty, VoiceActivitySettings(defaults: .standard).enabled {
				self.postNotice(VoiceActivitySettings.noSpeechNotice)
			}
			if !session.text.isEmpty {
				self.recordHistory(
					text: session.text,
					audio: session.samples.isEmpty ? nil : .samples(session.samples, sampleRate: 16000),
					source: .liveDictation)
			}
		}
	}

	/// The remote stream is not final until it actually closes (a network round
	/// trip), so the paste waits for that, then goes through the same recipe
	/// processor and secure-input rules as a text-mode dictation.
	private func finishRemoteLiveDictation(_ engine: SpeechTranscribing) {
		isTranscribing = true
		Task { @MainActor [weak self] in
			let draft = await engine.stopStreaming()
			// The two-pass finalizer, when the engine retained audio for one. It
			// answers nil with no real suspension on the instant path, so a
			// finalizer set to off pastes exactly as fast as before; when it is
			// on, this is the bounded "polishing" wait, and isTranscribing holds
			// the spinner up until the paste lands.
			let polished = await engine.finalizeDictation(draft: draft)
			guard let self else { return }
			defer { self.syncTranscribingState() }
			guard let text = Self.textToPaste(afterLiveDictationFinished: polished ?? draft) else { return }
			let secure = SecureDictation.isSecureInputActive
			let policy = SecureDictationPolicy.resolve(postProcessRequested: false, secureInput: secure)
			let processed = await self.applyDictationProcessor(
				text, mode: .text, secureInput: policy.concealClipboard, cleanUp: false)
			if policy.rememberAsLastTranscription {
				self.lastTranscription = text
			}
			if let toPaste = processed?.text, !toPaste.isEmpty {
				self.pasteToFocusedApp(toPaste, concealed: policy.concealClipboard)
			}
			if policy.saveToHistory {
				self.recordHistory(
					text: text, audio: nil, source: .liveDictation, postProcessing: processed?.history)
			}
		}
	}

	/// What a finished live dictation should paste, if anything. Cancelling
	/// during startup (`cancelCaptureStartup`) and a failed `startStreaming`
	/// never reach `stopStreaming` at all, so they never reach this function
	/// either — the only case left to decide is whether the engine actually
	/// produced words. An empty or whitespace-only transcript is not an error:
	/// the user said nothing, or a stream closed before confirming anything.
	nonisolated static func textToPaste(afterLiveDictationFinished transcript: String) -> String? {
		let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
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
			postNotice(VoiceActivitySettings.noSpeechNotice)
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
			let combined = [notice, transcriptionError].compactMap { $0 }.joined(separator: "\n")
			if transcriptionError == nil || transcriptionErrorIsNotice {
				postNotice(combined)
			} else {
				transcriptionError = combined
			}
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
			try await self.transcriber.transcribe(
				samples: audioArray, options: self.dictationOptions(translate: enableTranslation))
		}
	}

	/// A file recording that changed microphones part way through: its parts are joined first.
	fileprivate func transcribeAudio(
		segments: [FileRecordingSegments.Segment], enableTranslation: Bool, session: DictationSession
	) async {
		let joined = await Task.detached(priority: .userInitiated) {
			Result { try FileRecordingSegments.loadJoined(segments) }
		}.value
		FileRecordingSegments.removeFiles(of: segments)
		switch joined {
		case .success(let samples):
			await transcribeAudioBuffer(audioArray: samples, enableTranslation: enableTranslation, session: session)
		case .failure(let error):
			await runTranscription(session: session, historyAudio: .samples([], sampleRate: 16000)) {
				throw error
			}
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
			try await self.transcriber.transcribe(
				fileAt: fileURL, options: self.dictationOptions(translate: enableTranslation))
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
			let policy = SecureDictationPolicy.resolve(
				postProcessRequested: session.postProcess, secureInput: SecureDictation.isSecureInputActive)
			if let notice = SecureDictationPolicy.skippedPostProcessingNotice(
				postProcessRequested: session.postProcess, secureInput: SecureDictation.isSecureInputActive)
			{
				postNotice(notice)
			}
			let processed = await applyDictationProcessor(
				rawTranscription, mode: session.mode, secureInput: policy.concealClipboard,
				cleanUp: policy.postProcess)
			guard !ledger.isCancelled(id) else {
				AppLogger.shared.audioManager.info("Discarding the processed dictation of a cancelled recording")
				return
			}
			if policy.rememberAsLastTranscription {
				lastTranscription = processed?.text ?? rawTranscription
			} else {
				AppLogger.shared.audioManager.info(
					"Secure input is on; the dictation is pasted but not kept in history or sent to a recipe")
			}
			finishTranscription(id)

			if session.mode == .text, let toPaste = processed?.text {
				pasteToFocusedApp(toPaste, concealed: policy.concealClipboard)
			}
			// After the paste so saving the recording never delays the text
			if policy.saveToHistory {
				recordHistory(text: rawTranscription, audio: historyAudio, postProcessing: processed?.history)
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

	/// Runs the transcription through the dictation processor (recipe matching +
	/// execution) when in text mode. Returns nil to paste nothing. Never runs on
	/// a dictation into a secure input field, which stays out of every LLM. WHI-41.
	fileprivate func applyDictationProcessor(
		_ transcription: String, mode: RecordingMode, secureInput: Bool, cleanUp: Bool
	) async -> DictationResult? {
		guard mode == .text, !secureInput, let processor = dictationProcessor else {
			return DictationResult(text: transcription, history: nil)
		}
		return await processor(transcription, cleanUp)
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
		// read before the paste moves the caret; observers use it as the
		// destination for the dictation particle flight
		let caret = MagnetField.caretRect()
		NotificationCenter.default.post(
			name: .dictationWillPaste, object: caret.map { NSValue(rect: $0) })

		// the particle field is already in flight; landing the text as it arrives
		// reads as one motion, where pasting immediately puts the text on screen
		// well before the animation catches up
		let lead = MagnetField.pasteLeadTime(caret: caret)
		if lead > 0 {
			DispatchQueue.main.asyncAfter(deadline: .now() + lead) {
				TextInserter.shared.insert(text, context: .finalTranscript, concealed: concealed)
			}
		} else {
			TextInserter.shared.insert(text, context: .finalTranscript, concealed: concealed)
		}
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
		alert.messageText = String(localized: "Microphone Access Required")
		alert.informativeText = String(
			localized:
				"Whispera needs access to your microphone to transcribe audio. Please grant permission in System Settings > Privacy & Security > Microphone."
		)
		alert.alertStyle = .warning
		alert.addButton(withTitle: String(localized: "Open System Settings"))
		alert.addButton(withTitle: String(localized: "Cancel"))

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
