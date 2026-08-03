import AVFoundation
import AppKit
import Foundation
import SwiftUI

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

/// Where a device selection has to land. Extracted from switchInputDevice so the
/// routing matrix can be exercised without standing up an AudioManager.
enum DeviceSwitchRoute: Equatable, Sendable {
	case startupInFlight
	case nextRecording
	case liveRestart
	case engineRestart
	case fileRecorderRestart
}

enum RecordingSegmentError: Error, LocalizedError {
	case recorderRefusedToStart
	case unreadableSegment(URL)

	var errorDescription: String? {
		switch self {
		case .recorderRefusedToStart:
			return "The audio recorder refused to start on the selected input"
		case .unreadableSegment(let url):
			return "Could not read recording segment \(url.lastPathComponent)"
		}
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
	private var recordingPreparationTask: Task<Void, Never>?
	/// True from the moment a start path is entered until capture is established
	/// (or the attempt aborts). A device switch arriving in this window must not
	/// cancel the task that is bringing capture up.
	@ObservationIgnored
	private var isStartingCapture = false
	/// File segments already closed by a mid-recording device switch. The live
	/// segment lives in audioFileURL and joins these at stop.
	@ObservationIgnored
	private var completedSegmentURLs: [URL] = []

	@ObservationIgnored
	let whisperKitTranscriber = WhisperKitTranscriber.shared

	/// Transforms a finished transcription before it is pasted (recipe matching
	/// + execution). Returns nil to paste nothing. Injected by the app so
	/// AudioManager stays free of recipe/network dependencies. WHI-41.
	@ObservationIgnored
	var dictationProcessor: ((String) async -> String?)?

	// MARK: - Initialization

	override init() {
		super.init()
		whisperKitTranscriber.startInitialization()
		whisperKitTranscriber.onLiveAudioSamples = { [weak self] samples in
			// WhisperKit delivers per-buffer chunks; cap the window so level
			// math stays cheap even if a large backlog arrives at once
			self?.levelMonitor.update(from: Array(samples.suffix(4800)))
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
		} else if isMicrophoneInitializing, let recordingPreparationTask {
			// A second shortcut press during the bounded media preflight is cancel,
			// not another recording start.
			recordingPreparationTask.cancel()
			self.recordingPreparationTask = nil
			isMicrophoneInitializing = false
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
		} else {
			currentRecordingMode = enableStreaming ? .liveTranscription : .text
			startRecording()
		}
	}

	nonisolated static func deviceSwitchRoute(
		isStartingCapture: Bool,
		isRecording: Bool,
		isMicrophoneInitializing: Bool,
		mode: RecordingMode,
		useStreaming: Bool
	) -> DeviceSwitchRoute {
		// Startup wins over everything: isMicrophoneInitializing is also true while
		// capture is coming up, so without this the startup would be mistaken for an
		// established session and torn down.
		if isStartingCapture { return .startupInFlight }
		guard isRecording || isMicrophoneInitializing else { return .nextRecording }
		if mode == .liveTranscription { return .liveRestart }
		return useStreaming ? .engineRestart : .fileRecorderRestart
	}

	/// Whether a failed activation should be mirrored back into the selection. The
	/// persisted UID moving away from the one that was activated means either the
	/// user re-picked while activation was in flight - that newer choice is applied
	/// separately and must not be overwritten - or activateSelectedDevice already
	/// healed a vanished device itself.
	nonisolated static func shouldHealSelectionAfterFailedActivation(
		activated: Bool,
		activationUID: String,
		persistedUID: String
	) -> Bool {
		guard !activated else { return false }
		return persistedUID == activationUID
	}

	func switchInputDevice(to uid: String) {
		AppLogger.shared.audioManager.info(
			"switchInputDevice(to: \(uid)) state=\(currentState) mode=\(currentRecordingMode)")

		let route = Self.deviceSwitchRoute(
			isStartingCapture: isStartingCapture,
			isRecording: isRecording,
			isMicrophoneInitializing: isMicrophoneInitializing,
			mode: currentRecordingMode,
			useStreaming: useStreamingTranscription
		)

		deviceManager.selectDevice(uid: uid)

		switch route {
		case .startupInFlight:
			AppLogger.shared.audioManager.info(
				"switchInputDevice: capture startup in flight, selection persisted and applied once capture is established")
			return
		case .nextRecording:
			deviceActivationTask?.cancel()
			deviceActivationTask = nil
			AppLogger.shared.audioManager.info(
				"switchInputDevice: not capturing, activation deferred to next recording start")
			return
		case .liveRestart, .engineRestart, .fileRecorderRestart:
			deviceActivationTask?.cancel()
			deviceActivationTask = nil
		}

		isMicrophoneInitializing = true
		deviceActivationTask = Task {
			switch route {
			case .liveRestart:
				await whisperKitTranscriber.switchLiveStreamDevice()
				guard !Task.isCancelled else { return }
				isMicrophoneInitializing = false
			case .engineRestart:
				await restartEngineForDeviceSwitch()
			case .fileRecorderRestart:
				await restartFileRecorderForDeviceSwitch()
			case .startupInFlight, .nextRecording:
				break
			}
			deviceActivationTask = nil
		}
	}

	/// Applies a selection the user made while capture was still coming up. The
	/// tap was deliberately not allowed to cancel the startup task, so it is
	/// replayed here through the established-session path.
	fileprivate func applySelectionMadeDuringStartup(activationUID: String) {
		let current = deviceManager.persistedDeviceUID
		guard current != activationUID else { return }
		AppLogger.shared.audioManager.info(
			"Applying device selection made during capture startup: \(current)")
		switchInputDevice(to: current)
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
		// Auto-clear the previous glance so a new recording never displays a stale
		// result or error underneath it.
		lastTranscription = nil
		transcriptionError = nil
		// Hooked here rather than in startRecording() so a denied mic permission
		// never pauses the user's music for a recording that won't happen.
		isMicrophoneInitializing = true
		recordingPreparationTask = Task { @MainActor in
			await MediaPlaybackCoordinator.shared.pauseBeforeDictation()
			guard !Task.isCancelled else { return }
			recordingPreparationTask = nil
			if currentRecordingMode == .liveTranscription {
				startLiveTranscription()
			} else if useStreamingTranscription {
				startStreamingRecording()
			} else {
				startFileBasedRecording()
			}
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
	/// Keeps the selection mirror honest when the requested input could not be made
	/// the system default. AVAudioRecorder captures from whatever the system default
	/// is, so after a failed activation the recorder is on a different device than
	/// `activeDevice` - and the pill icon - claims. Re-selecting the system default
	/// makes `activeDevice` describe what is really being captured: when activation
	/// failed because the persisted device vanished, activateSelectedDevice healed
	/// the selection itself and this is an idempotent no-op; when it failed because
	/// the CoreAudio set/verify did not take, this is what makes the UI honest.
	/// Returns the UID the caller should treat as activated, so a startup replay does
	/// not restart a recorder that is already on the healed input.
	@discardableResult
	fileprivate func healSelectionIfActivationFailed(activated: Bool, activationUID: String) -> String {
		guard
			Self.shouldHealSelectionAfterFailedActivation(
				activated: activated,
				activationUID: activationUID,
				persistedUID: deviceManager.persistedDeviceUID
			)
		else { return activationUID }

		AppLogger.shared.audioManager.error(
			"Input device activation failed for \(activationUID); recording continues from the actual system default")
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		return AudioDeviceManager.systemDefaultUID
	}

	fileprivate func startFileBasedRecording() {
		isMicrophoneInitializing = true
		isStartingCapture = true
		completedSegmentURLs.removeAll()
		audioFileURL = nil

		deviceActivationTask = Task {
			var activationUID = deviceManager.persistedDeviceUID
			let activated = await deviceManager.activateSelectedDevice()
			guard !Task.isCancelled else {
				isStartingCapture = false
				isMicrophoneInitializing = false
				MediaPlaybackCoordinator.shared.resumeAfterDictation()
				return
			}
			activationUID = healSelectionIfActivationFailed(
				activated: activated, activationUID: activationUID)

			do {
				let segmentURL = try makeRecordingSegmentURL()
				let recorder = try startRecorder(at: segmentURL)
				audioRecorder = recorder
				audioFileURL = segmentURL
				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				startMeteringTimer()
				isStartingCapture = false
				AppLogger.shared.audioManager.debug("File-based recording started")
				applySelectionMadeDuringStartup(activationUID: activationUID)
			} catch {
				isStartingCapture = false
				isMicrophoneInitializing = false
				AppLogger.shared.audioManager.error("Failed to start recording: \(error)")
				MediaPlaybackCoordinator.shared.resumeAfterDictation()
				showRecordingErrorAlert(error)
			}
		}
	}

	/// Reopens the file recorder on the device that was just selected. AudioQueue
	/// pins its input at record() time, so an established file recording only
	/// follows a switch by closing the current segment and starting a new one;
	/// the segments are stitched back together at stop.
	fileprivate func restartFileRecorderForDeviceSwitch() async {
		audioRecorder?.stop()
		audioRecorder = nil
		if let audioFileURL {
			completedSegmentURLs.append(audioFileURL)
		}
		audioFileURL = nil

		let activationUID = deviceManager.persistedDeviceUID
		let activated = await deviceManager.activateSelectedDevice()
		guard !Task.isCancelled else { return }
		healSelectionIfActivationFailed(activated: activated, activationUID: activationUID)

		do {
			let segmentURL = try makeRecordingSegmentURL()
			let recorder = try startRecorder(at: segmentURL)
			audioRecorder = recorder
			audioFileURL = segmentURL
			isMicrophoneInitializing = false
			AppLogger.shared.audioManager.info(
				"Restarted file recorder; capturing from \(deviceManager.activeDevice?.name ?? "system default")")
		} catch {
			isMicrophoneInitializing = false
			AppLogger.shared.audioManager.error(
				"Failed to restart file recorder after device switch: \(error)")
			isRecording = false
			timer.stop()
			// This aborts the recording without reaching any stop path, so
			// without this the user's music would stay paused for good.
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
			discardRecordingSegments()
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

		let segments = completedSegmentURLs + (audioFileURL.map { [$0] } ?? [])
		completedSegmentURLs.removeAll()
		audioFileURL = nil

		if segments.count > 1 {
			Task {
				await transcribeRecordingSegments(segments, enableTranslation: enableTranslation)
			}
		} else if let onlySegment = segments.first {
			Task {
				await transcribeAudio(fileURL: onlySegment, enableTranslation: enableTranslation)
			}
		} else {
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
		}

		scheduleTimerReset()
	}

	fileprivate func makeRecordingSegmentURL() throws -> URL {
		let recordingsDirectory =
			getApplicationSupportDirectory()
			.appendingPathComponent("recordings")

		try FileManager.default.createDirectory(
			at: recordingsDirectory, withIntermediateDirectories: true)

		return recordingsDirectory
			.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
	}

	fileprivate func startRecorder(at url: URL) throws -> AVAudioRecorder {
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: 1,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
		]

		let recorder = try AVAudioRecorder(url: url, settings: settings)
		recorder.isMeteringEnabled = true
		guard recorder.record() else {
			throw RecordingSegmentError.recorderRefusedToStart
		}
		return recorder
	}

	fileprivate func discardRecordingSegments() {
		for url in completedSegmentURLs {
			try? FileManager.default.removeItem(at: url)
		}
		completedSegmentURLs.removeAll()
		if let audioFileURL {
			try? FileManager.default.removeItem(at: audioFileURL)
		}
		audioFileURL = nil
	}

	/// Stitches the segments a mid-recording device switch produced into one
	/// buffer so the dictation is transcribed as a single utterance.
	fileprivate func transcribeRecordingSegments(_ segments: [URL], enableTranslation: Bool) async {
		let samples: [Float]
		do {
			samples = try Self.loadSamples(from: segments)
		} catch {
			AppLogger.shared.audioManager.error("Failed to load recording segments: \(error)")
			samples = []
		}

		for url in segments {
			try? FileManager.default.removeItem(at: url)
		}

		guard !samples.isEmpty else {
			AppLogger.shared.audioManager.info("No audio captured")
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
			return
		}

		await transcribeAudioBuffer(audioArray: samples, enableTranslation: enableTranslation)
	}

	/// Concatenates recorded segments into one mono sample array. A segment that
	/// fails to read is skipped with a logged error: losing the audio around one
	/// device switch beats losing the whole dictation.
	nonisolated static func loadSamples(from urls: [URL]) throws -> [Float] {
		var samples: [Float] = []

		for url in urls {
			do {
				let file = try AVAudioFile(forReading: url)
				let frameCount = AVAudioFrameCount(file.length)
				guard frameCount > 0 else { continue }

				guard
					let buffer = AVAudioPCMBuffer(
						pcmFormat: file.processingFormat, frameCapacity: frameCount)
				else {
					throw RecordingSegmentError.unreadableSegment(url)
				}

				try file.read(into: buffer)

				guard let channelData = buffer.floatChannelData?[0] else {
					throw RecordingSegmentError.unreadableSegment(url)
				}

				samples.append(
					contentsOf: UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
			} catch {
				AppLogger.shared.audioManager.error(
					"Skipping unreadable recording segment \(url.lastPathComponent): \(error)")
			}
		}

		return samples
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
		isMicrophoneInitializing = true
		isStartingCapture = true

		deviceActivationTask = Task {
			let activationUID = deviceManager.persistedDeviceUID
			do {
				await deviceManager.activateSelectedDevice()
				guard !Task.isCancelled else {
					isStartingCapture = false
					isMicrophoneInitializing = false
					MediaPlaybackCoordinator.shared.resumeAfterDictation()
					return
				}
				let _ = try await engineController.setup(deviceID: deviceManager.resolveActiveDeviceID())
				try engineController.installTap { [weak self] buffer, format in
					self?.processAudioBuffer(buffer, originalFormat: format)
				}

				isMicrophoneInitializing = false
				isRecording = true
				timer.start()
				playFeedbackSound(start: true)
				isStartingCapture = false
				applySelectionMadeDuringStartup(activationUID: activationUID)
			} catch {
				isMicrophoneInitializing = false
				isStartingCapture = false
				AppLogger.shared.audioManager.error("Failed to start streaming: \(error)")
				useStreamingTranscription = false
				// No media resume here: the fallback continues the same dictation and
				// its own stop path owns the resume.
				startFileBasedRecording()
			}
		}
	}

	/// Rebuilds the capture engine on the device that was just selected, keeping
	/// the audio recorded so far.
	fileprivate func restartEngineForDeviceSwitch() async {
		let savedBuffer = audioBuffer
		engineController.cleanup()

		do {
			let activated = await deviceManager.activateSelectedDevice()
			guard !Task.isCancelled else { return }
			let _ = try await engineController.setup(deviceID: deviceManager.resolveActiveDeviceID())
			try engineController.installTap { [weak self] buffer, format in
				self?.processAudioBuffer(buffer, originalFormat: format)
			}
			audioBuffer = savedBuffer
			isMicrophoneInitializing = false
			AppLogger.shared.audioManager.info(
				"Switched input device while recording; capturing from \(deviceManager.activeDevice?.name ?? "system default") (activated=\(activated))")
		} catch {
			guard !Task.isCancelled else { return }
			isMicrophoneInitializing = false
			AppLogger.shared.audioManager.error("Failed to switch device: \(error)")
			isRecording = false
			timer.stop()
			// This aborts the recording without reaching any stop path, so
			// without this the user's music would stay paused for good.
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
		}
	}

	fileprivate func stopStreamingRecording() {
		isRecording = false
		timer.stop()
		playFeedbackSound(start: false)

		let capturedAudio = audioBuffer
		audioBuffer.removeAll()
		levelMonitor.reset()

		engineController.cleanup()
		deviceManager.restoreSystemDefault()

		AppLogger.shared.audioManager.info("Streaming recording stopped")

		if !capturedAudio.isEmpty {
			Task {
				await transcribeAudioBuffer(audioArray: capturedAudio, enableTranslation: enableTranslation)
			}
		} else {
			AppLogger.shared.audioManager.info("No audio captured")
			MediaPlaybackCoordinator.shared.resumeAfterDictation()
		}

		scheduleTimerReset()
	}
	fileprivate func processAudioBuffer(_ buffer: AVAudioPCMBuffer, originalFormat: AVAudioFormat) {
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
		isStartingCapture = true
		isRecording = true
		timer.start()
		playFeedbackSound(start: true)
		whisperKitTranscriber.clearLiveTranscriptionState()
		whisperKitTranscriber.beginLiveTranscriptionWaitingUI()

		deviceActivationTask = Task {
			let activationUID = deviceManager.persistedDeviceUID
			do {
				try await whisperKitTranscriber.liveStream()
				// A cancelled live start means stopLiveTranscription already ran, and
				// that path owns the state reset and the media resume.
				guard !Task.isCancelled else {
					isStartingCapture = false
					return
				}
				isMicrophoneInitializing = false
				isStartingCapture = false
				AppLogger.shared.audioManager.info("Live transcription started")
				applySelectionMadeDuringStartup(activationUID: activationUID)
			} catch {
				guard !Task.isCancelled else {
					isStartingCapture = false
					return
				}
				isMicrophoneInitializing = false
				isStartingCapture = false
				isRecording = false
				timer.stop()
				AppLogger.shared.audioManager.error("Failed to start live transcription: \(error)")
				MediaPlaybackCoordinator.shared.resumeAfterDictation()
			}
		}
	}
	fileprivate func stopLiveTranscription() {
		deviceActivationTask?.cancel()
		deviceActivationTask = nil
		// Live is the one mode that can be stopped mid-startup, and a cancelled
		// task may never resume to clear this itself.
		isStartingCapture = false
		isMicrophoneInitializing = false
		isRecording = false
		timer.stop()
		playFeedbackSound(start: false)

		whisperKitTranscriber.stopLiveStream()
		levelMonitor.reset()
		MediaPlaybackCoordinator.shared.resumeAfterDictation()
		AppLogger.shared.audioManager.info("Live transcription stopped")

		scheduleTimerReset()
	}
}

// MARK: - Transcription
extension AudioManager {
	fileprivate func transcribeAudioBuffer(audioArray: [Float], enableTranslation: Bool) async {
		isTranscribing = true
		transcriptionError = nil

		do {
			let transcription = try await whisperKitTranscriber.transcribeAudioArray(
				audioArray, enableTranslation: enableTranslation)
			await applyAndPaste(transcription)
		} catch {
			await MainActor.run {
				transcriptionError = error.localizedDescription
				lastTranscription = "Transcription failed: \(error.localizedDescription)"
				isTranscribing = false
				MediaPlaybackCoordinator.shared.resumeAfterDictation()
			}
		}
	}
	fileprivate func transcribeAudio(fileURL: URL, enableTranslation: Bool) async {
		isTranscribing = true
		transcriptionError = nil

		do {
			let transcription = try await whisperKitTranscriber.transcribe(
				audioURL: fileURL, enableTranslation: enableTranslation)
			await applyAndPaste(transcription)
		} catch {
			await MainActor.run {
				transcriptionError = error.localizedDescription
				lastTranscription = "Transcription failed: \(error.localizedDescription)"
				isTranscribing = false
				MediaPlaybackCoordinator.shared.resumeAfterDictation()
			}
		}

		try? FileManager.default.removeItem(at: fileURL)
	}

	/// Runs the transcription through the dictation processor (recipe matching +
	/// execution) when in text mode, then pastes the result. WHI-41.
	@MainActor
	fileprivate func applyAndPaste(_ transcription: String) async {
		let mode = currentRecordingMode
		let toPaste: String?
		if mode == .text, let processor = dictationProcessor {
			toPaste = await processor(transcription)
		} else {
			toPaste = transcription
		}

		lastTranscription = transcription
		isTranscribing = false
		if mode == .text, let toPaste {
			pasteToFocusedApp(toPaste)
		}
		// After the paste, so the resume never races the ⌘V we just posted.
		MediaPlaybackCoordinator.shared.resumeAfterDictation()
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
