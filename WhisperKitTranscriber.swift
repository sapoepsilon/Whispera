import AVFoundation
import AppKit
import Combine
import CoreML
import Foundation
import OSLog
import SwiftUI
import WhisperKit

@MainActor
@Observable open class WhisperKitTranscriber: Sendable {
	var isInitialized = false
	private var cancellables = Set<AnyCancellable>()
	var isInitializing = false
	var isWaitingForModel: Bool = false
	var waitingForModelStatusText: String = ""
	var isStreamingAudio: Bool = false
	var initializationProgress: Double = 0.0
	var initializationStatus = String(localized: "Starting...")
	var availableModels: [String] = []
	var currentModel: String?
	var downloadedModels: Set<String> = []
	var onConfirmedTextChange: ((String) -> Void)?
	@ObservationIgnored var onLiveAudioSamples: (@MainActor ([Float]) -> Void)?
	var shouldShowLiveTranscriptionWindow: Bool = false
	var isTranscribing: Bool = false
	var decodingOptions: DecodingOptions?
	var currentText: String = ""
	var dictationWordTracker: DictationWordTracker?
	@ObservationIgnored private var lastLiveSession: (text: String, samples: [Float]) = (text: "", samples: [])
	/// Where the text pipeline reads its settings; tests point it at an isolated suite.
	@ObservationIgnored var textProcessingDefaults: UserDefaults = .standard
	// Live text management
	private var isLiveTranscriptionMode = false
	/// The live session's decode loop: confirmation point, pending tail and settled language.
	@ObservationIgnored private var livePass = LiveDictationPass()
	/// Stopping decodes the words said after the newest pass before committing the session.
	@ObservationIgnored private var liveFinishTask: Task<Bool, Never>?
	@ObservationIgnored private var liveFinish = LiveSessionGate()
	var confirmedText: String = "" {
		didSet {
			onConfirmedTextChange?(confirmedText)
		}
	}
	private var pendingText: String = ""  // Internal working property
	var stableDisplayText: String = ""  // UI-facing stable property
	private var lastDisplayedPendingText: String = ""
	var shouldShowDebugWindow: Bool = false
	var latestWord: String {
		let words = stableDisplayText.split(separator: " ")
		return words.last?.description ?? ""
	}

	func clearLiveTranscriptionState() {
		liveSession.end()
		liveStreamStartupTask?.cancel()
		liveStreamStartupTask = nil
		isWaitingForModel = false
		waitingForModelStatusText = ""
		endLiveFinish()
		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		shouldShowLiveTranscriptionWindow = false
		isTranscribing = false
		confirmedText = ""
		shouldShowDebugWindow = false
		transcriptionTask?.cancel()
		transcriptionTask = nil
		livePass = LiveDictationPass()
	}

	func beginLiveTranscriptionWaitingUI() {
		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		confirmedText = ""
		shouldShowLiveTranscriptionWindow = true
		isWaitingForModel = true
		waitingForModelStatusText = String(localized: "Waiting for model...")
	}

	private func updateWaitingStatusText() {
		guard isWaitingForModel else { return }

		if isDownloadingModel {
			let name = downloadingModelName ?? String(localized: "model")
			let pct = Int((downloadProgress * 100.0).rounded())
			waitingForModelStatusText = String(localized: "Downloading \(name)... \(pct)%")
			return
		}

		if isInitializing {
			waitingForModelStatusText = initializationStatus
			return
		}

		if isModelLoading {
			let modelName = loadingModelName ?? currentModel ?? selectedModel ?? String(localized: "model")
			let pct = Int((loadProgress * 100.0).rounded())
			waitingForModelStatusText = String(localized: "Loading \(modelName)... \(pct)%")
			return
		}

		waitingForModelStatusText = String(localized: "Waiting for model...")
	}

	private func ensureInitializedIfNeeded() async {
		if isInitialized { return }
		if initializationTask == nil {
			startInitialization()
		}
		await initializationTask?.value
	}

	private func chooseDownloadedModelToLoad(downloaded: Set<String>) -> String? {
		if let last = lastUsedModel, downloaded.contains(last) { return last }
		if let selected = selectedModel, downloaded.contains(selected) { return selected }
		let recommended = getRecommendedModels().default
		if downloaded.contains(recommended) { return recommended }
		return downloaded.sorted().first
	}

	private func ensureModelReadyForLiveTranscription(timeoutSeconds: TimeInterval = 30) async throws {
		try Task.checkCancellation()
		await ensureInitializedIfNeeded()
		try Task.checkCancellation()

		let refreshedDownloaded = (try? await getDownloadedModels()) ?? downloadedModels
		downloadedModels = refreshedDownloaded

		try await waitForInFlightLoadIfNoEngine(timeoutSeconds: timeoutSeconds)

		if whisperKit == nil && parakeetEngine == nil {
			guard !refreshedDownloaded.isEmpty else {
				isWaitingForModel = true
				waitingForModelStatusText = String(localized: "No model downloaded. Download one in Settings.")
				throw WhisperKitError.noModelLoaded
			}

			if let modelToLoad = chooseDownloadedModelToLoad(downloaded: refreshedDownloaded) {
				updateWaitingStatusText()
				try await loadModelCoalesced(modelToLoad)
			}
		}

		let start = Date()
		while true {
			try Task.checkCancellation()
			updateWaitingStatusText()

			if isCurrentModelLoaded() {
				return
			}

			if Date().timeIntervalSince(start) > timeoutSeconds {
				throw WhisperKitError.notReady
			}

			try await Task.sleep(nanoseconds: 200_000_000)
		}
	}

	/// With no engine loaded, a load already in flight is the model the user just picked, so
	/// wait for it instead of loading the previously used model next to it. Bounded by the same
	/// readiness timeout as the rest of the wait, so a hung load fails the dictation with a
	/// message instead of holding it until the user cancels.
	private func waitForInFlightLoadIfNoEngine(timeoutSeconds: TimeInterval) async throws {
		let pending = loadingModelName.map(Self.shortModelName(for:))
		try await Self.waitWhileLoading(timeoutSeconds: timeoutSeconds, modelName: pending) { [weak self] in
			guard let self else { return false }
			self.updateWaitingStatusText()
			return self.whisperKit == nil && self.parakeetEngine == nil && self.loadingModelName != nil
		}
	}

	static func waitWhileLoading(
		timeoutSeconds: TimeInterval, pollNanoseconds: UInt64 = 200_000_000, modelName: String?,
		isLoading: @MainActor () -> Bool
	) async throws {
		let start = Date()
		while isLoading() {
			try Task.checkCancellation()
			if Date().timeIntervalSince(start) > timeoutSeconds {
				AppLogger.shared.transcriber.error(
					"Model load still running after \(Int(timeoutSeconds)) s with no engine loaded; failing dictation"
				)
				throw WhisperKitError.modelLoadTimedOut(modelName)
			}
			try await Task.sleep(nanoseconds: pollNanoseconds)
		}
	}

	func waitForReadyForTranscription(timeoutSeconds: TimeInterval = 30) async throws {
		try Task.checkCancellation()
		await ensureInitializedIfNeeded()
		try Task.checkCancellation()

		let refreshedDownloaded = (try? await getDownloadedModels()) ?? downloadedModels
		downloadedModels = refreshedDownloaded

		try await waitForInFlightLoadIfNoEngine(timeoutSeconds: timeoutSeconds)

		if whisperKit == nil && parakeetEngine == nil {
			guard !refreshedDownloaded.isEmpty else {
				throw WhisperKitError.noModelLoaded
			}

			if let modelToLoad = chooseDownloadedModelToLoad(downloaded: refreshedDownloaded) {
				try await loadModelCoalesced(modelToLoad)
			}
		}

		let start = Date()
		while true {
			try Task.checkCancellation()

			if isCurrentModelLoaded() {
				return
			}

			if Date().timeIntervalSince(start) > timeoutSeconds {
				throw WhisperKitError.notReady
			}

			try await Task.sleep(nanoseconds: 200_000_000)
		}
	}

	private func shouldUpdatePendingText(newText: String) -> Bool {
		// If the text is empty or previous text was non-empty, always update (to handle clearing)
		if newText.isEmpty || lastDisplayedPendingText.isEmpty {
			return true
		}

		// Convert to word arrays for comparison
		let newWords = newText.split(separator: " ").map(String.init)
		let oldWords = lastDisplayedPendingText.split(separator: " ").map(String.init)

		// If word count changed significantly, update
		let wordCountDiff = abs(newWords.count - oldWords.count)
		if wordCountDiff > 1 { return true }

		// If the last few words are different, update
		let wordsToCompare = min(3, min(newWords.count, oldWords.count))
		if wordsToCompare > 0 {
			let newLastWords = Array(newWords.suffix(wordsToCompare))
			let oldLastWords = Array(oldWords.suffix(wordsToCompare))

			if newLastWords != oldLastWords {
				return true
			}
		}

		// Similar enough, don't update
		return false
	}

	private func safelyPasteText(_ text: String) {
		guard !text.isEmpty else { return }

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		simulateKeyPressWithModifier(keyCode: 0x09, modifier: .maskCommand)
	}

	private func simulateKeyPressWithModifier(keyCode: CGKeyCode, modifier: CGEventFlags) {
		CGKeyEventPoster().postKey(keyCode, flags: modifier)
	}

	private func confirmPendingText(_ text: String) {
		pendingText = ""
		guard !text.isEmpty else { return }

		// Sync all display properties before confirming to prevent double transcription
		stableDisplayText = text
		lastDisplayedPendingText = text

		// DictationWordTracker types only what extends the text it already typed
		confirmedText = Self.committingLiveTail(text, to: confirmedText)
	}

