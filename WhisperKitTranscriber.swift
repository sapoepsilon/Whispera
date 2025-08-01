import Foundation
import AVFoundation
import WhisperKit
import SwiftUI
import OSLog
import AppKit
import Combine

@MainActor
@Observable open class WhisperKitTranscriber: Sendable {
	var isInitialized = false
	private var cancellables = Set<AnyCancellable>()
	var isInitializing = false
	var isStreamingAudio: Bool = false
	var initializationProgress: Double = 0.0
	var initializationStatus = "Starting..."
	var availableModels: [String] = []
	var currentModel: String?
	var downloadedModels: Set<String> = []
	var onConfirmedTextChange: ((String) -> Void)?
	var shouldShowWindow: Bool = false
	var isTranscribing: Bool = false
	var decodingOptions: DecodingOptions?
	var currentText: String = ""
	var dictationWordTracker: DictationWordTracker?
	// Live text management
	private var isLiveTranscriptionMode = false
	private var lastConfirmedSegmentCount: Int = 0
	var confirmedText: String = ""{
		didSet {
			onConfirmedTextChange?(confirmedText)
		}
	}
	private var pendingText: String = ""  // Internal working property
	var stableDisplayText: String = ""    // UI-facing stable property
	private var lastDisplayedPendingText: String = ""
	var shouldShowDebugWindow: Bool = false
	var latestWord: String {
		let words = stableDisplayText.split(separator: " ")
		return words.last?.description ?? ""
	}

	func clearLiveTranscriptionState() {
		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		shouldShowWindow = false
		isTranscribing = false
		confirmedText = ""
		shouldShowDebugWindow = false
		transcriptionTask?.cancel()
		transcriptionTask = nil
		lastBufferSize = 0
		lastConfirmedSegmentCount = 0
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
		let source = CGEventSource(stateID: .combinedSessionState)
		let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
		let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
		
		keyDownEvent?.flags = modifier
		keyUpEvent?.flags = modifier
		
		keyDownEvent?.post(tap: .cghidEventTap)
		keyUpEvent?.post(tap: .cghidEventTap)
	}
	