	private var selectedLanguage: String {
		get {
			UserDefaults.standard.string(forKey: "selectedLanguage") ?? Constants.defaultLanguageName
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "selectedLanguage")
		}
	}

	// MARK: - Persistent Decoding Options
	private var savedTemperature: Float {
		get {
			let value = UserDefaults.standard.float(forKey: "decodingTemperature")
			return value == 0.0 ? 0.0 : value  // 0.0 is our default
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingTemperature")
		}
	}

	private var savedTemperatureFallbackCount: Int {
		get {
			let value = UserDefaults.standard.integer(forKey: "decodingTemperatureFallbackCount")
			return value == 0 ? 1 : value  // Default to 1
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingTemperatureFallbackCount")
		}
	}

	private var savedSampleLength: Int {
		get {
			let value = UserDefaults.standard.integer(forKey: "decodingSampleLength")
			return value == 0 ? getModelSpecificSampleLength() : value
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingSampleLength")
		}
	}

	private var savedUsePrefillPrompt: Bool {
		get {
			UserDefaults.standard.object(forKey: "decodingUsePrefillPrompt") as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingUsePrefillPrompt")
		}
	}

	private var savedUsePrefillCache: Bool {
		get {
			UserDefaults.standard.object(forKey: "decodingUsePrefillCache") as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingUsePrefillCache")
		}
	}

	private var savedSkipSpecialTokens: Bool {
		get {
			UserDefaults.standard.object(forKey: "decodingSkipSpecialTokens") as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingSkipSpecialTokens")
		}
	}

	private var savedWithoutTimestamps: Bool {
		get {
			UserDefaults.standard.object(forKey: "decodingWithoutTimestamps") as? Bool ?? false
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingWithoutTimestamps")
		}
	}

	private var savedWordTimestamps: Bool {
		get {
			UserDefaults.standard.object(forKey: "decodingWordTimestamps") as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingWordTimestamps")
		}
	}

	var lastUsedModel: String? {
		get {
			UserDefaults.standard.string(forKey: "lastUsedModel")
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "lastUsedModel")
		}
	}

	private var enableTranslation: Bool? {
		UserDefaults.standard.bool(forKey: "enableTranslation")
	}

	// WhisperKit model state tracking
	var modelState: String = "unloaded"
	var isModelLoading: Bool = false
	var isModelLoaded: Bool = false
	var selectedModel: String? {
		get {
			UserDefaults.standard.string(forKey: "selectedModel")
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "selectedModel")
		}
	}

	private func modelCacheDirectory(for modelName: String) -> URL? {
		guard
			let appSupport = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
				.first
		else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera/Models/\(modelName)")
	}

	var baseModelCacheDirectory: URL? {
		guard
			let appSupport = FileManager.default.urls(
				for: .applicationSupportDirectory, in: .userDomainMask
			).first
		else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera")
	}

	private func whisperKitModelDirectory(for modelName: String?) -> URL? {
		let name = modelName ?? ""
		return baseModelCacheDirectory?.appendingPathComponent(
			"models/argmaxinc/whisperkit-coreml/\(name)")
	}

	var isDownloadingModel = false {
		didSet {
			// Notify observers when download state changes
			if isDownloadingModel != oldValue {
				NotificationCenter.default.post(
					name: NSNotification.Name("DownloadStateChanged"), object: nil)
			}
		}
	}
	var downloadProgress: Double = 0.0
	var downloadingModelName: String?
	/// True only while bytes are still coming over the network; the load that follows cannot be
	/// interrupted, so Cancel is offered only in this phase.
	private(set) var isModelDownloadCancellable = false
	/// A download only blocks dictation when there is no model to fall back on: the loaded model
	/// (or an idle-unloaded one that reloads on demand) keeps serving until the new one is ready.
	var downloadBlocksDictation: Bool {
		isDownloadingModel && !hasLoadedEngine && !isIdleUnloaded
	}
	var loadProgress: Double = 0.0
	/// The model a load is currently bringing up; the engine already loaded keeps serving until it finishes.
	private(set) var loadingModelName: String?

	@MainActor var whisperKit: WhisperKit?
	@MainActor private(set) var parakeetEngine: ParakeetEngine?
	private var transcriptionTask: Task<Void, Never>?
	@MainActor private var liveStreamStartupTask: Task<Void, Error>?
	@ObservationIgnored private var liveSession = LiveSessionGate()
	private var realtimeDelayInterval: Float = 0.3
	@MainActor private var initializationTask: Task<Void, Never>?
	/// Serializes every model download, load and switch; a running operation also blocks idle unload.
	@ObservationIgnored private let modelOperations = ModelOperationQueue()

	private var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]

	// MARK: - Idle Model Unload State
	@ObservationIgnored private let idleUnloadTimer = DeferredAction()
	@ObservationIgnored private var activeModelUses = 0
	@ObservationIgnored private var liveStreamHoldsModel = false
	@ObservationIgnored private var retiredParakeetEngines = DeferredEngineRelease<ParakeetEngine>()
	@ObservationIgnored private var idleUnloadRetry = IdleUnloadRetryPolicy()
	@ObservationIgnored private var pendingLoadTask: Task<Void, Error>?
	@ObservationIgnored private var lastObservedUnloadTimeout: ModelUnloadTimeout?
	@ObservationIgnored private var settingsObserver: DefaultsKeyObserver?
	@ObservationIgnored private var customWordsObserver: CustomWordPromptObserver?
	private(set) var isIdleUnloaded = false
	/// Model and compute-unit combinations already prewarmed in this process. CoreML keeps the
	/// specialized model cached, so a reload after idle unload can skip the prewarm pass.
	@ObservationIgnored private var prewarmedModelKeys: Set<String> = []

	var hasLoadedEngine: Bool { whisperKit != nil || parakeetEngine != nil }

	// Swift 6 compliant singleton pattern
	static let shared: WhisperKitTranscriber = {
		let instance = WhisperKitTranscriber()
		return instance
	}()

	private init() {
		// Initialize last observed values to prevent unnecessary updates on first launch
		lastObservedLanguage =
			UserDefaults.standard.string(forKey: "selectedLanguage") ?? Constants.defaultLanguageName
		lastObservedTranslation = UserDefaults.standard.bool(forKey: "enableTranslation")

		Task {
			downloadedModels = try await getDownloadedModels()
			AppLogger.shared.transcriber.log("downloaded models: \(self.downloadedModels)")
			// Initialize decoding options for live streaming
			startInitialization()
		}
		// Set up reactive UserDefaults observation
		setupUserDefaultsObservation()
	}

	func startInitialization() {
		guard !isInitialized else { return }
		guard initializationTask == nil else {
			AppLogger.shared.transcriber.log("WhisperKit initialization already in progress...")
			return
		}

		isInitializing = true
		initializationProgress = 0.0
		initializationStatus = String(localized: "Preparing to load Whisper models...")

		initializationTask = Task { @MainActor in
			await initialize()
		}
	}

	func initialize() async {
		guard !isInitialized else {
			AppLogger.shared.transcriber.log("WhisperKit already initialized")
			isInitializing = false
			// A leftover task would block idle unload forever
			initializationTask = nil
			return
		}
		await updateProgress(0.1, String(localized: "Loading WhisperKit framework..."))
		try? await Task.sleep(nanoseconds: 500_000_000)  // Small delay for UI feedback

		AppLogger.shared.transcriber.log("Initializing WhisperKit framework...")
		await updateProgress(0.3, String(localized: "Setting up AI framework..."))

		// Sync our cache with what's actually on disk
		await updateProgress(0.6, String(localized: "Checking for existing models..."))

		// Queued like every other load, so a model the user picks while the app is still starting
		// (onboarding) is not overwritten by this one finishing later
		try? await runModelOperation { transcriber in
			await transcriber.loadModelAtLaunch()
		}

		await updateProgress(1.0, String(localized: "Ready for model selection!"))
		decodingOptions = createDecodingOptions(
			enableTranslation: enableTranslation ?? false
		)

		isInitialized = true
		isInitializing = false
		AppLogger.shared.transcriber.log("WhisperKit framework initialized - ready for transcription")
		initializationTask = nil
		scheduleIdleUnload()
	}

	private func loadModelAtLaunch() async {
		guard !hasLoadedEngine else {
			AppLogger.shared.transcriber.log("A model was loaded before launch loading ran; keeping it")
			return
		}
		if let last = lastUsedModel, downloadedModels.contains(last),
			!Self.isStandardWhisperKitModel(last)
		{
			await updateProgress(0.9, String(localized: "Loading last used model..."))
			do {
				try await autoLoadLastModel()
			} catch {
				AppLogger.shared.transcriber.log("Failed to load last used model \(last): \(error)")
			}
		} else if !downloadedModels.isEmpty {
			await updateProgress(0.8, String(localized: "Loading existing model..."))
			do {
				whisperKit = try await Task { @MainActor in
					let config = WhisperKitConfig(
						downloadBase: baseModelCacheDirectory,
						computeOptions: getOptimizedComputeOptions(),
						prewarm: true
					)
					let whisperKitInstance = try await Self.makeWhisperKit(config)
					self.setupModelStateCallback(for: whisperKitInstance)
					return whisperKitInstance
				}.value
				AppLogger.shared.transcriber.log("WhisperKit initialized with existing models")
				await updateProgress(0.9, String(localized: "Loading last used model..."))
				try await autoLoadLastModel()

			} catch {
				AppLogger.shared.transcriber.log("Failed to initialize with existing models: \(error)")
				AppLogger.shared.transcriber.log(
					"Will initialize WhisperKit when first model is downloaded")
			}
		} else {
			AppLogger.shared.transcriber.log(
				"No models downloaded yet - WhisperKit will be initialized with first model download")
		}
	}

	func autoLoadLastModel() async throws {
		guard let lastModel = lastUsedModel else {
			AppLogger.shared.transcriber.log("No last used model found, will use default when needed")
			return
		}

		guard downloadedModels.contains(lastModel) else {
			AppLogger.shared.transcriber.log(
				"Last used model '\(lastModel)' is no longer available, clearing preference")
			lastUsedModel = nil
			return
		}

		do {
			AppLogger.shared.transcriber.log("Auto-loading last used model: \(lastModel)")
			try await loadModelInOperation(lastModel)
			AppLogger.shared.transcriber.log("Successfully auto-loaded last used model: \(lastModel)")
			// The model list is a network fetch with a 10 s timeout. Awaited here it held the
			// launch model operation and isInitialized, which every dictation waits for before
			// opening the microphone, although nothing it returns is needed to transcribe.
			refreshModelCatalogInBackground()
		} catch {
			AppLogger.shared.transcriber.log(
				"Failed to auto-load last used model '\(lastModel)': \(error)")
			AppLogger.shared.transcriber.log("Clearing invalid model preference")
			lastUsedModel = nil
			throw error
		}
	}
	private func updateProgress(_ progress: Double, _ status: String) async {
		await MainActor.run {
			self.initializationProgress = progress
			self.initializationStatus = status
		}
	}
	func checkIfWhisperKitIsAvailable() throws {
		guard isInitialized else {
			throw WhisperKitError.notInitialized
		}
		guard let whisperKit = whisperKit else {
			throw WhisperKitError.notInitialized
		}
		guard whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed else {
			throw WhisperKitError.notReady
		}
		guard isWhisperKitReady() else {
			throw WhisperKitError.notReady
		}
		AppLogger.shared.transcriber.info("WhisperKit is ready")
	}
	func liveStream() async throws {
		// The previous session's final decode still types into the app and holds the model
		_ = await liveFinishTask?.value
		AppLogger.shared.transcriber.info("Starting live stream...")
		beginLiveTranscriptionWaitingUI()
		if !liveStreamHoldsModel {
			liveStreamHoldsModel = true
			beginModelUse()
		}

		liveStreamStartupTask?.cancel()
		let generation = liveSession.begin()
		let startup = Task { @MainActor in
			do {
				try await ensureModelReadyForLiveTranscription()
				try checkLiveStartupIsCurrent(generation)
				if parakeetEngine != nil {
					waitingForModelStatusText = String(
						localized: "Live Transcription Mode needs a Whisper model.")
					throw WhisperKitError.liveModeUnsupported
				}
				isWaitingForModel = false
				waitingForModelStatusText = ""

				guard let whisperKit = whisperKit, isWhisperKitReady() else {
					throw WhisperKitError.notReady
				}
				try await LiveStartupSequence.run(
					openMicrophone: {
						dictationWordTracker = DictationWordTracker()
						dictationWordTracker?.startNewSession()

						shouldShowLiveTranscriptionWindow = true
						isTranscribing = true
						isLiveTranscriptionMode = true
						livePass = LiveDictationPass()

						await AudioDeviceManager.shared.activateSelectedDevice()
						guard liveSession.isCurrent(generation), !Task.isCancelled else {
							// Stop already restored the input before this activation finished
							if !liveSession.isActive {
								AudioDeviceManager.shared.restoreSystemDefault()
							}
							throw CancellationError()
						}
						let selectedDeviceID = AudioDeviceManager.shared.resolveActiveDeviceID()
						try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: selectedDeviceID) {
							[weak self] samples in
							Task { @MainActor in
								guard let self, self.liveSession.isCurrent(generation) else { return }
								self.shouldShowLiveTranscriptionWindow = true
								self.onLiveAudioSamples?(samples)
							}
						}
					},
					preparePrompt: {
						// The live loop reuses these options for every pass
						await loadTokenizerForCustomWords()
						refreshDecodingOptions()
					},
					isCurrent: { liveSession.isCurrent(generation) && !Task.isCancelled },
					startDecoding: { realtimeLoop(generation: generation) })
			} catch {
				guard liveSession.isCurrent(generation), !Task.isCancelled, !(error is CancellationError) else {
					throw CancellationError()
				}
				failLiveStartup(error)
				throw error
			}
		}
		liveStreamStartupTask = startup
		defer {
			// A stopped session's continuation must not clear the handle of the session after it
			if liveStreamStartupTask == startup {
				liveStreamStartupTask = nil
			}
		}
		try await startup.value
	}

	private func checkLiveStartupIsCurrent(_ generation: Int) throws {
		guard liveSession.isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
	}

	/// Undoes a live startup that failed on its own, so the caller can reset the recording.
	/// The waiting text stays up to tell the user why dictation did not start.
	private func failLiveStartup(_ error: Error) {
		liveSession.end()
		transcriptionTask?.cancel()
		transcriptionTask = nil
		whisperKit?.audioProcessor.stopRecording()
		AudioDeviceManager.shared.restoreSystemDefault()
		isWaitingForModel = false
		isTranscribing = false
		isLiveTranscriptionMode = false
		dictationWordTracker?.endSession()
		if waitingForModelStatusText.isEmpty {
			waitingForModelStatusText = String(localized: "Unable to start dictation.")
		}
		shouldShowLiveTranscriptionWindow = true
		releaseLiveStreamModelUse()
		AppLogger.shared.transcriber.error("Failed to start live stream: \(error)")
	}
	func switchLiveStreamDevice() async {
		guard isLiveTranscriptionMode, let whisperKit else { return }
		let generation = liveSession.generation

		await AudioDeviceManager.shared.activateSelectedDevice()
		// The session may have stopped while the device switched; resuming would reopen the mic
		guard liveSession.isCurrent(generation) else { return }
		let newDeviceID = AudioDeviceManager.shared.resolveActiveDeviceID()
		whisperKit.audioProcessor.pauseRecording()

		do {
			try whisperKit.audioProcessor.resumeRecordingLive(inputDeviceID: newDeviceID) { [weak self] samples in
				Task { @MainActor in
					guard let self, self.liveSession.isCurrent(generation) else { return }
					self.onLiveAudioSamples?(samples)
				}
			}
			let deviceName = newDeviceID.flatMap { id -> String? in
				AudioDeviceManager.shared.availableDevices.first(where: { $0.id == id })?.name
			} ?? "System Default"
			AppLogger.shared.transcriber.info("Switched live stream device to: \(deviceName)")
		} catch {
			AppLogger.shared.transcriber.error("Failed to switch live stream device: \(error)")
		}
	}

	/// How long stopping waits for the final decode before typing the newest pass's pending tail.
	nonisolated static let liveFinalDecodeTimeLimit: Duration = .seconds(8)

	/// Stops the microphone at once, then decodes the words said after the newest pass and types
	/// them. The task's value is false when a cancel or reset threw the session away first.
	@discardableResult
	func stopLiveStream() -> Task<Bool, Never> {
		let wasLive = isLiveTranscriptionMode
		// A second stop while the first one's final decode runs must not throw that decode away
		if !wasLive, liveFinish.isActive, let liveFinishTask {
			return liveFinishTask
		}
		// The buffer is final once the microphone stops, and the final decode reads it
		whisperKit?.audioProcessor.stopRecording()
		// A long session is tens of MB of samples, so they are copied only when history keeps them.
		let keepsAudio = wasLive && HistorySettings(defaults: .standard).keepsAudio
		let sessionSamples = keepsAudio ? Array(whisperKit?.audioProcessor.audioSamples ?? []) : []

		liveSession.end()
		let startup = liveStreamStartupTask
		liveStreamStartupTask?.cancel()
		liveStreamStartupTask = nil
		isWaitingForModel = false
		waitingForModelStatusText = ""
		isTranscribing = false
		shouldShowLiveTranscriptionWindow = false
		isLiveTranscriptionMode = false
		AudioDeviceManager.shared.restoreSystemDefault()
		// The pass in flight is cancelled: its result would be stale, and the final decode covers its audio
		let inFlight = transcriptionTask
		inFlight?.cancel()
		transcriptionTask = nil

		let generation = liveFinish.begin()
		let pass = livePass
		let finishing = Task { @MainActor [weak self] () -> Bool in
			await inFlight?.value
			// Stopped while startup still prepared the prompt: the microphone was already
			// capturing, and the final decode needs the loaded model and the prompt
			if wasLive { _ = await startup?.result }
			guard let self else { return false }
			let settings = wasLive ? self.liveSettings() : nil
			var tail = pass.pendingTail
			if let settings, let whisperKit = self.whisperKit {
				tail = await pass.finish(
					audio: WhisperKitLiveAudio(processor: whisperKit.audioProcessor), settings: settings,
					decode: self.liveDecoder(), timeLimit: Self.liveFinalDecodeTimeLimit,
					isCurrent: { [weak self] in self?.liveFinish.isCurrent(generation) ?? false })
			}
			guard self.liveFinish.isCurrent(generation) else { return false }
			self.liveFinish.end()
			self.commitLiveSession(
				tail: wasLive ? self.processLiveText(tail, language: pass.language) : "", wasLive: wasLive,
				samples: sessionSamples)
			return true
		}
		liveFinishTask = finishing
		return finishing
	}

	private func commitLiveSession(tail: String, wasLive: Bool, samples: [Float]) {
		let fallbackSessionText = Self.liveSessionText(confirmed: confirmedText, pending: tail)
		confirmPendingText(tail)
		if wasLive {
			// What the tracker typed is exactly what reached the focused app
			let typedText = dictationWordTracker?.typedText ?? ""
			lastLiveSession = (text: typedText.isEmpty ? fallbackSessionText : typedText, samples: samples)
			if !typedText.isEmpty {
				TextInserter.shared.submitAfterLiveSession()
			}
		}
		dictationWordTracker?.endSession()
		releaseLiveStreamModelUse()
		AppLogger.shared.transcriber.info("Live streaming stopped")
	}

	/// Throws away a final decode that has not committed yet, with the model hold it kept.
	private func endLiveFinish() {
		guard liveFinish.isActive else { return }
		liveFinish.end()
		liveFinishTask?.cancel()
		liveFinishTask = nil
		dictationWordTracker?.endSession()
		releaseLiveStreamModelUse()
	}

	/// Hands the finished live session to history once, then forgets it so the audio is freed.
	func takeLastLiveSession() -> (text: String, samples: [Float]) {
		defer { lastLiveSession = (text: "", samples: []) }
		return lastLiveSession
	}

	/// confirmedText holds the segments already confirmed and pendingText the trailing
	/// unconfirmed ones, so the whole session is the two joined.
	nonisolated static func liveSessionText(confirmed: String, pending: String) -> String {
		[confirmed, pending]
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty && $0 != liveWaitingPlaceholder }
			.joined(separator: " ")
	}

	nonisolated static let liveWaitingPlaceholder = "Waiting for speech..."

	/// Segments held back as pending because Whisper may still revise them.
	nonisolated static let liveSegmentsHeldBack = 2
	/// The options for one live pass over a window that starts at the confirmation point, so
	/// confirmed sentences are never re-segmented; confirmation needs segment timestamps. The
	/// custom-word prompt is left out while the window holds no speech, because Whisper echoes it
	/// on silence.
	nonisolated static func liveDecodingOptions(_ base: DecodingOptions, windowHasSpeech: Bool) -> DecodingOptions {
		var options = base
		options.clipTimestamps = [0]
		options.withoutTimestamps = false
		if !windowHasSpeech {
			options.promptTokens = nil
		}
		return promptSafeDecodingOptions(options)
	}

	/// A live pass's segments as the confirmer takes them. Their times are relative to `audio`,
	/// the window the pass decoded.
	nonisolated static func liveSegments(
		_ segments: [LiveSegment], promptWords: [String], audio: [Float], sensitivity: VADSensitivity
	) -> [LiveSegment] {
		withoutPromptEchoes(
			segments.map { LiveSegment(text: withoutStrayQuotes($0.text), start: $0.start, end: $0.end) },
			promptWords: promptWords, audio: audio, sensitivity: sensitivity)
	}

	private nonisolated static let quoteMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

	/// Whisper wraps a sentence it decodes on its own, from a live clip point, in quote marks: one
	/// came back fully quoted, another opened and never closed. Only quotes wrapping the whole
	/// segment are removed, so a quotation inside a sentence stays.
	nonisolated static func withoutStrayQuotes(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let quoteCount = trimmed.filter { quoteMarks.contains($0) }.count
		guard quoteCount > 0, quoteCount <= 2, let first = trimmed.first, let last = trimmed.last else { return text }
		let opens = quoteMarks.contains(first)
		let closes = quoteMarks.contains(last) && trimmed.count > 1
		var result = Substring(trimmed)
		switch (quoteCount, opens, closes) {
		case (1, true, _): result = result.dropFirst()
		case (1, false, true): result = result.dropLast()
		case (2, true, true): result = result.dropFirst().dropLast()
		default: return text
		}
		return result.trimmingCharacters(in: .whitespaces)
	}

	/// The live preview shows what will be typed, and bracketed non-speech markers such as
	/// [BLANK_AUDIO] are never typed.
	nonisolated static func livePreviewText(_ pendingText: String) -> String {
		TranscriptTextProcessor.removeNonSpeechMarkers(pendingText)
	}

	/// Drops the segments that only echo the custom-word prompt over their own silent audio.
	nonisolated static func withoutPromptEchoes(
		_ segments: [LiveSegment], promptWords: [String], audio: [Float], sensitivity: VADSensitivity
	) -> [LiveSegment] {
		guard !promptWords.isEmpty else { return segments }
		return segments.filter { segment in
			!PromptEchoFilter.isEcho(
				segment.text, customWords: promptWords, audio: samples(of: segment, in: audio), sensitivity: sensitivity)
		}
	}

	/// The samples between a segment's timestamps, empty when they fall outside the audio.
	nonisolated static func samples(of segment: LiveSegment, in audio: [Float]) -> ArraySlice<Float> {
		let rate = Float(WhisperKit.sampleRate)
		let start = min(audio.count, max(0, Int(segment.start * rate)))
		let end = min(audio.count, max(start, Int(segment.end * rate)))
		return audio[start..<end]
	}

	/// What stopping a live session leaves in confirmedText: the processed held-back tail
	/// appended to what was already typed. The decoder's progress text (a partial decode of the
	/// whole window) is never committed, or the tracker would retype or truncate the session.
	nonisolated static func committingLiveTail(_ processedTail: String, to confirmed: String) -> String {
		processedTail.isEmpty ? confirmed : appendingConfirmed(processedTail, to: confirmed)
	}

	nonisolated static func appendingConfirmed(_ addition: String, to confirmed: String) -> String {
		confirmed.isEmpty ? addition : confirmed + " " + addition
	}

	/// Runs the text pipeline over live text, dropping the waiting placeholder.
	func processLiveText(_ text: String, language: String?) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != Self.liveWaitingPlaceholder else { return "" }
		return processTranscriptText(
			trimmed, detectedLanguage: language,
			enableTranslation: decodingOptions?.task == .translate)
	}


	/// Stops live dictation without committing the pending (unconfirmed) text.
	/// Text already confirmed and typed into the focused app stays where it is.
	func cancelLiveStream() {
		endLiveFinish()
		liveSession.end()
		liveStreamStartupTask?.cancel()
		liveStreamStartupTask = nil
		transcriptionTask?.cancel()
		transcriptionTask = nil
		isWaitingForModel = false
		waitingForModelStatusText = ""
		isTranscribing = false
		shouldShowLiveTranscriptionWindow = false
		whisperKit?.audioProcessor.stopRecording()
		AudioDeviceManager.shared.restoreSystemDefault()

		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		lastLiveSession = (text: "", samples: [])
		isLiveTranscriptionMode = false
		dictationWordTracker?.endSession()
		releaseLiveStreamModelUse()
		AppLogger.shared.transcriber.info("Live streaming cancelled")
	}

	private func releaseLiveStreamModelUse() {
		guard liveStreamHoldsModel else { return }
		liveStreamHoldsModel = false
		endModelUse()
	}
	private func realtimeLoop(generation: Int) {
		transcriptionTask = Task {
			while isTranscribing, liveSession.isCurrent(generation), !Task.isCancelled {
				do {
					try await transcribeCurrentBuffer(generation: generation)
				} catch {
					if liveSession.isCurrent(generation) {
						AppLogger.shared.liveTranscriber.error(
							"Transcription error: \(error.localizedDescription)"
						)
					}
					break
				}
			}
		}
	}

	/// The settings every live pass reads, fresh each pass so Settings changes apply mid-session.
	private func liveSettings() -> LivePassSettings? {
		guard let base = decodingOptions else { return nil }
		return LivePassSettings(
			base: base, voiceActivity: VoiceActivitySettings(defaults: .standard),
			promptWords: TextProcessingSettings.customWords(from: .standard),
			minimumNewAudioSeconds: realtimeDelayInterval)
	}

	private func liveDecoder() -> LiveDecoder {
		{ [weak self] samples, options in
			guard let self else { return nil }
			guard let result = try await self.transcribeAudioSamples(samples, options: options) else { return nil }
			return LiveDecodeOutput(
				segments: result.segments.map { LiveSegment(text: $0.text, start: $0.start, end: $0.end) },
				language: result.language)
		}
	}

	private func transcribeCurrentBuffer(generation: Int) async throws {
		guard let whisperKit = whisperKit, liveSession.isCurrent(generation) else { return }
		guard let settings = liveSettings() else {
			AppLogger.shared.transcriber.log("Decoding options not initialized, skipping live pass")
			try await Task.sleep(nanoseconds: 100_000_000)
			return
		}
		let pass = livePass
		let step = try await pass.step(
			audio: WhisperKitLiveAudio(processor: whisperKit.audioProcessor), settings: settings,
			decode: liveDecoder(), process: { [weak self] in self?.processLiveText($0, language: pass.language) ?? "" },
			isCurrent: { [weak self] in self?.liveSession.isCurrent(generation) ?? false })

		switch step {
		case .waitingForAudio, .silence:
			if liveSession.isCurrent(generation), pendingText.isEmpty && confirmedText.isEmpty {
				pendingText = Self.liveWaitingPlaceholder
				shouldShowLiveTranscriptionWindow = true
			}
			try await Task.sleep(nanoseconds: 100_000_000)
		case .stale, .noSegments:
			return
		case .decoded(let confirmation):
			// A pass that outlived its session must not confirm, and so type, its text into the next one
			guard liveSession.isCurrent(generation) else { return }
			if confirmation.confirmedSegmentCount > 0 {
				AppLogger.shared.transcriber.debug(
					"Confirmed \(confirmation.confirmedSegmentCount) segment(s) through \(pass.confirmer.confirmedThroughSeconds)s, text: '\(confirmation.confirmedAddition)'"
				)
			}
			if !confirmation.confirmedAddition.isEmpty {
				confirmedText = Self.appendingConfirmed(confirmation.confirmedAddition, to: confirmedText)
			}

			pendingText = confirmation.pendingText

			// Only update UI-facing property if text has changed meaningfully
			let preview = Self.livePreviewText(confirmation.pendingText)
			if shouldUpdatePendingText(newText: preview) {
				stableDisplayText = preview
				lastDisplayedPendingText = preview
			}

			shouldShowLiveTranscriptionWindow = !stableDisplayText.isEmpty || !confirmedText.isEmpty
		}
	}

	private func transcribeAudioSamples(_ samples: [Float], options: DecodingOptions) async throws -> TranscriptionResult? {
		guard let whisperKit = whisperKit else { return nil }

		do {
			return try await whisperKit.transcribe(audioArray: samples, decodeOptions: options).first
		} catch {
			let errorString = error.localizedDescription
			if errorString.contains("Could not store NSNumber at offset")
				|| errorString.contains("beyond the end of the multi array")
			{
				AppLogger.shared.transcriber.log(
					"Array bounds error detected, retrying with smaller sampleLength")

				// Retry with a smaller sampleLength, keeping the live pass's window and prompt
				var fallbackOptions = options
				fallbackOptions.sampleLength = 224
				return try await whisperKit.transcribe(audioArray: samples, decodeOptions: fallbackOptions).first
			} else {
				throw error
			}
		}
	}

	// MARK: - Decoding Options Management
	private func createDefaultDecodingOptions() -> DecodingOptions {
		let languageParameters = Self.languageDecodingParameters(
			selectedLanguage: selectedLanguage, enableTranslation: false)
		return Self.promptSafeDecodingOptions(DecodingOptions(
			verbose: false,
			task: .transcribe,
			language: languageParameters.language,
			temperature: savedTemperature,
			temperatureFallbackCount: savedTemperatureFallbackCount,
			sampleLength: savedSampleLength,
			usePrefillPrompt: savedUsePrefillPrompt,
			usePrefillCache: savedUsePrefillCache,
			detectLanguage: languageParameters.detectLanguage,
			skipSpecialTokens: savedSkipSpecialTokens,
			withoutTimestamps: savedWithoutTimestamps,
			wordTimestamps: savedWordTimestamps,
			clipTimestamps: [0],
			promptTokens: customWordPromptTokens()
		))
	}

	func createDecodingOptions(enableTranslation: Bool) -> DecodingOptions {
		let task: DecodingTask = enableTranslation ? .translate : .transcribe
		let languageParameters = Self.languageDecodingParameters(
			selectedLanguage: selectedLanguage, enableTranslation: enableTranslation)
		let languageCode = languageParameters.language
		let promptTokens = customWordPromptTokens()

		AppLogger.shared.transcriber.log(
			"Creating decoding options - mode: \(task.description) language: \(languageCode ?? "auto") promptTokens: \(promptTokens?.count ?? 0)"
		)
		return Self.promptSafeDecodingOptions(DecodingOptions(
			verbose: false,
			task: task,
			language: languageCode,
			temperature: savedTemperature,
			temperatureFallbackCount: savedTemperatureFallbackCount,
			sampleLength: savedSampleLength,
			usePrefillPrompt: savedUsePrefillPrompt,
			usePrefillCache: savedUsePrefillCache,
			detectLanguage: languageParameters.detectLanguage,
			skipSpecialTokens: savedSkipSpecialTokens,
			withoutTimestamps: savedWithoutTimestamps,
			wordTimestamps: savedWordTimestamps,
			clipTimestamps: [0],
			promptTokens: promptTokens
		))
	}

	/// "auto" leaves the language unset so WhisperKit detects it from the audio.
	nonisolated static func languageDecodingParameters(selectedLanguage: String, enableTranslation: Bool)
		-> (language: String?, detectLanguage: Bool)
	{
		let language = Constants.decodingLanguageCode(for: selectedLanguage)
		return (language, enableTranslation || language == nil)
	}

	func refreshDecodingOptions() {
		decodingOptions = createDecodingOptions(enableTranslation: enableTranslation ?? false)
	}

	/// A prewarmed model only loads its weights and tokenizer inside the first transcribe call,
	/// after the options were built, so without this the first dictation after every model load
	/// (and every live session) went out without the custom-word prompt. transcribe() would do
	/// the same load a moment later, so nothing extra is loaded.
	func loadTokenizerForCustomWords() async {
		guard let whisperKit, whisperKit.tokenizer == nil,
			CustomWordPromptObserver.effectivePrompt(in: .standard) != nil
		else { return }
		do {
			if whisperKit.modelState == .loaded {
				try await whisperKit.loadTokenizerIfNeeded()
			} else {
				try await whisperKit.loadModels()
			}
		} catch {
			AppLogger.shared.transcriber.error("Could not load the tokenizer for custom words: \(error)")
		}
	}

	private func customWordPromptTokens() -> [Int]? {
		Self.promptTokens(
			for: CustomWordPromptObserver.effectivePrompt(in: .standard), tokenizer: whisperKit?.tokenizer)
	}

	/// Nil without a tokenizer: options built before a model loads carry no prompt, so every
	/// load refreshes them.
	nonisolated static func promptTokens(for prompt: String?, tokenizer: (any WhisperTokenizer)?) -> [Int]? {
		guard let prompt, let tokenizer else { return nil }
		let tokens = tokenizer.encode(text: prompt).filter {
			$0 < tokenizer.specialTokens.specialTokenBegin
		}
		return tokens.isEmpty ? nil : tokens
	}

	func processTranscriptText(
		_ text: String, detectedLanguage: String?, enableTranslation: Bool, preservingLineBreaks: Bool = false,
		engineHonorsLanguage: Bool = true
	) -> String {
		guard !text.isEmpty else { return text }
		var configuration = TextProcessingSettings.configuration(from: textProcessingDefaults)
		configuration.preservesLineBreaks = preservingLineBreaks
		let evidence = TranscriptTextProcessor.languageEvidence(
			selectedLanguageCode: Self.pipelineLanguageCode(
				selectedLanguage: selectedLanguage, engineHonorsLanguage: engineHonorsLanguage),
			translating: enableTranslation,
			modelDetectedLanguage: detectedLanguage,
			text: text
		)
		let processed = TranscriptTextProcessor(configuration: configuration).process(text, language: evidence)
		if processed != text {
			AppLogger.shared.transcriber.log(
				"Text processing changed transcript (language evidence: \(evidence))")
		}
		return processed
	}

	/// Parakeet ignores the Source Language picker, so the picker says nothing about what was
	/// spoken; passing it on would strip English fillers such as "um" from Portuguese speech.
	/// Mirrors `CLITextPipeline`.
	static func pipelineLanguageCode(selectedLanguage: String, engineHonorsLanguage: Bool) -> String? {
		engineHonorsLanguage ? Constants.decodingLanguageCode(for: selectedLanguage) : nil
	}

	func updateDecodingOptions(
		temperature: Float? = nil,
		temperatureFallbackCount: Int? = nil,
		sampleLength: Int? = nil,
		usePrefillPrompt: Bool? = nil,
		usePrefillCache: Bool? = nil,
		skipSpecialTokens: Bool? = nil,
		withoutTimestamps: Bool? = nil,
		wordTimestamps: Bool? = nil
	) {
		if let temperature = temperature {
			savedTemperature = temperature
		}
		if let temperatureFallbackCount = temperatureFallbackCount {
			savedTemperatureFallbackCount = temperatureFallbackCount
		}
		if let sampleLength = sampleLength {
			savedSampleLength = sampleLength
		}
		if let usePrefillPrompt = usePrefillPrompt {
			savedUsePrefillPrompt = usePrefillPrompt
		}
		if let usePrefillCache = usePrefillCache {
			savedUsePrefillCache = usePrefillCache
		}
		if let skipSpecialTokens = skipSpecialTokens {
			savedSkipSpecialTokens = skipSpecialTokens
		}
		if let withoutTimestamps = withoutTimestamps {
			savedWithoutTimestamps = withoutTimestamps
		}
		if let wordTimestamps = wordTimestamps {
			savedWordTimestamps = wordTimestamps
		}

		AppLogger.shared.transcriber.log(
			"Updated decoding options - temperature: \(self.savedTemperature), sampleLength: \(self.savedSampleLength)"
		)

		// Recreate decoding options with updated values
		if let currentOptions = decodingOptions {
			decodingOptions = createDecodingOptions(enableTranslation: currentOptions.task == .translate)
		}
	}

	func getCurrentDecodingOptions(enableTranslation: Bool) -> DecodingOptions {
		return createDecodingOptions(enableTranslation: enableTranslation)
	}

	/// The options every one-shot transcription sends (dictation, files, the queue, YouTube,
	/// history re-transcription). A prewarmed model loads its tokenizer only inside transcribe,
	/// after the options were built, so options built without this left the first transcription
	/// after a launch or a model switch without the custom-word prompt.
	func promptReadyDecodingOptions(enableTranslation: Bool) async -> DecodingOptions {
		await loadTokenizerForCustomWords()
		return createDecodingOptions(enableTranslation: enableTranslation)
	}

	// MARK: - Dynamic Settings Management
	func reloadCurrentModelIfNeeded() async throws {
		guard let currentModel = currentModel else {
			AppLogger.shared.transcriber.log("No current model to reload")
			return
		}
		AppLogger.shared.transcriber.log("Reloading current model: \(currentModel)")
		try await runModelOperation { transcriber in
			try await transcriber.loadModelInOperation(currentModel)
		}
	}

	func updateLanguageSettings(_ newLanguage: String) {
		let oldLanguage = selectedLanguage
		selectedLanguage = newLanguage
		AppLogger.shared.transcriber.log("Updated language: \(oldLanguage) -> \(newLanguage)")
		// Update decoding options with new language
		updateDecodingOptionsForTranslation(
			enableTranslation: enableTranslation ?? false
		)
	}

	func updateDecodingOptionsForTranslation(enableTranslation: Bool) {
		decodingOptions = createDecodingOptions(enableTranslation: enableTranslation)
		AppLogger.shared.transcriber.log(
			"Updated decoding options for translation mode: \(enableTranslation ? "enabled" : "disabled")"
		)
	}

	func updateTranscriptionQuality(
		temperature: Float? = nil,
		sampleLength: Int? = nil,
		usePrefillPrompt: Bool? = nil,
		usePrefillCache: Bool? = nil
	) {
		updateDecodingOptions(
			temperature: temperature,
			sampleLength: sampleLength,
			usePrefillPrompt: usePrefillPrompt,
			usePrefillCache: usePrefillCache
		)
		AppLogger.shared.transcriber.log("Updated transcription quality settings")
	}

	func updateAdvancedSettings(
		skipSpecialTokens: Bool? = nil,
		withoutTimestamps: Bool? = nil,
		wordTimestamps: Bool? = nil
	) {
		updateDecodingOptions(
			skipSpecialTokens: skipSpecialTokens,
			withoutTimestamps: withoutTimestamps,
			wordTimestamps: wordTimestamps
		)
		AppLogger.shared.transcriber.log("Updated advanced transcription settings")
	}

	private func getModelSpecificSampleLength() -> Int {
		// Always use 224 as the safe default to prevent KV cache overflow crashes
		// Larger values can cause NSInvalidArgumentException in CoreML
		return 224
	}

	func resetDecodingOptionsToDefaults() {
		savedTemperature = 0.0
		savedTemperatureFallbackCount = 1
		savedSampleLength = getModelSpecificSampleLength()
		savedUsePrefillPrompt = true
		savedUsePrefillCache = true
		savedSkipSpecialTokens = true
		savedWithoutTimestamps = false
		savedWordTimestamps = true
		AppLogger.shared.transcriber.log("Reset all decoding options to defaults")
	}

	private enum TranscriptionInput {
		case audioPath(String)
		case audioArray([Float])
	}

	private func performTranscription(
		input: TranscriptionInput, enableTranslation: Bool, logPrefix: String
	) async throws -> String {
		beginModelUse()
		defer { endModelUse() }
		try await waitForReadyForTranscription()
		guard isWhisperKitReady() else { throw WhisperKitError.notReady }
		if let notice = modelSwitchNotice, let activeModel = notice.activeModel {
			AppLogger.shared.transcriber.info(
				"Transcribing with \(activeModel) while \(notice.pendingModel) is still \(notice.phase == .loading ? "loading" : "downloading")"
			)
		}
		if let engine = parakeetEngine {
			return try await transcribe(
				with: engine, input: input, enableTranslation: enableTranslation, logPrefix: logPrefix)
		}
		let maxRetries = 3
		var lastError: Error?
		decodingOptions = await promptReadyDecodingOptions(enableTranslation: enableTranslation)

		for attempt in 1...maxRetries {
			do {
				let result = try await Task { @MainActor in
					guard let whisperKitInstance = self.whisperKit else {
						throw WhisperKitError.notInitialized
					}
					if whisperKitInstance.modelState != .loaded {
						AppLogger.shared.transcriber.log(
							"Model isn't loaded yet. \(whisperKitInstance.modelState)")
					}

					switch input {
					case .audioPath(let path):
						return try await whisperKitInstance.transcribe(
							audioPath: path, decodeOptions: decodingOptions)
					case .audioArray(let array):
						return try await whisperKitInstance.transcribe(
							audioArray: array, decodeOptions: decodingOptions)
					}
				}.value

				if !result.isEmpty {
					let rawTranscription = result.compactMap { $0.text }.joined(separator: " ")
						.trimmingCharacters(in: .whitespacesAndNewlines)
					let transcription = processTranscriptText(
						rawTranscription, detectedLanguage: result.first?.language,
						enableTranslation: enableTranslation)

					if !transcription.isEmpty {
						AppLogger.shared.transcriber.userText(
							"WhisperKit \(logPrefix) transcription completed", transcription)
						return transcription
					} else {
						AppLogger.shared.transcriber.log("Transcription returned empty text")
						return ""
					}
				} else {
					AppLogger.shared.transcriber.log("No transcription segments returned")
					return ""
				}

			} catch {
				lastError = error
				let errorString = error.localizedDescription

				if errorString.contains("Could not store NSNumber at offset")
					|| errorString.contains("beyond the end of the multi array")
				{
					AppLogger.shared.transcriber.log(
						"Array bounds error detected, retrying with smaller sampleLength")

					let fallbackOptions = Self.promptSafeDecodingOptions(DecodingOptions(
						verbose: false,
						task: decodingOptions?.task ?? .transcribe,
						language: decodingOptions?.language,
						temperature: savedTemperature,
						temperatureFallbackCount: savedTemperatureFallbackCount,
						sampleLength: 224,
						usePrefillPrompt: savedUsePrefillPrompt,
						usePrefillCache: savedUsePrefillCache,
						detectLanguage: decodingOptions?.detectLanguage,
						skipSpecialTokens: savedSkipSpecialTokens,
						withoutTimestamps: savedWithoutTimestamps,
						wordTimestamps: savedWordTimestamps,
						clipTimestamps: [0],
						promptTokens: decodingOptions?.promptTokens
					))

					do {
						let fallbackResult = try await Task { @MainActor in
							guard let whisperKitInstance = self.whisperKit else {
								throw WhisperKitError.notInitialized
							}
							switch input {
							case .audioPath(let path):
								return try await whisperKitInstance.transcribe(
									audioPath: path, decodeOptions: fallbackOptions)
							case .audioArray(let array):
								return try await whisperKitInstance.transcribe(
									audioArray: array, decodeOptions: fallbackOptions)
							}
						}.value

						if !fallbackResult.isEmpty {
							let rawTranscription = fallbackResult.compactMap { $0.text }
								.joined(separator: " ")
								.trimmingCharacters(in: .whitespacesAndNewlines)
							let transcription = processTranscriptText(
								rawTranscription, detectedLanguage: fallbackResult.first?.language,
								enableTranslation: enableTranslation)
							if !transcription.isEmpty {
								AppLogger.shared.transcriber.userText(
									"WhisperKit \(logPrefix) transcription completed with fallback", transcription)
								return transcription
							}
						}
						return ""
					} catch {
						AppLogger.shared.transcriber.log(
							"Fallback transcription also failed: \(error)")
						throw WhisperKitError.transcriptionFailed(error.localizedDescription)
					}
				} else if errorString.contains("Failed to open resource file")
					|| errorString.contains("MPSGraphComputePackage") || errorString.contains("Metal")
				{
					AppLogger.shared.transcriber.log(
						"Attempt \(attempt)/\(maxRetries) failed with MPS error: \(error)")

					if attempt < maxRetries {
						let delayNanoseconds = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
						AppLogger.shared.transcriber.log(
							"Waiting \(delayNanoseconds / 1_000_000_000)s before retry...")
						try? await Task.sleep(nanoseconds: delayNanoseconds)

						AppLogger.shared.transcriber.log("Allowing MPS to reinitialize...")
						try? await Task.sleep(nanoseconds: 1_000_000_000)
					}
				} else {
					AppLogger.shared.transcriber.log(
						"WhisperKit \(logPrefix) transcription failed with non-retryable error: \(error)")
					break
				}
			}
		}
		if let error = lastError {
			let errorString = error.localizedDescription
			if errorString.contains("Failed to open resource file")
				|| errorString.contains("MPSGraphComputePackage") || errorString.contains("Metal")
			{
				throw WhisperKitError.transcriptionFailed(
					"Metal Performance Shaders failed to load resources after \(maxRetries) attempts. Please restart the app."
				)
			} else if errorString.contains("Could not store NSNumber at offset") {
				throw WhisperKitError.transcriptionFailed(
					"Model cache size error. Try using a smaller model or restart the app."
				)
			} else {
				throw WhisperKitError.transcriptionFailed(error.localizedDescription)
			}
		} else {
			throw WhisperKitError.transcriptionFailed("Transcription failed for unknown reason")
		}
	}

	func getDecodingOptionsStatus() -> [String: Any] {
		return [
			"temperature": savedTemperature,
			"temperatureFallbackCount": savedTemperatureFallbackCount,
			"sampleLength": savedSampleLength,
			"usePrefillPrompt": savedUsePrefillPrompt,
			"usePrefillCache": savedUsePrefillCache,
			"skipSpecialTokens": savedSkipSpecialTokens,
			"withoutTimestamps": savedWithoutTimestamps,
			"wordTimestamps": savedWordTimestamps,
			"language": selectedLanguage,
			"lastUsedModel": lastUsedModel ?? "none",
		]
	}

	func transcribe(audioURL: URL, enableTranslation: Bool) async throws -> String {
		return try await performTranscription(
			input: .audioPath(audioURL.path),
			enableTranslation: enableTranslation,
			logPrefix: ""
		)
	}

	func transcribeAudioArray(_ audioArray: [Float], enableTranslation: Bool) async throws -> String {
		guard !audioArray.isEmpty else {
			AppLogger.shared.transcriber.log("Empty audio array provided")
			return ""
		}

		AppLogger.shared.transcriber.log(
			"Starting audio array transcription with \(audioArray.count) samples")

		return try await performTranscription(
			input: .audioArray(audioArray),
			enableTranslation: enableTranslation,
			logPrefix: "audio array"
		)
	}

	// MARK: - File Transcription Methods

	func transcribeFile(at url: URL, enableTranslation: Bool = false) async throws -> String {
		AppLogger.shared.transcriber.log("Starting file transcription for: \(url.lastPathComponent)")

		return try await performTranscription(
			input: .audioPath(url.path),
			enableTranslation: enableTranslation,
			logPrefix: "file"
		)
	}

	func transcribeFileWithTimestamps(at url: URL, enableTranslation: Bool = false) async throws
		-> [TranscriptionSegment]
	{
		AppLogger.shared.transcriber.log(
			"Starting timestamped file transcription for: \(url.lastPathComponent)")
		beginModelUse()
		defer { endModelUse() }
		try await waitForReadyForTranscription()
		if let engine = parakeetEngine {
			let transcript = try await engine.transcribe(fileURL: url)
			AppLogger.shared.transcriber.log(
				"Parakeet file transcription completed with \(transcript.segments.count) segments")
			return transcript.segments.compactMap { segment in
				let text = processTranscriptText(
					segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
					detectedLanguage: nil, enableTranslation: false, preservingLineBreaks: true,
					engineHonorsLanguage: false)
				guard !text.isEmpty else { return nil }
				return TranscriptionSegment(text: text, startTime: segment.startTime, endTime: segment.endTime)
			}
		}
		guard let whisperKitInstance = whisperKit else { throw WhisperKitError.notInitialized }

		let decodingOptions = await promptReadyDecodingOptions(enableTranslation: enableTranslation)

		let result = try await Task {
			if whisperKitInstance.modelState == .loading {
				AppLogger.shared.transcriber.log("Model isn't loaded yet. \(whisperKitInstance.modelState)")
			}

			return try await whisperKitInstance.transcribe(
				audioPath: url.path, decodeOptions: decodingOptions)
		}.value

		if !result.isEmpty {
			// WhisperKit returns [TranscriptionResult], we need to extract segments from each result
			let allSegments = result.flatMap { transcriptionResult in
				transcriptionResult.segments.compactMap { whisperSegment -> TranscriptionSegment? in
					let text = processTranscriptText(
						whisperSegment.text.trimmingCharacters(in: .whitespacesAndNewlines),
						detectedLanguage: transcriptionResult.language,
						enableTranslation: enableTranslation, preservingLineBreaks: true)
					guard !text.isEmpty else {
						return nil
					}

					return TranscriptionSegment(
						text: text,
						startTime: Double(whisperSegment.start),
						endTime: Double(whisperSegment.end)
					)
				}
			}

			AppLogger.shared.transcriber.log(
				"WhisperKit file transcription completed with \(allSegments.count) segments")
			return allSegments
		} else {
			AppLogger.shared.transcriber.log("No transcription segments returned")
			return []
		}
	}

	func transcribeFileSegment(
		at url: URL, startTime: Double, endTime: Double, enableTranslation: Bool = false
	) async throws -> String {
		AppLogger.shared.transcriber.log(
			"Starting segment transcription for: \(url.lastPathComponent) [\(startTime)s - \(endTime)s]"
		)

		guard startTime < endTime else {
			throw NSError(
				domain: "WhisperKitTranscriber", code: -1,
				userInfo: [NSLocalizedDescriptionKey: "Invalid time range"])
		}

		beginModelUse()
		defer { endModelUse() }
		try await waitForReadyForTranscription()
		if let engine = parakeetEngine {
			let samples = try AudioProcessor.loadAudioAsFloatArray(
				fromPath: url.path, startTime: startTime, endTime: endTime)
			let text = processTranscriptText(
				try await engine.transcribe(samples: samples).text, detectedLanguage: nil,
				enableTranslation: false, preservingLineBreaks: true, engineHonorsLanguage: false)
			return text.isEmpty ? "No speech detected in segment" : text
		}
		guard let whisperKitInstance = whisperKit else { throw WhisperKitError.notInitialized }

		var decodingOptions = await promptReadyDecodingOptions(enableTranslation: enableTranslation)

		// Set time range for segment transcription
		decodingOptions.clipTimestamps = [Float(startTime), Float(endTime)]

		let result = try await Task {
			if whisperKitInstance.modelState == .loading {
				AppLogger.shared.transcriber.log("Model isn't loaded yet. \(whisperKitInstance.modelState)")
			}

			return try await whisperKitInstance.transcribe(
				audioPath: url.path, decodeOptions: decodingOptions)
		}.value

		if !result.isEmpty {
			let transcription = processTranscriptText(
				result.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(
					in: .whitespacesAndNewlines),
				detectedLanguage: result.first?.language,
				enableTranslation: enableTranslation, preservingLineBreaks: true)

			if !transcription.isEmpty {
				AppLogger.shared.transcriber.userText(
					"WhisperKit segment transcription completed", transcription)
				return transcription
			} else {
				AppLogger.shared.transcriber.log("Segment transcription returned empty text")
				return "No speech detected in segment"
			}
		} else {
			AppLogger.shared.transcriber.log("No transcription segments returned for segment")
			return "No speech detected in segment"
		}
	}

	func switchModel(to model: String) async throws {
		try await runModelOperation { transcriber in
			try await transcriber.performSwitchModel(to: model)
		}
	}

	private func runModelOperation(
		_ body: @escaping @MainActor (WhisperKitTranscriber) async throws -> Void
	) async throws {
		try await modelOperations.run { [self] in
			try await body(self)
		}
	}

	private func performSwitchModel(to model: String) async throws {
		if model == currentModel, hasLoadedEngine {
			AppLogger.shared.transcriber.log("Model \(model) is already loaded")
			return
		}
		if ParakeetModel.isParakeetID(model) {
			if !downloadedModels.contains(model) {
				try await performDownloadModel(model)
			} else {
				try await loadModelInOperation(model)
			}
			return
		}

		if CustomWhisperModel.isCustomID(model) {
			guard CustomModelStore.shared.isAvailable(id: model) else {
				throw WhisperKitError.modelNotFound(model)
			}
			try await loadModelInOperation(model)
			return
		}

		// Check if model is already downloaded
		let currentlyDownloadedModels = try await getDownloadedModels()
		downloadedModels = currentlyDownloadedModels
		// Only a download needs the model list; it is a network fetch that held this operation
		// (and every load queued behind it) for up to 10 s even for a model already on disk
		if !currentlyDownloadedModels.contains(model), availableModels.isEmpty {
			try await refreshAvailableModels()
		}

		guard availableModels.contains(model) || currentlyDownloadedModels.contains(model) else {
			throw WhisperKitError.modelNotFound(model)
		}

		AppLogger.shared.transcriber.log("Switching to model: \(model)")

		if !currentlyDownloadedModels.contains(model) {
			AppLogger.shared.transcriber.log("Model \(model) not found locally, downloading first...")
			try await performDownloadModel(model)
			return  // downloadModel already creates the WhisperKit instance
		}

		// Model is downloaded, just need to load it
		try await loadModelInOperation(model)
	}

	private func updateDownloadProgress(_ progress: Double, _ status: String) async {
		await MainActor.run {
			// Late callbacks from a download that already ended would otherwise show a stale percentage
			guard self.isDownloadingModel else { return }
			self.downloadProgress = progress
		}
	}

	private func updateLoadProgress(_ progress: Double, _ status: String) async {
		await MainActor.run {
			self.loadProgress = progress
			// You could also update a load status message if needed
		}
	}

	func getDownloadedModels() async throws -> Set<String> {
		// Get the WhisperKit models base directory (without specific model name)
		guard
			let baseDir = baseModelCacheDirectory?.appendingPathComponent(
				"models/argmaxinc/whisperkit-coreml")
		else {
			throw NSError(
				domain: "ModelManager", code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Could not access WhisperKit models directory"])
		}

		// Check if the models directory exists
		guard FileManager.default.fileExists(atPath: baseDir.path) else {
			AppLogger.shared.transcriber.log("WhisperKit models directory doesn't exist yet")
			return additionalDownloadedModelIDs()
		}

		do {
			let contents = try FileManager.default.contentsOfDirectory(
				at: baseDir,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)

			let modelDirectories = try contents.filter { url in
				let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
				return resourceValues.isDirectory == true
			}

			let modelNames = Set(modelDirectories.map { $0.lastPathComponent })
			return modelNames.union(additionalDownloadedModelIDs())

		} catch {
			AppLogger.shared.transcriber.log("Error reading WhisperKit models directory: \(error)")
			throw error
		}
	}

	@ObservationIgnored var fetchModelCatalog: @Sendable () async throws -> [String] = {
		try await WhisperKit.fetchAvailableModels()
	}
	@ObservationIgnored private(set) var modelCatalogRefreshTask: Task<Void, Never>?

	func refreshModelCatalogInBackground() {
		modelCatalogRefreshTask?.cancel()
		modelCatalogRefreshTask = Task { @MainActor [weak self] in
			try? await self?.refreshAvailableModels()
		}
	}

	func refreshAvailableModels() async throws {
		do {
			// Add timeout to prevent hanging
			let fetch = fetchModelCatalog
			let fetchedModels = try await withTimeout(seconds: 10) {
				try await fetch()
			}

			// Remove duplicates using Set
			let uniqueModels = Array(Set(fetchedModels)).sorted()
			availableModels = uniqueModels + additionalAvailableModelIDs()

			AppLogger.shared.transcriber.log(
				"Refreshed available models: \(self.availableModels.count) unique models")
		} catch {
			AppLogger.shared.transcriber.log(
				"Failed to refresh available models, using defaults: \(error)")
			// Fallback to defaults instead of throwing
			let downloaded = (try? await getDownloadedModels()) ?? downloadedModels
			availableModels = Self.offlineModelList(downloaded: downloaded, additional: additionalAvailableModelIDs())
		}
	}

	nonisolated static let fallbackModelIDs = [
		"openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en",
	]

	/// Used when the model list cannot be fetched (offline, or the request times out). Models
	/// already on disk stay selectable; without them a downloaded model outside the short
	/// default list could not be switched to until the list fetch succeeded.
	nonisolated static func offlineModelList(downloaded: Set<String>, additional: [String]) -> [String] {
		let local = downloaded.filter { !CustomWhisperModel.isCustomID($0) && !ParakeetModel.isParakeetID($0) }.sorted()
		var seen = Set<String>()
		return (fallbackModelIDs + local + additional).filter { seen.insert($0).inserted }
	}

	/// Races `operation` against a deadline. Unlike a task group, this returns at the
	/// deadline even if the operation ignores cancellation (the model list fetch can),
	/// which otherwise leaves initialization waiting forever.
	private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T)
		async throws -> T
	{
		let gate = ResumeGate()
		return try await withCheckedThrowingContinuation { continuation in
			let work = Task {
				do {
					let value = try await operation()
					if gate.claim() { continuation.resume(returning: value) }
				} catch {
					if gate.claim() { continuation.resume(throwing: error) }
				}
			}
			Task {
				try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				if gate.claim() {
					work.cancel()
					continuation.resume(throwing: TimeoutError())
				}
			}
		}
	}

	private final class ResumeGate: @unchecked Sendable {
		private let lock = NSLock()
		private var claimed = false

		func claim() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			if claimed { return false }
			claimed = true
			return true
		}
	}

	private struct TimeoutError: Error {}

	func getRecommendedModels() -> (default: String, supported: [String]) {
		let recommended = WhisperKit.recommendedModels()
		return (default: recommended.default, supported: recommended.supported)
	}

	private func getAudioDuration(_ audioURL: URL) async throws -> Double {
		let asset = AVAsset(url: audioURL)
		let duration = try await asset.load(.duration)
		return CMTimeGetSeconds(duration)
	}

	func downloadModel(_ modelName: String) async throws {
		try await runModelOperation { transcriber in
			try await transcriber.performDownloadModel(modelName)
		}
	}

	/// Aborts the network phase of the running model download. The operation keeps holding the
	/// model-operation lock until its task has unwound, so a model picked right after this waits
	/// for it instead of loading alongside it.
	@MainActor
	func cancelModelDownload() {
		guard isDownloadingModel, isModelDownloadCancellable, modelOperations.cancelCurrent() else { return }
		endDownloadState()
		AppLogger.shared.transcriber.log("Model download cancelled by user")
	}

	private func performDownloadModel(_ modelName: String) async throws {
		// The cache can still be empty here (onboarding calls this before it is filled), and deleting
		// on a cancel must never remove a model that was already installed
		let wasOnDisk = Self.modelWasOnDisk(
			cached: downloadedModels.contains(modelName), folder: whisperKitModelDirectory(for: modelName))
		beginDownloadState(modelName)
		// A failed download or load must not leave the app looking busy: that blocked idle unload,
		// custom model import and the onboarding button until relaunch.
		defer { endDownloadState() }

		do {
			await updateDownloadProgress(0, "Starting download...")

			if let parakeet = ParakeetModel(rawValue: modelName) {
				guard let base = baseModelCacheDirectory else { throw WhisperKitError.notInitialized }
				try await ParakeetEngine.download(parakeet, modelsBase: base)
				try finishCancellableDownload()
				AppLogger.shared.transcriber.log("Parakeet model downloaded: \(modelName)")
				downloadedModels.insert(modelName)
				endDownloadState()
				try await loadModelInOperation(modelName)
				return
			}

			// Use WhisperKit's download method with default location
			let downloadedFolder = try await WhisperKit.download(
				variant: modelName, downloadBase: baseModelCacheDirectory
			) { progress in
				Task {
					await self.updateDownloadProgress(
						progress.fractionCompleted, "Downloading \(modelName)...")
				}
			}
			try finishCancellableDownload()
			AppLogger.shared.transcriber.log("Model downloaded to: \(downloadedFolder)")

			downloadedModels.insert(modelName)
			try await loadModelInOperation(modelName)
			AppLogger.shared.transcriber.log("Successfully downloaded and loaded model: \(modelName)")

		} catch {
			if Task.isCancelled, !wasOnDisk, !downloadedModels.contains(modelName) {
				discardCancelledDownload(of: modelName)
			}
			AppLogger.shared.transcriber.log("Failed to download model \(modelName): \(error)")
			throw error
		}
	}

	nonisolated static func modelWasOnDisk(cached: Bool, folder: URL?) -> Bool {
		if cached { return true }
		guard let folder else { return false }
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

	/// Ends the cancellable network phase; a Cancel that landed while the last bytes arrived still
	/// wins over the load that would follow.
	private func finishCancellableDownload() throws {
		isModelDownloadCancellable = false
		try Task.checkCancellation()
	}

	/// A cancelled WhisperKit download leaves a partial folder that would otherwise be listed as
	/// downloaded. Parakeet checks its files before listing a model, so its folder is left alone.
	private func discardCancelledDownload(of modelName: String) {
		guard !modelName.isEmpty, ParakeetModel(rawValue: modelName) == nil,
			!CustomWhisperModel.isCustomID(modelName),
			let folder = whisperKitModelDirectory(for: modelName),
			FileManager.default.fileExists(atPath: folder.path)
		else { return }
		do {
			try FileManager.default.removeItem(at: folder)
			AppLogger.shared.transcriber.log("Removed the partial download of \(modelName)")
		} catch {
			AppLogger.shared.transcriber.error("Could not remove the partial download of \(modelName): \(error)")
		}
	}

	func beginDownloadState(_ modelName: String) {
		isDownloadingModel = true
		isModelDownloadCancellable = true
		downloadingModelName = modelName
		downloadProgress = 0.0
	}

	func endDownloadState() {
		isDownloadingModel = false
		isModelDownloadCancellable = false
		downloadingModelName = nil
		downloadProgress = 0.0
	}

	func loadModel(_ modelName: String) async throws {
		if let parakeet = ParakeetModel(rawValue: modelName) {
			try await loadParakeetModel(parakeet)
			scheduleIdleUnload()
			return
		}
		isModelLoading = true
		loadProgress = 0.0
		loadingModelName = modelName
		defer {
			// WhisperKit's state callback never fires when the config or init throws first
			isModelLoading = false
			loadProgress = 0.0
			if loadingModelName == modelName { loadingModelName = nil }
			scheduleIdleUnload()
		}

		do {
			await updateLoadProgress(0.2, "Preparing to load \(modelName)...")

			let recommendedModels = WhisperKit.recommendedModels()
			AppLogger.shared.transcriber.debug("Recommended models: \(recommendedModels)")

			await updateLoadProgress(0.6, "Loading \(modelName)...")
			let loaded = try await Task { @MainActor in
				let config = try whisperKitConfig(forModel: modelName)
				let prewarmKey = Self.prewarmKey(model: modelName, computeOptions: config.computeOptions)
				if prewarmedModelKeys.contains(prewarmKey) {
					// Without prewarm WhisperKit only loads when told to (modelFolder is nil here),
					// and an unloaded model never reports ready
					config.prewarm = false
					config.load = true
				}
				let whisperKitInstance = try await Self.makeWhisperKit(config)
				prewarmedModelKeys.insert(prewarmKey)
				self.setupModelStateCallback(for: whisperKitInstance)
				return whisperKitInstance
			}.value
			// Only now, so a failed load keeps the Parakeet engine that was working
			unloadParakeetEngine()
			whisperKit = loaded
			// Options built while no tokenizer was loaded (launch, idle unload) have no prompt
			refreshDecodingOptions()

			await updateLoadProgress(0.9, "Finalizing model setup...")
			currentModel = modelName
			selectedModel = modelName
			lastUsedModel = modelName
			isIdleUnloaded = false

			if UserDefaults.standard.object(forKey: "decodingSampleLength") == nil {
				UserDefaults.standard.removeObject(forKey: "decodingSampleLength")
			}

			await updateLoadProgress(1.0, "Model ready!")

			AppLogger.shared.transcriber.log(
				"Successfully loaded model: \(modelName) with sampleLength: \(self.getModelSpecificSampleLength()) (saved as last used)"
			)

		} catch {
			AppLogger.shared.transcriber.log("Failed to load model \(modelName): \(error)")
			throw WhisperKitError.transcriptionFailed(
				"Failed to load model: \(error.localizedDescription)")
		}
	}

	nonisolated static func prewarmKey(model: String, computeOptions: ModelComputeOptions?) -> String {
		guard let options = computeOptions else { return "\(model)|default" }
		let units = [
			options.melCompute, options.audioEncoderCompute, options.textDecoderCompute, options.prefillCompute,
		]
		return "\(model)|" + units.map { String($0.rawValue) }.joined(separator: ",")
	}

	/// Loads a model from inside a model operation, after any dictation reload running beside it.
	private func loadModelInOperation(_ modelName: String) async throws {
		await modelOperations.waitForRestore()
		try await loadModel(modelName)
	}

	/// The reload a dictation triggers when no engine is loaded. It never runs next to another
	/// load: see `ModelOperationQueue.restore`.
	private func loadModelCoalesced(_ modelName: String) async throws {
		if let pendingLoadTask {
			try await pendingLoadTask.value
			return
		}
		let task = Task { @MainActor in
			try await self.modelOperations.restore(
				canRunBesideCurrent: { [weak self] in self?.isModelDownloadCancellable ?? false },
				isNeeded: { [weak self] in self.map { !$0.hasLoadedEngine } ?? false },
				load: { [weak self] in try await self?.loadModel(modelName) }
			)
		}
		pendingLoadTask = task
		defer { pendingLoadTask = nil }
		try await task.value
	}

	// MARK: - Idle Model Unload

	/// Marks the model as in use so the idle timer cannot unload it mid-transcription.
	/// Every call must be balanced by `endModelUse()`.
	func beginModelUse() {
		activeModelUses += 1
		idleUnloadTimer.cancel()
	}

	func endModelUse() {
		activeModelUses = max(0, activeModelUses - 1)
		for engine in retiredParakeetEngines.drain(activeUses: activeModelUses) {
			engine.unload()
			AppLogger.shared.transcriber.log(
				"Unloaded replaced Parakeet model \(engine.modelID) after its last use")
		}
		scheduleIdleUnload()
	}

	/// Starts loading a model that was released by the idle timer, so it is ready by the
	/// time a recording stops.
	func preloadModelIfIdleUnloaded() {
		guard isIdleUnloaded, !hasLoadedEngine, pendingLoadTask == nil else { return }
		AppLogger.shared.transcriber.info("Reloading model released by the idle timer")
		Task { @MainActor in
			do {
				try await waitForReadyForTranscription()
			} catch {
				AppLogger.shared.transcriber.error("Failed to reload idle-unloaded model: \(error)")
			}
		}
	}

	var canUnloadModel: Bool {
		idleUnloadBlockers.isEmpty
	}

	/// Names every condition currently keeping the model from being unloaded.
	var idleUnloadBlockers: [String] {
		var blockers: [String] = []
		if !hasLoadedEngine { blockers.append("no model loaded") }
		if activeModelUses > 0 { blockers.append("\(activeModelUses) active model uses") }
		if isLiveTranscriptionMode { blockers.append("live transcription") }
		if modelOperations.isBusy { blockers.append("model operation running") }
		if pendingLoadTask != nil { blockers.append("model load pending") }
		if initializationTask != nil { blockers.append("initialization running") }
		if isModelLoading { blockers.append("model loading") }
		if isDownloadingModel { blockers.append("model downloading") }
		return blockers
	}

	func scheduleIdleUnload() {
		guard let interval = RecordingControlSettings().modelUnloadTimeout.interval else {
			idleUnloadTimer.cancel()
			return
		}
		guard activeModelUses == 0, hasLoadedEngine else { return }
		idleUnloadRetry.reset()
		idleUnloadTimer.schedule(after: interval) { [weak self] in
			await self?.unloadModelIfIdle()
		}
	}

	private func unloadModelIfIdle() async {
		guard hasLoadedEngine, activeModelUses == 0, !isLiveTranscriptionMode else { return }
		guard canUnloadModel else {
			// A model operation or load is still settling; try again once it has.
			guard idleUnloadRetry.shouldRetry() else {
				AppLogger.shared.transcriber.info(
					"Idle unload gave up while blocked by \(self.idleUnloadBlockers.joined(separator: ", "))")
				return
			}
			idleUnloadTimer.schedule(after: IdleUnloadRetryPolicy.interval) { [weak self] in
				await self?.unloadModelIfIdle()
			}
			return
		}
		AppLogger.shared.transcriber.info("Unloading model after idle timeout")
		await unloadModel()
	}

	/// Releases the loaded model's memory. The next transcription reloads it on demand.
	func unloadModel() async {
		guard canUnloadModel else {
			AppLogger.shared.transcriber.info("Model unload skipped: model busy or not loaded")
			return
		}
		idleUnloadTimer.cancel()
		if parakeetEngine != nil {
			unloadParakeetEngine()
			isIdleUnloaded = true
			isModelLoaded = false
			publishEngineState(from: modelState, to: "unloaded")
			AppLogger.shared.transcriber.info(
				"Unloaded model \(currentModel ?? "unknown"); it will reload on next use")
			return
		}
		guard let instance = whisperKit else { return }
		// Detach first so a transcription that starts during the unload loads a fresh
		// instance instead of reusing one whose models are being torn down.
		instance.modelStateCallback = nil
		whisperKit = nil
		isIdleUnloaded = true
		handleModelStateChange(from: instance.modelState, to: .unloaded)
		await instance.unloadModels()
		AppLogger.shared.transcriber.info(
			"Unloaded model \(currentModel ?? "unknown"); it will reload on next use")
	}

	private func createSilentAudioFile() -> URL {
		let tempDir = FileManager.default.temporaryDirectory
		let fileName = "mps_prewarm_\(UUID().uuidString).wav"
		let audioURL = tempDir.appendingPathComponent(fileName)

		// Create a 0.5 second silent WAV file
		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsFloatKey: false,
		]

		do {
			let audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
			let frameCount = AVAudioFrameCount(16000 * 0.5)  // 0.5 seconds
			let silentBuffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
			silentBuffer.frameLength = frameCount
			// Buffer is already zeroed (silent)
			try audioFile.write(from: silentBuffer)
		} catch {
			AppLogger.shared.transcriber.log("Failed to create silent audio file: \(error)")
		}

		return audioURL
	}

	private func isWhisperKitReady() -> Bool {
		if !isInitialized {
			return false
		}
		return (whisperKit != nil || parakeetEngine != nil) && isInitialized
	}

	func isReadyForTranscription() -> Bool {
		return isInitialized && (whisperKit != nil || parakeetEngine != nil)
	}

	func hasAnyModel() -> Bool {
		return whisperKit != nil || parakeetEngine != nil || isIdleUnloaded
	}

	private func getApplicationSupportDirectory() -> URL {
		let appSupport = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
		let appDirectory = appSupport.appendingPathComponent("Whispera")

		// Ensure app directory exists
		try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

		return appDirectory
	}

	// MARK: - Model Helpers

	static func getModelDisplayName(for modelName: String) -> String {
		if let parakeet = ParakeetModel(rawValue: modelName) { return parakeet.displayName }
		if CustomWhisperModel.isCustomID(modelName) {
			let name =
				CustomModelStore.shared.model(id: modelName)?.displayName
				?? String(modelName.dropFirst(CustomWhisperModel.idPrefix.count))
			return "Custom: \(name)"
		}
		let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")

		switch cleanName {
		case "tiny.en": return "Tiny (English) - 39MB"
		case "tiny": return "Tiny (Multilingual) - 39MB"
		case "base.en": return "Base (English) - 74MB"
		case "base": return "Base (Multilingual) - 74MB"
		case "small.en": return "Small (English) - 244MB"
		case "small": return "Small (Multilingual) - 244MB"
		case "medium.en": return "Medium (English) - 769MB"
		case "medium": return "Medium (Multilingual) - 769MB"
		case "large-v2": return "Large v2 (Multilingual) - 1.5GB"
		case "large-v3": return "Large v3 (Multilingual) - 1.5GB"
		case "large-v3-turbo": return "Large v3 Turbo (Multilingual) - 809MB"
		case "distil-large-v2": return "Distil Large v2 (Multilingual) - 756MB"
		case "distil-large-v3": return "Distil Large v3 (Multilingual) - 756MB"
		default: return cleanName.capitalized
		}
	}

	static func getModelPriority(for modelName: String) -> Int {
		if CustomWhisperModel.isCustomID(modelName) { return 10 }
		if ParakeetModel.isParakeetID(modelName) { return 8 }
		let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")

		switch cleanName {
		case "tiny.en", "tiny": return 1
		case "base.en", "base": return 2
		case "small.en", "small": return 3
		case "medium.en", "medium": return 4
		case "large-v2": return 5
		case "large-v3": return 6
		case "large-v3-turbo": return 7
		case "distil-large-v2", "distil-large-v3": return 8
		default: return 9
		}
	}

	// MARK: - Model Sources

	static func isStandardWhisperKitModel(_ id: String) -> Bool {
		!CustomWhisperModel.isCustomID(id) && !ParakeetModel.isParakeetID(id)
	}

	/// Parakeet streams nothing back while recording, so dictation falls back to record-then-transcribe.
	var supportsLiveTranscription: Bool {
		guard let model = currentModel ?? lastUsedModel ?? selectedModel else { return true }
		return !ParakeetModel.isParakeetID(model)
	}

	private func additionalDownloadedModelIDs() -> Set<String> {
		var ids = Set(CustomModelStore.shared.availableModels.map(\.id))
		if let base = baseModelCacheDirectory {
			for model in ParakeetModel.allCases where ParakeetEngine.isDownloaded(model, modelsBase: base) {
				ids.insert(model.rawValue)
			}
		}
		return ids
	}

	private func additionalAvailableModelIDs() -> [String] {
		ParakeetModel.allCases.map(\.rawValue) + CustomModelStore.shared.availableModels.map(\.id)
	}

	private func loadParakeetModel(_ model: ParakeetModel) async throws {
		guard let base = baseModelCacheDirectory else { throw WhisperKitError.notInitialized }
		isModelLoading = true
		loadProgress = 0.3
		loadingModelName = model.rawValue
		publishEngineState(from: modelState, to: "loading")
		defer {
			isModelLoading = false
			loadProgress = 0.0
			if loadingModelName == model.rawValue { loadingModelName = nil }
		}

		do {
			let engine = try await ParakeetEngine.load(
				model, modelsBase: base,
				computeUnits: ComputeUnitPreference.load().parakeetComputeUnits)
			unloadParakeetEngine()
			whisperKit = nil
			parakeetEngine = engine
			currentModel = model.rawValue
			selectedModel = model.rawValue
			lastUsedModel = model.rawValue
			isModelLoaded = true
			isIdleUnloaded = false
			publishEngineState(from: "loading", to: "loaded")
			AppLogger.shared.transcriber.log("Loaded Parakeet model \(model.rawValue) via FluidAudio")
		} catch {
			isModelLoaded = whisperKit != nil
			publishEngineState(from: "loading", to: whisperKit == nil ? "unloaded" : "loaded")
			AppLogger.shared.transcriber.error("Failed to load Parakeet model \(model.rawValue): \(error)")
			throw WhisperKitError.transcriptionFailed(
				"Failed to load model: \(error.localizedDescription)")
		}
	}

	/// A transcription that already captured the engine keeps using it, so while any model hold
	/// is active the engine is only detached and torn down when the last hold ends.
	private func unloadParakeetEngine() {
		guard let engine = parakeetEngine else { return }
		parakeetEngine = nil
		guard let idle = retiredParakeetEngines.release(engine, activeUses: activeModelUses) else {
			AppLogger.shared.transcriber.log(
				"Detached Parakeet model \(engine.modelID); unloading once its transcriptions finish")
			return
		}
		idle.unload()
		AppLogger.shared.transcriber.log("Unloaded Parakeet model \(idle.modelID)")
	}

	private func publishEngineState(from oldState: String, to newState: String) {
		modelState = newState
		NotificationCenter.default.post(
			name: NSNotification.Name("WhisperKitModelStateChanged"),
			object: nil,
			userInfo: [
				"oldState": oldState,
				"newState": newState,
				"isLoading": newState == "loading",
				"isLoaded": newState == "loaded",
			]
		)
	}

	private func transcribe(
		with engine: any LocalModelEngine, input: TranscriptionInput, enableTranslation: Bool,
		logPrefix: String
	) async throws -> String {
		if enableTranslation {
			AppLogger.shared.transcriber.log("\(engine.modelID) cannot translate; transcribing instead")
		}
		do {
			let transcript: EngineTranscript
			switch input {
			case .audioPath(let path):
				transcript = try await engine.transcribe(fileURL: URL(fileURLWithPath: path))
			case .audioArray(let samples):
				transcript = try await engine.transcribe(samples: samples)
			}
			// Parakeet reports no language, so the pipeline relies on the selected language or text detection
			let text = processTranscriptText(
				transcript.text, detectedLanguage: nil, enableTranslation: false, engineHonorsLanguage: false)
			guard !text.isEmpty else {
				AppLogger.shared.transcriber.log("\(engine.modelID) returned empty text")
				return ""
			}
			AppLogger.shared.transcriber.info(
				"\(engine.modelID) \(logPrefix) transcription completed (\(ExtendedLogger.redactedSummary(text)))")
			return text
		} catch {
			AppLogger.shared.transcriber.error("\(engine.modelID) transcription failed: \(error)")
			throw WhisperKitError.transcriptionFailed(error.localizedDescription)
		}
	}

	private func whisperKitConfig(forModel modelName: String) throws -> WhisperKitConfig {
		if CustomWhisperModel.isCustomID(modelName) {
			guard let custom = CustomModelStore.shared.model(id: modelName),
				CustomModelStore.shared.isAvailable(id: modelName)
			else {
				throw WhisperKitError.modelNotFound(modelName)
			}
			return custom.whisperKitConfig(
				downloadBase: baseModelCacheDirectory, computeOptions: getOptimizedComputeOptions())
		}
		return WhisperKitConfig(
			model: modelName,
			downloadBase: baseModelCacheDirectory,
			computeOptions: getOptimizedComputeOptions(),
			prewarm: true
		)
	}

	func addCustomModel(fromHuggingFace repoInput: String, variant: String) async throws
		-> CustomWhisperModel
	{
		guard let reference = HuggingFaceModelReference.parse(repoInput: repoInput, variant: variant)
		else {
			throw CustomModelError.invalidReference
		}
		guard !reference.isBuiltInRepository else { throw CustomModelError.builtInRepository }
		guard !CustomModelStore.shared.containsHuggingFace(reference) else {
			throw CustomModelError.alreadyAdded("\(reference.repo)/\(reference.variant)")
		}
		var added: CustomWhisperModel?
		try await runModelOperation { transcriber in
			added = try await transcriber.performAddCustomModel(reference)
		}
		guard let added else { throw CancellationError() }
		return added
	}

	private func performAddCustomModel(_ reference: HuggingFaceModelReference) async throws
		-> CustomWhisperModel
	{
		beginDownloadState(reference.variant)
		defer { endDownloadState() }

		AppLogger.shared.transcriber.log(
			"Downloading custom model \(reference.variant) from \(reference.repo)")
		let folder = try await WhisperKit.download(
			variant: reference.variant,
			downloadBase: baseModelCacheDirectory,
			from: reference.repo
		) { progress in
			Task {
				await self.updateDownloadProgress(
					progress.fractionCompleted, "Downloading \(reference.variant)...")
			}
		}

		let model: CustomWhisperModel
		do {
			try finishCancellableDownload()
			model = try CustomModelStore.shared.registerHuggingFaceModel(reference, folder: folder)
		} catch {
			CustomModelStore.shared.discardFailedDownload(folder)
			throw error
		}
		downloadedModels.insert(model.id)
		try? await refreshAvailableModels()
		return model
	}

	func importCustomModel(from folder: URL) async throws -> CustomWhisperModel {
		let model = try await CustomModelStore.shared.importLocalFolder(folder)
		downloadedModels.insert(model.id)
		try? await refreshAvailableModels()
		return model
	}

	func removeCustomModel(id: String) async throws {
		if currentModel == id {
			throw CustomModelError.inUse(Self.getModelDisplayName(for: id))
		}
		try CustomModelStore.shared.remove(id: id)
		downloadedModels.remove(id)
		availableModels.removeAll { $0 == id }
		if selectedModel == id { selectedModel = nil }
		if lastUsedModel == id { lastUsedModel = nil }
	}

	// MARK: - Model Management

	func clearDownloadedModelsCache() {
		downloadedModels.removeAll()
		UserDefaults.standard.removeObject(forKey: "downloadedModels")
		AppLogger.shared.transcriber.log("Cleared downloaded models cache")
	}

	// MARK: - WhisperKit Model State Management
	private func setupModelStateCallback(for whisperKitInstance: WhisperKit) {
		whisperKitInstance.modelStateCallback = { [weak self] oldState, newState in
			DispatchQueue.main.async {
				self?.handleModelStateChange(from: oldState, to: newState)
			}
		}

		// Set initial state
		handleModelStateChange(from: nil, to: whisperKitInstance.modelState)
	}

	private func handleModelStateChange(from oldState: ModelState?, to newState: ModelState) {
		let stateString = String(describing: newState)
		modelState = stateString
		isModelLoading = (newState == .loading || newState == .prewarming)
		isModelLoaded = (newState == .loaded || newState == .prewarmed)

		AppLogger.shared.transcriber.log(
			"WhisperKit model state changed: \(oldState.map(String.init(describing:)) ?? "nil") -> \(stateString)"
		)

		// Post notification for other parts of the app
		NotificationCenter.default.post(
			name: NSNotification.Name("WhisperKitModelStateChanged"),
			object: nil,
			userInfo: [
				"oldState": oldState.map(String.init(describing:)) ?? "unknown",
				"newState": stateString,
				"isLoading": isModelLoading,
				"isLoaded": isModelLoaded,
			]
		)
	}

	func getCurrentModelState() -> String {
		if parakeetEngine != nil { return "loaded" }
		guard let whisperKit = whisperKit else { return "unloaded" }
		return String(describing: whisperKit.modelState)
	}

	private func setupUserDefaultsObservation() {
		settingsObserver = DefaultsKeyObserver(
			keys: [
				"selectedLanguage", "enableTranslation", RecordingControlSettings.Key.modelUnloadTimeout,
			]
		) { [weak self] in
			self?.checkForSettingsChanges()
		}
		customWordsObserver = CustomWordPromptObserver { [weak self] in
			AppLogger.shared.transcriber.log("Custom words changed; rebuilding the decoder prompt")
			self?.refreshDecodingOptions()
		}
	}

	private var lastObservedLanguage: String?
	private var lastObservedTranslation: Bool?

	private func checkForSettingsChanges() {
		let currentLanguage = selectedLanguage
		let currentTranslation = enableTranslation ?? false

		// Check if language changed
		if lastObservedLanguage != currentLanguage {
			lastObservedLanguage = currentLanguage
			handleLanguageSettingsChanged()
		}

		// Check if translation mode changed
		if lastObservedTranslation != currentTranslation {
			lastObservedTranslation = currentTranslation
			handleTranslationSettingsChanged()
		}

		let currentUnloadTimeout = RecordingControlSettings().modelUnloadTimeout
		if lastObservedUnloadTimeout != currentUnloadTimeout {
			lastObservedUnloadTimeout = currentUnloadTimeout
			scheduleIdleUnload()
		}
	}

	private func handleLanguageSettingsChanged() {
		AppLogger.shared.transcriber.log("Language changed to: \(self.selectedLanguage)")

		decodingOptions = createDecodingOptions(
			enableTranslation: enableTranslation ?? false
		)
		AppLogger.shared.transcriber.log(
			"Updated live transcription language to: \(self.selectedLanguage)")

	}

	private func handleTranslationSettingsChanged() {
		AppLogger.shared.transcriber.log(
			"Translation mode changed to: \(self.enableTranslation ?? false)")

		// Update decoding options if we're actively transcribing
		if isTranscribing && isLiveTranscriptionMode {
			updateDecodingOptionsForTranslation(enableTranslation: self.enableTranslation ?? false)
			AppLogger.shared.transcriber.log("Updated live transcription translation mode")
		}
	}

	func isCurrentlyLoadingModel() -> Bool {
		guard let whisperKit = whisperKit else { return false }
		return whisperKit.modelState == .loading || whisperKit.modelState == .prewarming
	}

	func isCurrentModelLoaded() -> Bool {
		if parakeetEngine != nil { return true }
		guard let whisperKit = whisperKit else { return false }
		return whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed
	}

	func loadCurrentModel() async throws {
		guard whisperKit != nil || parakeetEngine != nil else {
			throw WhisperKitError.notInitialized
		}

		let model = currentModel ?? getRecommendedModels().default
		try await runModelOperation { transcriber in
			try await transcriber.loadModelInOperation(model)
		}
	}

	private func getOptimizedComputeOptions() -> ModelComputeOptions {
		return ComputeUnitPreference.load().whisperKitComputeOptions
	}

	var computeUnitPreference: ComputeUnitPreference {
		ComputeUnitPreference.load()
	}

	func applyComputeUnitPreference(_ preference: ComputeUnitPreference) async throws {
		guard preference != ComputeUnitPreference.load() else { return }
		preference.save()
		AppLogger.shared.transcriber.log("Compute units changed to \(preference.rawValue)")

		guard let model = currentModel else { return }
		try await runModelOperation { transcriber in
			try await transcriber.loadModelInOperation(model)
		}
	}

	func getComputeOptionsStatus() -> [String: String] {
		let options = getOptimizedComputeOptions()
		return [
			"melCompute": mlComputeUnitsName(options.melCompute),
			"audioEncoderCompute": mlComputeUnitsName(options.audioEncoderCompute),
			"textDecoderCompute": mlComputeUnitsName(options.textDecoderCompute),
			"prefillCompute": mlComputeUnitsName(options.prefillCompute),
		]
	}

	private func mlComputeUnitsName(_ units: MLComputeUnits) -> String {
		switch units {
		case .cpuOnly: return "cpuOnly"
		case .cpuAndGPU: return "cpuAndGPU"
		case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
		case .all: return "all"
		@unknown default: return "unknown"
		}
	}
}

enum WhisperKitError: LocalizedError {
	case notInitialized
	case notReady
	case noModelLoaded
	case modelNotFound(String)
	case audioConversionFailed
	case transcriptionFailed(String)
	case liveModeUnsupported
	/// Carries the display name, resolved when thrown.
	case modelLoadTimedOut(String?)

	var errorDescription: String? {
		let description: String
		switch self {
		case .notInitialized:
			description = "WhisperKit not initialized. Please wait for startup to complete."
		case .notReady:
			description = "WhisperKit not ready for transcription. Please wait a moment and try again."
		case .noModelLoaded:
			description = "No Whisper model loaded. Please download a model first."
		case .modelNotFound(let model):
			description = "Model '\(model)' not found in available models."
		case .audioConversionFailed:
			description = "Failed to convert audio to required format."
		case .transcriptionFailed(let error):
			description = "Transcription failed: \(error)"
		case .liveModeUnsupported:
			description =
				"Live Transcription Mode needs a Whisper model. Parakeet transcribes after you stop recording."
		case .modelLoadTimedOut(let modelName):
			if let modelName {
				description = String(
					localized:
						"\(modelName) is still loading, so this dictation could not be transcribed. Try again once it is ready, or pick another model in Settings."
				)
			} else {
				description = String(
					localized:
						"The model is still loading, so this dictation could not be transcribed. Try again once it is ready, or pick another model in Settings."
				)
			}
		}

		AppLogger.shared.transcriber.error("WhisperKitError: \(description)")
		return description
	}
}