	private func confirmPendingText() {
		guard !pendingText.isEmpty else { return }
		
		// Sync all display properties before confirming to prevent double transcription
		stableDisplayText = pendingText
		lastDisplayedPendingText = pendingText
		
		// Since WhisperKit provides complete transcription history in pendingText,
		// we replace confirmedText entirely rather than appending
		confirmedText = pendingText
		pendingText = ""
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
			return value == 0.0 ? 0.0 : value // 0.0 is our default
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "decodingTemperature")
		}
	}
	
	private var savedTemperatureFallbackCount: Int {
		get {
			let value = UserDefaults.standard.integer(forKey: "decodingTemperatureFallbackCount")
			return value == 0 ? 1 : value // Default to 1
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
	
	private var lastUsedModel: String? {
		get {
			UserDefaults.standard.string(forKey: "lastUsedModel")
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "lastUsedModel")
		}
	}
	
	private var enableTranslation: Bool? {
		get {
			UserDefaults.standard.bool(forKey: "enableTranslation")
		}
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
		guard let appSupport = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera/Models/\(modelName)")
	}
	
	var baseModelCacheDirectory: URL? {
		guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera")
	}
	
	private func whisperKitModelDirectory(for modelName: String?) -> URL? {
		let name = modelName ?? ""
		return baseModelCacheDirectory?.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)")
	}
	
	var isDownloadingModel = false {
		didSet {
			// Notify observers when download state changes
			if isDownloadingModel != oldValue {
				NotificationCenter.default.post(name: NSNotification.Name("DownloadStateChanged"), object: nil)
			}
		}
	}
	var downloadProgress: Double = 0.0
	var downloadingModelName: String?
	var loadProgress: Double = 0.0
	
	@MainActor var whisperKit: WhisperKit?
	private var transcriptionTask: Task<Void, Never>?
	private var lastBufferSize: Int = 0
	private var realtimeDelayInterval: Float = 0.3
	@MainActor private var initializationTask: Task<Void, Never>?
	@MainActor private var modelOperationTask: Task<Void, Error>?
	
	private var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
	
	// Swift 6 compliant singleton pattern
	static let shared: WhisperKitTranscriber = {
		let instance = WhisperKitTranscriber()
		return instance
	}()
	
	private init() {
		// Initialize last observed values to prevent unnecessary updates on first launch
		lastObservedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? Constants.defaultLanguageName
		lastObservedTranslation = UserDefaults.standard.bool(forKey: "enableTranslation")
		
		Task{
			downloadedModels = try await getDownloadedModels()
			AppLogger.shared.transcriber.log("downloaded models: \(self.downloadedModels)")
			// Initialize decoding options for live streaming
			startInitialization()
		}
		// Set up reactive UserDefaults observation
		setupUserDefaultsObservation()
	}
	
	func startInitialization() {
		guard initializationTask == nil else {
			AppLogger.shared.transcriber.log("📋 WhisperKit initialization already in progress...")
			return
		}
		
		isInitializing = true
		initializationProgress = 0.0
		initializationStatus = "Preparing to load Whisper models..."
		
		initializationTask = Task { @MainActor in
			await initialize()
		}
	}
	
	 func initialize() async {
		guard !isInitialized else {
			AppLogger.shared.transcriber.log("📋 WhisperKit already initialized")
			isInitializing = false
			return
		}
		await updateProgress(0.1, "Loading WhisperKit framework...")
		try? await Task.sleep(nanoseconds: 500_000_000) // Small delay for UI feedback
		
		AppLogger.shared.transcriber.log("🔄 Initializing WhisperKit framework...")
		await updateProgress(0.3, "Setting up AI framework...")
		
		// Sync our cache with what's actually on disk
		await updateProgress(0.6, "Checking for existing models...")
		
		if !downloadedModels.isEmpty {
			await updateProgress(0.8, "Loading existing model...")
			do {
				whisperKit = try await Task { @MainActor in
					let whisperKitInstance = try await WhisperKit(downloadBase: baseModelCacheDirectory)
					self.setupModelStateCallback(for: whisperKitInstance)
					return whisperKitInstance
				}.value
				AppLogger.shared.transcriber.log("✅ WhisperKit initialized with existing models")
				await updateProgress(0.9, "Loading last used model...")
				try await autoLoadLastModel()
				
			} catch {
				AppLogger.shared.transcriber.log("⚠️ Failed to initialize with existing models: \(error)")
				AppLogger.shared.transcriber.log("📋 Will initialize WhisperKit when first model is downloaded")
			}
		} else {
			AppLogger.shared.transcriber.log("📋 No models downloaded yet - WhisperKit will be initialized with first model download")
		}
		
		await updateProgress(1.0, "Ready for model selection!")
		 decodingOptions = createDecodingOptions(
			enableTranslation: enableTranslation ?? false
		 )
		 
		isInitialized = true
		isInitializing = false
		AppLogger.shared.transcriber.log("✅ WhisperKit framework initialized - ready for transcription")
		initializationTask = nil
	}
	
	private func autoLoadLastModel() async throws {
		guard let lastModel = lastUsedModel else {
			AppLogger.shared.transcriber.log("📋 No last used model found, will use default when needed")
			return
		}
		
		guard downloadedModels.contains(lastModel) else {
			AppLogger.shared.transcriber.log("⚠️ Last used model '\(lastModel)' is no longer available, clearing preference")
			lastUsedModel = nil
			return
		}
		
		do {
			AppLogger.shared.transcriber.log("🔄 Auto-loading last used model: \(lastModel)")
			try await loadModel(lastModel)
			try await refreshAvailableModels()
			AppLogger.shared.transcriber.log("✅ Successfully auto-loaded last used model: \(lastModel)")
		} catch {
			AppLogger.shared.transcriber.log("⚠️ Failed to auto-load last used model '\(lastModel)': \(error)")
			AppLogger.shared.transcriber.log("📋 Clearing invalid model preference")
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
		AppLogger.shared.transcriber.info("Starting live stream...")
		guard isInitialized else {
			throw WhisperKitError.notInitialized
		}
		
		guard let whisperKit = whisperKit else {
			throw WhisperKitError.notInitialized
		}
		
		guard isWhisperKitReady() else {
			throw WhisperKitError.notReady
		}
		
		dictationWordTracker = DictationWordTracker() // TODO: Make sure this is a correct way of doing it
		dictationWordTracker?.startNewSession()
		
		shouldShowWindow = true
		isTranscribing = true
		isLiveTranscriptionMode = true
		lastConfirmedSegmentCount = 0
		
		try? whisperKit.audioProcessor.startRecordingLive { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }
				self.shouldShowWindow = true
			}
		}
		realtimeLoop()
	}
	
	func stopLiveStream() {
		isTranscribing = false
		shouldShowWindow = false
		whisperKit?.audioProcessor.stopRecording()
		
		confirmPendingText()
		isLiveTranscriptionMode = false
		dictationWordTracker?.endSession()
		transcriptionTask?.cancel()
		AppLogger.shared.transcriber.info("🛑 Live streaming stopped")
	}
	
	private func realtimeLoop() {
		transcriptionTask = Task {
			while isTranscribing {
				do {
					try await transcribeCurrentBuffer(delayInterval: realtimeDelayInterval)
				} catch {
					AppLogger.shared.liveTranscriber.error(
						"Transcription error: \(error.localizedDescription)"
					)
					break
				}
			}
		}
	}
	
		
	
 // TODO: Allow a user to choose between pending text, and the confirmed text. Do not impelment it the og author will do it
	private func transcribeCurrentBuffer(delayInterval: Float = 0.3) async throws {
		guard let whisperKit = whisperKit else { return }
		
		let currentBuffer = whisperKit.audioProcessor.audioSamples
		let nextBufferSize = currentBuffer.count - lastBufferSize
		let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
		
		guard nextBufferSeconds > delayInterval else {
			await MainActor.run {
				if pendingText.isEmpty && confirmedText.isEmpty {
					pendingText = "Waiting for speech..."
					shouldShowWindow = true
				}
			}
			try await Task.sleep(nanoseconds: 100_000_000)
			return
		}
		
		lastBufferSize = currentBuffer.count
		let transcription = try await transcribeAudioSamples(Array(currentBuffer))
		
		await MainActor.run {
			guard let segments = transcription?.segments, !segments.isEmpty else {
				return
			}
			
			let fullTranscriptionText = segments
				.map { $0.text.trimmingCharacters(in: .whitespaces) }
				.joined(separator: " ")
			
			print("📝 Transcription received: \(segments.count) segments, full text: '\(fullTranscriptionText)'")
			print("📝 Current state: confirmedText.count=\(confirmedText.count), pendingText='\(pendingText)'")
			
			let requiredSegmentsForConfirmation = 2
			
			if segments.count > requiredSegmentsForConfirmation {
				let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation
				
				// Only confirm new segments that haven't been confirmed before
				if numberOfSegmentsToConfirm > lastConfirmedSegmentCount {
					let newSegmentsToConfirm = numberOfSegmentsToConfirm - lastConfirmedSegmentCount
					let startIndex = lastConfirmedSegmentCount
					let endIndex = lastConfirmedSegmentCount + newSegmentsToConfirm
					
					let newConfirmedSegments = Array(segments[startIndex..<endIndex])
					
					let newConfirmedText = newConfirmedSegments
						.map { $0.text.trimmingCharacters(in: .whitespaces) }
						.joined(separator: " ")
					
					print("📝 New segments to confirm: \(newSegmentsToConfirm), text: '\(newConfirmedText)'")
					
					if !newConfirmedText.isEmpty {
						let updatedConfirmedText: String
						if !confirmedText.isEmpty {
							updatedConfirmedText = confirmedText + " " + newConfirmedText
						} else {
							updatedConfirmedText = newConfirmedText
						}
						confirmedText = updatedConfirmedText
						lastConfirmedSegmentCount = numberOfSegmentsToConfirm
					}
				} else {
					print("📝 No new segments to confirm (already confirmed \(lastConfirmedSegmentCount) segments)")
				}
				let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))
				
				let newPendingText = remainingSegments
					.map { $0.text.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
				
				// Always update internal pendingText for logic
				pendingText = newPendingText
				
				// Only update UI-facing property if text has changed meaningfully
				if shouldUpdatePendingText(newText: newPendingText) {
					stableDisplayText = newPendingText
					lastDisplayedPendingText = newPendingText
				}
			} else {
				let newPendingText = segments
					.map { $0.text.trimmingCharacters(in: .whitespaces) }
					.joined(separator: " ")
				
				// Always update internal pendingText for logic
				pendingText = newPendingText
				
				// Only update UI-facing property if text has changed meaningfully
				if shouldUpdatePendingText(newText: newPendingText) {
					stableDisplayText = newPendingText
					lastDisplayedPendingText = newPendingText
				}
			}
			
			shouldShowWindow = !stableDisplayText.isEmpty || !confirmedText.isEmpty
		}
	}
	
	private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
		guard let whisperKit = whisperKit else { return nil }
			
		guard let options = decodingOptions else {
			AppLogger.shared.transcriber.log("⚠️ Decoding options not initialized, creating default options")
			return nil
		}
		
		let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
			Task { @MainActor in
				self.pendingText = progress.text
			}
			return nil
		}
		
		do {
			let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
				audioArray: samples,
				decodeOptions: options,
				callback: decodingCallback,
			)
			
			return transcriptionResults.first
		} catch {
			let errorString = error.localizedDescription
			if errorString.contains("Could not store NSNumber at offset") ||
				errorString.contains("beyond the end of the multi array") {
				AppLogger.shared.transcriber.log("⚠️ Array bounds error detected, retrying with smaller sampleLength")
				
				// Retry with a smaller sampleLength
				let fallbackOptions = DecodingOptions(
					verbose: false,
					task: options.task,
					language: options.language,
					temperature: savedTemperature,
					temperatureFallbackCount: savedTemperatureFallbackCount,
					sampleLength: 224, // Use safe fallback
					usePrefillPrompt: savedUsePrefillPrompt,
					usePrefillCache: savedUsePrefillCache,
					skipSpecialTokens: savedSkipSpecialTokens,
					withoutTimestamps: savedWithoutTimestamps,
					wordTimestamps: savedWordTimestamps,
					clipTimestamps: [0]
				)
				
				let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
					audioArray: samples,
					decodeOptions: fallbackOptions,
					callback: decodingCallback
				)
				
				return transcriptionResults.first
			} else {
				throw error
			}
		}
	}
	
	// MARK: - Decoding Options Management
	private func createDefaultDecodingOptions() -> DecodingOptions {
		return DecodingOptions(
			verbose: false,
			task: .transcribe,
			language: Constants.languageCode(for: selectedLanguage),
			temperature: savedTemperature,
			temperatureFallbackCount: savedTemperatureFallbackCount,
			sampleLength: savedSampleLength,
			usePrefillPrompt: savedUsePrefillPrompt,
			usePrefillCache: savedUsePrefillCache,
			detectLanguage: false,
			skipSpecialTokens: savedSkipSpecialTokens,
			withoutTimestamps: savedWithoutTimestamps,
			wordTimestamps: savedWordTimestamps,
			clipTimestamps: [0]
		)
	}
	
	func createDecodingOptions(enableTranslation: Bool) -> DecodingOptions {
		let task: DecodingTask = enableTranslation ? .translate : .transcribe
		let languageCode = Constants.languageCode(for: selectedLanguage)
		
		AppLogger.shared.transcriber.log("Creating decoding options - mode: \(task.description) language: \(languageCode)")
		return DecodingOptions(
			verbose: false,
			task: task,
			language: languageCode,
			temperature: savedTemperature,
			temperatureFallbackCount: savedTemperatureFallbackCount,
			sampleLength: savedSampleLength,
			usePrefillPrompt: savedUsePrefillPrompt,
			usePrefillCache: savedUsePrefillCache,
			detectLanguage: enableTranslation,
			skipSpecialTokens: savedSkipSpecialTokens,
			withoutTimestamps: savedWithoutTimestamps,
			wordTimestamps: savedWordTimestamps,
			clipTimestamps: [0]
		)
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
		
		AppLogger.shared.transcriber.log("🔧 Updated decoding options - temperature: \(self.savedTemperature), sampleLength: \(self.savedSampleLength)")
		
		// Recreate decoding options with updated values
		if let currentOptions = decodingOptions {
			// Preserve the current translation setting
			let isTranslating = currentOptions.task == .translate
			decodingOptions = createDecodingOptions(enableTranslation: !isTranslating) // Note: reversed due to existing logic
		}
	}
	
	func getCurrentDecodingOptions(enableTranslation: Bool) -> DecodingOptions {
		return createDecodingOptions(enableTranslation: enableTranslation)
	}
	
	// MARK: - Dynamic Settings Management
	func reloadCurrentModelIfNeeded() async throws {
		guard let currentModel = currentModel else {
			AppLogger.shared.transcriber.log("📋 No current model to reload")
			return
		}
		AppLogger.shared.transcriber.log("🔄 Reloading current model: \(currentModel)")
		try await loadModel(currentModel)
	}
	
	func updateLanguageSettings(_ newLanguage: String) {
		let oldLanguage = selectedLanguage
		selectedLanguage = newLanguage
		AppLogger.shared.transcriber.log("🔧 Updated language: \(oldLanguage) -> \(newLanguage)")
		// Update decoding options with new language
		updateDecodingOptionsForTranslation(
			enableTranslation: enableTranslation ?? false
		)
	}
	
	func updateDecodingOptionsForTranslation(enableTranslation: Bool) {
		decodingOptions = createDecodingOptions(enableTranslation: enableTranslation)
		AppLogger.shared.transcriber.log("🔧 Updated decoding options for translation mode: \(enableTranslation ? "enabled" : "disabled")")
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
		AppLogger.shared.transcriber.log("🔧 Updated transcription quality settings")
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
		AppLogger.shared.transcriber.log("🔧 Updated advanced transcription settings")
	}
	
	private func getModelSpecificSampleLength() -> Int {
		guard let currentModelName = currentModel else {
			return 224 // Safe default for unknown models
		}
		
		let modelName = currentModelName.lowercased()
		
		// Use conservative sampleLength values based on model size
		if modelName.contains("tiny") {
			return 224
		} else if modelName.contains("base") {
			return 224
		} else if modelName.contains("small") {
			return 224
		} else if modelName.contains("medium") {
			return 448
		} else if modelName.contains("large") || modelName.contains("turbo") {
			return 448
		} else {
			return 224 // Safe fallback
		}
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
		AppLogger.shared.transcriber.log("🔄 Reset all decoding options to defaults")
	}
	
	private enum TranscriptionInput {
		case audioPath(String)
		case audioArray([Float])
	}
	
	private func performTranscription(input: TranscriptionInput, enableTranslation: Bool, logPrefix: String) async throws -> String {
		guard isInitialized else {
			throw WhisperKitError.notInitialized
		}
		
		guard whisperKit != nil else {
			throw WhisperKitError.noModelLoaded
		}
		
		guard isWhisperKitReady() else {
			throw WhisperKitError.notReady
		}
		
		let maxRetries = 3
		var lastError: Error?
		decodingOptions = createDecodingOptions(enableTranslation: enableTranslation)
		
		for attempt in 1...maxRetries {
			do {
				let result = try await Task { @MainActor in
					guard let whisperKitInstance = self.whisperKit else {
						throw WhisperKitError.notInitialized
					}
					if whisperKitInstance.modelState == .loading {
						AppLogger.shared.transcriber.log("Model isn't loaded yet. \(whisperKitInstance.modelState)")
					}
					
					switch input {
						case .audioPath(let path):
							return try await whisperKitInstance.transcribe(audioPath: path, decodeOptions: decodingOptions)
						case .audioArray(let array):
							return try await whisperKitInstance.transcribe(audioArray: array, decodeOptions: decodingOptions)
					}
				}.value
				
				if !result.isEmpty {
					let transcription = result.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
					
					if !transcription.isEmpty {
						AppLogger.shared.transcriber.log("✅ WhisperKit \(logPrefix) transcription completed: \(transcription)")
						return transcription
					} else {
						AppLogger.shared.transcriber.log("⚠️ Transcription returned empty text")
						return "No speech detected"
					}
				} else {
					AppLogger.shared.transcriber.log("⚠️ No transcription segments returned")
					return "No speech detected"
				}
				
			} catch {
				lastError = error
				let errorString = error.localizedDescription
				
				if errorString.contains("Failed to open resource file") ||
					errorString.contains("MPSGraphComputePackage") ||
					errorString.contains("Metal") {
					
					AppLogger.shared.transcriber.log("⚠️ Attempt \(attempt)/\(maxRetries) failed with MPS error: \(error)")
					
					if attempt < maxRetries {
						let delayNanoseconds = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
						AppLogger.shared.transcriber.log("⏳ Waiting \(delayNanoseconds / 1_000_000_000)s before retry...")
						try? await Task.sleep(nanoseconds: delayNanoseconds)
						
						AppLogger.shared.transcriber.log("🔄 Allowing MPS to reinitialize...")
						try? await Task.sleep(nanoseconds: 1_000_000_000)
					}
				} else {
					AppLogger.shared.transcriber.log("❌ WhisperKit \(logPrefix) transcription failed with non-retryable error: \(error)")
					break
				}
			}
		}
		
		if let error = lastError {
			let errorString = error.localizedDescription
			if errorString.contains("Failed to open resource file") ||
				errorString.contains("MPSGraphComputePackage") ||
				errorString.contains("Metal") {
				throw WhisperKitError.transcriptionFailed("Metal Performance Shaders failed to load resources after \(maxRetries) attempts. Please restart the app.")
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
			"lastUsedModel": lastUsedModel ?? "none"
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
			AppLogger.shared.transcriber.log("⚠️ Empty audio array provided")
			return "No audio data provided"
		}
		
		AppLogger.shared.transcriber.log("🎵 Starting audio array transcription with \(audioArray.count) samples")
		
		return try await performTranscription(
			input: .audioArray(audioArray),
			enableTranslation: enableTranslation,
			logPrefix: "audio array"
		)
	}
	
	func switchModel(to model: String) async throws {
		if let existingTask = modelOperationTask {
			AppLogger.shared.transcriber.log("⏳ Waiting for existing model operation to complete...")
			try await existingTask.value
		}
		
		// Create new operation task
		modelOperationTask = Task { @MainActor in
			try await performSwitchModel(to: model)
		}
		
		do {
			try await modelOperationTask!.value
		} catch {
			modelOperationTask = nil
			throw error
		}
		
		modelOperationTask = nil
	}
	
	private func performSwitchModel(to model: String) async throws {
		// Refresh available models first to ensure we have the latest list
		if availableModels.isEmpty {
			try await refreshAvailableModels()
		}
		
		guard availableModels.contains(model) else {
			throw WhisperKitError.modelNotFound(model)
		}
		
		AppLogger.shared.transcriber.log("🔄 Switching to model: \(model)")
		
		// Check if model is already downloaded
		let currentlyDownloadedModels = try await getDownloadedModels()
		downloadedModels = currentlyDownloadedModels
		
		if !currentlyDownloadedModels.contains(model) {
			AppLogger.shared.transcriber.log("📥 Model \(model) not found locally, downloading first...")
			try await performDownloadModel(model)
			return // downloadModel already creates the WhisperKit instance
		}
		
		// Model is downloaded, just need to load it
		try await loadModel(model)
	}
	
	private func updateDownloadProgress(_ progress: Double, _ status: String) async {
		await MainActor.run {
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
		guard let baseDir = baseModelCacheDirectory?.appendingPathComponent("models/argmaxinc/whisperkit-coreml") else {
			throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access WhisperKit models directory"])
		}
		
		// Check if the models directory exists
		guard FileManager.default.fileExists(atPath: baseDir.path) else {
			AppLogger.shared.transcriber.log("📝 WhisperKit models directory doesn't exist yet")
			return Set<String>()
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
			return modelNames
			
		} catch {
			AppLogger.shared.transcriber.log("❌ Error reading WhisperKit models directory: \(error)")
			throw error
		}
	}
	
	func refreshAvailableModels() async throws {
		do {
			// Add timeout to prevent hanging
			let fetchedModels = try await withTimeout(seconds: 10) {
				try await WhisperKit.fetchAvailableModels()
			}
			
			// Remove duplicates using Set
			let uniqueModels = Array(Set(fetchedModels)).sorted()
			availableModels = uniqueModels
			
			AppLogger.shared.transcriber.log("✅ Refreshed available models: \(self.availableModels.count) unique models")
		} catch {
			AppLogger.shared.transcriber.log("❌ Failed to refresh available models, using defaults: \(error)")
			// Fallback to defaults instead of throwing
			availableModels = ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en"]
		}
	}
	
	private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask {
				try await operation()
			}
			
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				throw TimeoutError()
			}
			
			guard let result = try await group.next() else {
				throw TimeoutError()
			}
			
			group.cancelAll()
			return result
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
		// Check if there's already a model operation in progress
		if let existingTask = modelOperationTask {
			AppLogger.shared.transcriber.log("⏳ Waiting for existing model operation to complete...")
			try await existingTask.value
		}
		
		// Create new operation task
		modelOperationTask = Task { @MainActor in
			try await performDownloadModel(modelName)
		}
		
		do {
			try await modelOperationTask!.value
		} catch {
			modelOperationTask = nil
			throw error
		}
		
		modelOperationTask = nil
	}
	
	private func performDownloadModel(_ modelName: String) async throws {
		isDownloadingModel = true
		downloadingModelName = modelName
		downloadProgress = 0.0
		
		do {
			await updateDownloadProgress(0, "Starting download...")
			
			// Use WhisperKit's download method with default location
			let downloadedFolder = try await WhisperKit.download(variant: modelName, downloadBase: baseModelCacheDirectory) { progress in
				Task {
					await self.updateDownloadProgress(progress.fractionCompleted, "Downloading \(modelName)...")
				}
			}
			AppLogger.shared.transcriber.log("📥 Model downloaded to: \(downloadedFolder)")
			
			downloadedModels.insert(modelName)
			try await loadModel(modelName)
			AppLogger.shared.transcriber.log("✅ Successfully downloaded and loaded model: \(modelName)")
			
		} catch {
			AppLogger.shared.transcriber.log("❌ Failed to download model \(modelName): \(error)")
			throw error
		}
		
		isDownloadingModel = false
		downloadingModelName = nil
		downloadProgress = 0.0
	}
	
	private func loadModel(_ modelName: String) async throws {
		isModelLoading = true
		loadProgress = 0.0
		
		do {
			await updateLoadProgress(0.2, "Preparing to load \(modelName)...")
			
			let recommendedModels = WhisperKit.recommendedModels()
			AppLogger.shared.transcriber.debug("👂🏼 Recommended models: \(recommendedModels)")
			
			await updateLoadProgress(0.6, "Loading \(modelName)...")
			whisperKit = try await Task { @MainActor in
				let config = WhisperKitConfig(
					model: modelName,
					downloadBase: baseModelCacheDirectory,
					computeOptions: ModelComputeOptions(
						melCompute: .cpuAndNeuralEngine,
						audioEncoderCompute: .cpuAndNeuralEngine,
						textDecoderCompute: .cpuAndNeuralEngine
					)
				)
				let whisperKitInstance = try await WhisperKit(config)
				self.setupModelStateCallback(for: whisperKitInstance)
				return whisperKitInstance
			}.value
			
			await updateLoadProgress(0.9, "Finalizing model setup...")
			currentModel = modelName
			selectedModel = modelName
			lastUsedModel = modelName
			
			if UserDefaults.standard.object(forKey: "decodingSampleLength") == nil {
				UserDefaults.standard.removeObject(forKey: "decodingSampleLength")
			}
			
			await updateLoadProgress(1.0, "Model ready!")
			
			AppLogger.shared.transcriber.log("✅ Successfully loaded model: \(modelName) with sampleLength: \(self.getModelSpecificSampleLength()) (saved as last used)")
			
		} catch {
			AppLogger.shared.transcriber.log("❌ Failed to load model \(modelName): \(error)")
			throw WhisperKitError.transcriptionFailed("Failed to load model: \(error.localizedDescription)")
		}
		
		isModelLoading = false
		loadProgress = 0.0
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
			AVLinearPCMIsFloatKey: false
		]
		
		do {
			let audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
			let frameCount = AVAudioFrameCount(16000 * 0.5) // 0.5 seconds
			let silentBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
			silentBuffer.frameLength = frameCount
			// Buffer is already zeroed (silent)
			try audioFile.write(from: silentBuffer)
		} catch {
			AppLogger.shared.transcriber.log("⚠️ Failed to create silent audio file: \(error)")
		}
		
		return audioURL
	}
	
	private func isWhisperKitReady() -> Bool {
		if !isInitialized {
			return false
		}
		return whisperKit != nil && isInitialized
	}
	
	func isReadyForTranscription() -> Bool {
		return isInitialized && whisperKit != nil
	}
	
	func hasAnyModel() -> Bool {
		return whisperKit != nil
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
	
	// MARK: - Model Management
	
	func clearDownloadedModelsCache() {
		downloadedModels.removeAll()
		UserDefaults.standard.removeObject(forKey: "downloadedModels")
		AppLogger.shared.transcriber.log("🗑️ Cleared downloaded models cache")
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
		
		
		AppLogger.shared.transcriber.log("🎯 WhisperKit model state changed: \(oldState.map(String.init(describing:)) ?? "nil") -> \(stateString)")
		
		// Post notification for other parts of the app
		NotificationCenter.default.post(
			name: NSNotification.Name("WhisperKitModelStateChanged"),
			object: nil,
			userInfo: [
				"oldState": oldState.map(String.init(describing:)) ?? "unknown",
				"newState": stateString,
				"isLoading": isModelLoading,
				"isLoaded": isModelLoaded
			]
		)
	}
	
	func getCurrentModelState() -> String {
		guard let whisperKit = whisperKit else { return "unloaded" }
		return String(describing: whisperKit.modelState)
	}
	
	private func setupUserDefaultsObservation() {
		// Observe language changes
		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.checkForSettingsChanges()
			}
			.store(in: &cancellables)
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
	}
	
	private func handleLanguageSettingsChanged() {
		AppLogger.shared.transcriber.log("🔄 Language changed to: \(self.selectedLanguage)")
		
		decodingOptions = createDecodingOptions(
			enableTranslation: enableTranslation ?? false
		)
		AppLogger.shared.transcriber.log("✅ Updated live transcription language to: \(self.selectedLanguage)")
	
	}
	
	private func handleTranslationSettingsChanged() {
		AppLogger.shared.transcriber.log("🔄 Translation mode changed to: \(self.enableTranslation ?? false)")
		
		// Update decoding options if we're actively transcribing
		if isTranscribing && isLiveTranscriptionMode {
			updateDecodingOptionsForTranslation(enableTranslation: self.enableTranslation ?? false)
			AppLogger.shared.transcriber.log("✅ Updated live transcription translation mode")
		}
	}
	
	func isCurrentlyLoadingModel() -> Bool {
		guard let whisperKit = whisperKit else { return false }
		return whisperKit.modelState == .loading || whisperKit.modelState == .prewarming
	}
	
	func isCurrentModelLoaded() -> Bool {
		guard let whisperKit = whisperKit else { return false }
		return whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed
	}
	
	func loadCurrentModel() async throws {
		guard whisperKit != nil else {
			throw WhisperKitError.notInitialized
		}
		
		if let currentModel = currentModel {
			try await loadModel(currentModel)
		} else {
			let recommended = getRecommendedModels()
			try await loadModel(recommended.default)
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
		}
		
		AppLogger.shared.transcriber.error("WhisperKitError: \(description)")
		return description
	}
}