/// Runs model operations one at a time. Only the operation that took the slot releases it, and only
/// once its task has finished, so a cancelled download keeps later loads waiting until it unwinds
/// instead of letting two loads race and one's cleanup clear the other's state.
@MainActor
final class ModelOperationQueue {
	private var current: Task<Void, Error>?
	private var currentID: UUID?

	var isBusy: Bool { current != nil }

	func run(_ body: @escaping @MainActor () async throws -> Void) async throws {
		while let existing = current {
			AppLogger.shared.transcriber.log("Waiting for existing model operation to complete...")
			_ = await existing.result
		}
		try Task.checkCancellation()
		let id = UUID()
		let task = Task { @MainActor [weak self] in
			defer {
				if let self, self.currentID == id {
					self.current = nil
					self.currentID = nil
				}
			}
			try await body()
		}
		current = task
		currentID = id
		try await task.value
	}

	/// Returns false when nothing is running.
	@discardableResult
	func cancelCurrent() -> Bool {
		guard let current else { return false }
		current.cancel()
		return true
	}

	/// A reload of the previous model for a dictation, running beside an operation that is
	/// still downloading. Operations call `waitForRestore()` before they load a model, so the
	/// reload always finishes first and cannot overwrite the model the user just picked.
	private var restoreTask: Task<Void, Error>?

	var isRestoring: Bool { restoreTask != nil }

	/// Brings back the model a dictation needs. With nothing running, the reload takes the slot
	/// like any operation. While an operation is only downloading (`canRunBesideCurrent`), it runs
	/// beside it, since waiting could mean minutes. Otherwise it waits for the operation and then
	/// loads only if `isNeeded` still holds, because that operation usually leaves a model loaded.
	func restore(
		canRunBesideCurrent: @MainActor () -> Bool,
		isNeeded: @escaping @MainActor () -> Bool,
		load: @escaping @MainActor () async throws -> Void
	) async throws {
		if let restoreTask {
			try await restoreTask.value
			return
		}
		guard current != nil, canRunBesideCurrent() else {
			try await run {
				guard isNeeded() else { return }
				try await load()
			}
			return
		}
		guard isNeeded() else { return }
		let id = UUID()
		let task = Task { @MainActor [weak self] in
			defer {
				if let self, self.restoreID == id {
					self.restoreTask = nil
					self.restoreID = nil
				}
			}
			try await load()
		}
		restoreTask = task
		restoreID = id
		try await task.value
	}

	private var restoreID: UUID?

	/// Called by an operation right before it loads a model.
	func waitForRestore() async {
		while let restoreTask {
			_ = await restoreTask.result
		}
	}
}
