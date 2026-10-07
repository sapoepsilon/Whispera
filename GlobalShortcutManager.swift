import ApplicationServices
import Cocoa
import Foundation
import SwiftUI

class GlobalShortcutManager: ObservableObject {
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var fileSelectionGlobalMonitor: Any?
	private var fileSelectionLocalMonitor: Any?
	private var modifierGlobalMonitor: Any?
	private var modifierLocalMonitor: Any?
	private var modifierMachine: ModifierOnlyShortcutMachine?
	/// The capture the current single-key press started, the only one its cancel may discard.
	@MainActor private var modifierPressSession: Int?
	private var audioManager: AudioManager?
	private var fileTranscriptionManager: FileTranscriptionManager?
	private var networkDownloader: NetworkFileDownloader?
	private var queueManager: TranscriptionQueueManager?
	private var isProcessingFileOperation = false
	private let cleanUpShortcutMonitor = CleanUpShortcutMonitor()
	private var requestedBackend = HotkeyBackend.preferred()
	private var activeBackend = HotkeyBackend.eventMonitor
	private let logger = AppLogger.shared.general
	@MainActor private var cancelMonitor: CancelShortcutMonitor?
	@MainActor private var activation = ActivationStateMachine(
		mode: .toggle, holdThreshold: TimeInterval(RecordingControlSettings.defaultHoldThresholdMs) / 1000)
	private var recordingStateObserver: NSObjectProtocol?
	private var defaultsObserver: DefaultsKeyObserver?
	private var monitorsKeyRelease = false
	var currentShortcut: String = ShortcutDefaults.dictation(in: .standard)
	var fileSelectionShortcut: String = ShortcutDefaults.fileSelection(in: .standard)

	// MARK: - Settings
	private var autoDeleteDownloadedFiles: Bool {
		UserDefaults.standard.bool(forKey: "autoDeleteDownloadedFiles")
	}

	init() {
		setupShortcut()
		defaultsObserver = DefaultsKeyObserver(
			keys: [
				"globalShortcut", "fileSelectionShortcut", HotkeyBackend.defaultsKey,
				RecordingControlSettings.Key.activationMode,
			]
		) { [weak self] in
			self?.shortcutSettingsChanged()
		}
	}

	private func shortcutSettingsChanged() {
		let newShortcut = ShortcutDefaults.dictation(in: .standard)
		let newFileShortcut = ShortcutDefaults.fileSelection(in: .standard)
		let newBackend = HotkeyBackend.preferred()
		var needsSetup = false

		if newBackend != requestedBackend {
			logger.info("Hotkey backend changed to \(newBackend.rawValue)")
			requestedBackend = newBackend
			needsSetup = true
		}

		if newShortcut != currentShortcut {
			logger.info("Text shortcut changed: \(currentShortcut) → \(newShortcut)")
			currentShortcut = newShortcut
			needsSetup = true
		}

		if newFileShortcut != fileSelectionShortcut {
			logger.info(
				"File selection shortcut changed: \(fileSelectionShortcut) → \(newFileShortcut)")
			fileSelectionShortcut = newFileShortcut
			needsSetup = true
		}

		if RecordingControlSettings().activationMode.needsKeyRelease != monitorsKeyRelease {
			logger.info("Activation mode changed; reinstalling shortcut monitors")
			needsSetup = true
		}

		if needsSetup { setupShortcut() }
	}

	func setAudioManager(_ manager: AudioManager) {
		self.audioManager = manager
		logger.info("AudioManager set, checking accessibility status...")
		cleanUpShortcutMonitor.attach(audioManager: manager)
		checkAccessibilityStatus()
		observeRecordingStateForCancel()
	}

	private func observeRecordingStateForCancel() {
		guard recordingStateObserver == nil else { return }
		recordingStateObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in self?.updateCancelMonitor() }
		}
	}

	@MainActor
	private func updateCancelMonitor() {
		guard let audioManager else { return }
		let shouldListen = CancelShortcutPolicy.shouldListen(
			isRecording: audioManager.isRecording, isStarting: audioManager.isMicrophoneInitializing,
			enabled: RecordingControlSettings().cancelShortcutEnabled)
		if shouldListen && cancelMonitor == nil {
			cancelMonitor = CancelShortcutMonitor { [weak self] in
				self?.logger.info("Cancel shortcut pressed")
				self?.audioManager?.cancelRecording()
			}
		}
		cancelMonitor?.setActive(shouldListen)
	}

	func setFileTranscriptionManager(_ manager: FileTranscriptionManager) {
		self.fileTranscriptionManager = manager
		logger.info("FileTranscriptionManager set")
	}

	func setNetworkDownloader(_ downloader: NetworkFileDownloader) {
		self.networkDownloader = downloader
		logger.info("NetworkFileDownloader set")
	}

	func setQueueManager(_ manager: TranscriptionQueueManager) {
		self.queueManager = manager
		logger.info("TranscriptionQueueManager set")
	}

	func checkAccessibilityStatus() {
		let hasPermissions = AXIsProcessTrusted()
		logger.info("Current accessibility permissions: \(hasPermissions)")
		logger.info("Text shortcut: \(currentShortcut)")
		logger.info("File selection shortcut: \(fileSelectionShortcut)")
		logger.info(
			"Global monitors active - Text: \(globalMonitor != nil), File: \(fileSelectionGlobalMonitor != nil)"
		)

		if !hasPermissions {
			logger.error("PROBLEM: No accessibility permissions - shortcuts will NOT work")
			logger.error("Go to System Settings > Privacy & Security > Accessibility")
			logger.error("Add Whispera to the list and enable it")
		} else if activeBackend == .eventMonitor
			&& ((globalMonitor == nil && modifierGlobalMonitor == nil) || fileSelectionGlobalMonitor == nil)
		{
			logger.error("PROBLEM: Some global monitors not set up despite having permissions")
			setupShortcut()
		}
	}

	private func setupShortcut() {
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
			self.globalMonitor = nil
			logger.info("Removed old text global monitor")
		}
		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
			self.localMonitor = nil
			logger.info("Removed old text local monitor")
		}
		if let monitor = fileSelectionGlobalMonitor {
			NSEvent.removeMonitor(monitor)
			self.fileSelectionGlobalMonitor = nil
			logger.info("Removed old file selection global monitor")
		}
		if let monitor = fileSelectionLocalMonitor {
			NSEvent.removeMonitor(monitor)
			self.fileSelectionLocalMonitor = nil
			logger.info("Removed old file selection local monitor")
		}
		removeModifierMonitors()
		CarbonHotKeyCenter.shared.unregisterAll()
		// A release in flight is lost when the monitors or hotkeys are replaced
		Task { @MainActor [weak self] in
			self?.activation.reset()
			self?.modifierMachine?.reset()
			self?.modifierPressSession = nil
		}
		cleanUpShortcutMonitor.reinstall()
		monitorsKeyRelease = RecordingControlSettings().activationMode.needsKeyRelease

		if let modifierKey = ModifierOnlyShortcut(stored: currentShortcut) {
			installModifierOnlyShortcut(modifierKey)
			return
		}

		let (textModifiers, textKeyCode) = parseShortcut(
			currentShortcut, fallback: ShortcutDefaults.dictation, defaultsKey: ShortcutDefaults.dictationKey)
		logger.info(
			"Setting up text shortcut for \(currentShortcut) (keyCode: \(textKeyCode), modifiers: \(textModifiers.rawValue))"
		)

		let (fileModifiers, fileKeyCode) = parseShortcut(
			fileSelectionShortcut, fallback: ShortcutDefaults.fileSelection,
			defaultsKey: ShortcutDefaults.fileSelectionKey)
		logger.info(
			"Setting up file selection shortcut for \(fileSelectionShortcut) (keyCode: \(fileKeyCode), modifiers: \(fileModifiers.rawValue))"
		)

		if requestedBackend == .carbon {
			// The secure input fallback may already hold this combination on its own Carbon center,
			// which would make this registration fail with eventHotKeyExistsErr
			stopSecureInputFallback()
			do {
				try CarbonHotKeyCenter.shared.register(
					keyCode: textKeyCode, modifiers: textModifiers,
					onRelease: { [weak self] in self?.handleTextHotKeyRelease() }
				) { [weak self] in
					self?.handleTextHotKey(isRepeat: false, source: .systemHotKey)
				}
				publishBackend(active: .carbon, message: nil)
				// A fallback start queued by an earlier setup must not bring the monitor back
				Task { @MainActor in SecureInputMonitor.shared.stop() }
				// The file shortcut (default Control-F) stays observed rather than registered: a
				// system hotkey would swallow it in every app, breaking forward-char in text fields
				installFileSelectionMonitors(modifiers: fileModifiers, keyCode: fileKeyCode)
				logger.info("Registered the text shortcut as a system hotkey; file selection stays on event monitors")
				return
			} catch {
				CarbonHotKeyCenter.shared.unregisterAll()
				logger.error("System hotkey registration failed, using event monitors: \(error.localizedDescription)")
				publishBackend(
					active: .eventMonitor,
					message: String(
						localized:
							"System hotkey unavailable (\(error.localizedDescription)); using the event monitor."
					))
			}
		} else {
			publishBackend(active: .eventMonitor, message: nil)
		}

		// A global key-up monitor wakes the app on every key release in every app, so it is
		// only installed for the activation modes that act on release.
		let globalMask: NSEvent.EventTypeMask = monitorsKeyRelease ? [.keyDown, .keyUp] : .keyDown
		logger.info("Installing global monitors (key release: \(monitorsKeyRelease))...")
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) {
			[weak self] event in
			// Whispera's own Cmd-V key-up would otherwise end a held shortcut that uses V
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return }
			if event.type == .keyUp {
				if event.keyCode == textKeyCode {
					self?.handleTextHotKeyRelease()
				}
				return
			}
			if self?.matchesShortcut(
				event: event, expectedModifiers: textModifiers, expectedKeyCode: textKeyCode) == true
			{
				if !event.isARepeat {
					self?.logger.info("Global text shortcut detected!")
				}
				self?.handleTextHotKey(isRepeat: event.isARepeat)
			} else if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Global file selection shortcut detected!")
				self?.handleFileSelectionHotKey()
			}
		}

		// Also set up local monitors as fallback (works when app is focused)
		logger.info("Installing local monitors as fallback...")
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
			[weak self] event in
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return event }
			if event.type == .keyUp {
				if event.keyCode == textKeyCode {
					self?.handleTextHotKeyRelease()
				}
				return event
			}
			if self?.matchesShortcut(
				event: event, expectedModifiers: textModifiers, expectedKeyCode: textKeyCode) == true
			{
				if !event.isARepeat {
					self?.logger.info("Local text shortcut detected!")
				}
				self?.handleTextHotKey(isRepeat: event.isARepeat)
				return nil  // Consume the event
			} else if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Local file selection shortcut detected!")
				self?.handleFileSelectionHotKey()
				return nil  // Consume the event
			}
			return event
		}

		installFileSelectionMonitors(modifiers: fileModifiers, keyCode: fileKeyCode)

		logger.info(
			"Monitors installed - Text Global: \(globalMonitor != nil), Text Local: \(localMonitor != nil)"
		)
		configureSecureInputFallback(modifiers: textModifiers, keyCode: textKeyCode)
	}

	/// A modifier on its own reaches apps only as flagsChanged, which neither Carbon hotkeys nor
	/// the secure input fallback can bind, so it always runs on the event monitors.
	private func installModifierOnlyShortcut(_ key: ModifierOnlyShortcut) {
		stopSecureInputFallback()
		// Secure Input blinds this monitor too, and there is no hotkey to fall back on, so the
		// monitor only warns: without it dictation would stop working with nothing saying why
		Task { @MainActor in
			SecureInputMonitor.shared.configureWarningOnly()
			SecureInputMonitor.shared.start()
		}
		publishBackend(
			active: .eventMonitor,
			message: requestedBackend == .carbon
				? String(
					localized:
						"System hotkeys cannot bind \(key.displayName) on its own, so the event monitor is used.")
				: nil)
		modifierMachine = ModifierOnlyShortcutMachine(key: key)
		logger.info("Installing modifier-only dictation shortcut for \(key.rawValue)")
		// keyDown is watched too: a key typed while the modifier is held makes it a combination
		modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
			[weak self] event in
			self?.handleModifierEvent(event)
		}
		modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
			[weak self] event in
			self?.handleModifierEvent(event)
			return event
		}
		let (fileModifiers, fileKeyCode) = parseShortcut(
			fileSelectionShortcut, fallback: ShortcutDefaults.fileSelection,
			defaultsKey: ShortcutDefaults.fileSelectionKey)
		installFileSelectionMonitors(modifiers: fileModifiers, keyCode: fileKeyCode)
		logger.info(
			"Modifier monitors installed - Global: \(modifierGlobalMonitor != nil), Local: \(modifierLocalMonitor != nil)")
	}

	private func removeModifierMonitors() {
		if let monitor = modifierGlobalMonitor {
			NSEvent.removeMonitor(monitor)
			modifierGlobalMonitor = nil
		}
		if let monitor = modifierLocalMonitor {
			NSEvent.removeMonitor(monitor)
			modifierLocalMonitor = nil
		}
		modifierMachine = nil
	}

	/// Monitors deliver on the main thread.
	private func handleModifierEvent(_ event: NSEvent) {
		guard let input = ModifierOnlyInput(event: event) else { return }
		MainActor.assumeIsolated { handleModifierInput(input, at: Date()) }
	}

	@MainActor
	private func handleModifierInput(_ input: ModifierOnlyInput, at: Date) {
		guard var machine = modifierMachine, let audioManager else { return }
		let steps = machine.handle(
			input, recorderListening: ShortcutRecorderGate.shared.isRecording,
			mode: RecordingControlSettings().activationMode, isSessionActive: audioManager.isSessionActive)
		modifierMachine = machine
		runModifierSteps(steps, at: at, on: audioManager)
	}

	@MainActor
	private func runModifierSteps(_ steps: [ModifierOnlyPressRouter.Step], at: Date, on audioManager: AudioManager) {
		for step in steps {
			switch step {
			case .keyDown:
				textKeyDown(isRepeat: false, source: .eventMonitor, at: at)
				modifierPressSession = audioManager.captureSessionID
			case .keyUp:
				textKeyUp(at: at)
				modifierPressSession = nil
			case .cancelSession:
				logger.info("Dictation key was part of a key combination; cancelling the recording it started")
				activation.reset()
				// Only this press's own capture: an earlier dictation still transcribing is kept
				if let session = modifierPressSession {
					audioManager.cancelCapture(sessionID: session)
				}
				modifierPressSession = nil
			case .scheduleStart(let press, let delay):
				Task { @MainActor [weak self] in
					try? await Task.sleep(for: .seconds(delay))
					guard let self, let audioManager = self.audioManager else { return }
					guard var machine = self.modifierMachine else { return }
					let steps = machine.startDelayElapsed(press: press, isSessionActive: audioManager.isSessionActive)
					self.modifierMachine = machine
					self.runModifierSteps(steps, at: at, on: audioManager)
				}
			}
		}
	}

	private func installFileSelectionMonitors(modifiers fileModifiers: NSEvent.ModifierFlags, keyCode fileKeyCode: UInt16) {
		fileSelectionGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
			[weak self] event in
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return }
			if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Global file selection shortcut detected (dedicated monitor)!")
				self?.handleFileSelectionHotKey()
			}
		}

		fileSelectionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
			[weak self] event in
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return event }
			if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Local file selection shortcut detected (dedicated monitor)!")
				self?.handleFileSelectionHotKey()
				return nil  // Consume the event
			}
			return event
		}
		logger.info(
			"File monitors installed - File Global: \(fileSelectionGlobalMonitor != nil), File Local: \(fileSelectionLocalMonitor != nil)"
		)
	}

	private func stopSecureInputFallback() {
		if Thread.isMainThread {
			MainActor.assumeIsolated { SecureInputMonitor.shared.stop() }
		} else {
			DispatchQueue.main.sync { MainActor.assumeIsolated { SecureInputMonitor.shared.stop() } }
		}
	}

	private func configureSecureInputFallback(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
		let spec = CarbonHotKeyMapping.spec(keyCode: keyCode, modifiers: modifiers)
		Task { @MainActor [weak self] in
			let monitor = SecureInputMonitor.shared
			monitor.configure(
				hotKeySpec: { spec },
				action: { [weak self] in
					self?.logger.info("Text shortcut detected through the secure input fallback")
					self?.handleTextHotKey(isRepeat: false, source: .secureInputFallback)
				},
				release: { [weak self] in
					self?.handleTextHotKeyRelease()
				})
			monitor.start()
		}
	}

	private func publishBackend(active: HotkeyBackend, message: String?) {
		activeBackend = active
		let requested = requestedBackend
		Task { @MainActor in
			KeyboardDiagnostics.shared.updateBackend(requested: requested, active: active, message: message)
		}
	}

	/// Resolves a stored shortcut, falling back to `fallback` when its key is unknown so a
	/// corrupt value never binds some unrelated key. The fallback is written back so every
	/// place that shows the shortcut shows the key that actually works, and the user is told.
	private func parseShortcut(
		_ shortcut: String, fallback: String, defaultsKey: String
	) -> (NSEvent.ModifierFlags, UInt16) {
		if let combo = ShortcutCombo(shortcut) {
			logger.debug("Parsed shortcut '\(shortcut)': keyCode=\(combo.keyCode), modifiers=\(combo.modifiers.rawValue)")
			return (combo.modifiers, combo.keyCode)
		}
		logger.error("Shortcut '\(shortcut)' names an unknown key, using \(fallback)")
		let combo = ShortcutCombo(fallback) ?? ShortcutCombo(modifiers: [.option, .command], keyCode: 15)
		// Deferred: the defaults observer would re-enter setup while it is still running
		DispatchQueue.main.async {
			UserDefaults.standard.set(fallback, forKey: defaultsKey)
			MainActor.assumeIsolated {
				AppNoticeCenter.shared.post(.shortcutReset(unreadable: shortcut, boundTo: fallback))
			}
		}
		return (combo.modifiers, combo.keyCode)
	}

	private func matchesShortcut(
		event: NSEvent, expectedModifiers: NSEvent.ModifierFlags, expectedKeyCode: UInt16
	) -> Bool {
		return event.modifierFlags.intersection([.command, .option, .control, .shift])
			== expectedModifiers && event.keyCode == expectedKeyCode
	}

	func requestAccessibilityPermissions() {
		logger.info("Requesting accessibility permissions...")
		let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
		let accessEnabled = AXIsProcessTrustedWithOptions(options)

		if accessEnabled {
			logger.info("Accessibility permissions granted, setting up shortcut")
			setupShortcut()
		} else {
			logger.info("Waiting for accessibility permissions...")
			logger.info(
				"Please go to System Settings > Privacy & Security > Accessibility and enable Whispera")
			logger.info("Global shortcuts will NOT work until accessibility permissions are granted")

			// Check again every 3 seconds for up to 30 seconds
			var checkCount = 0
			let maxChecks = 10

			func checkPermissions() {
				checkCount += 1
				if AXIsProcessTrusted() {
					self.logger.info(
						"Accessibility permissions now granted! Setting up global shortcuts...")
					self.setupShortcut()
				} else if checkCount < maxChecks {
					self.logger.info(
						"Still waiting for accessibility permissions... (\(checkCount)/\(maxChecks))")
					DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
						checkPermissions()
					}
				} else {
					self.logger.error(
						"Accessibility permissions still not granted. Global shortcuts disabled.")
					self.logger.error(
						"You can grant permissions later in System Settings > Privacy & Security > Accessibility"
					)
				}
			}

			DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
				checkPermissions()
			}
		}
	}

	private func handleTextHotKey(isRepeat: Bool, source: ShortcutSource = .eventMonitor) {
		let pressedAt = Date()
		Task { @MainActor in
			textKeyDown(isRepeat: isRepeat, source: source, at: pressedAt)
		}
	}

	private func handleTextHotKeyRelease() {
		let releasedAt = Date()
		Task { @MainActor in
			textKeyUp(at: releasedAt)
		}
	}

	@MainActor
	private func textKeyDown(isRepeat: Bool, source: ShortcutSource, at pressedAt: Date) {
		// The key press is being recorded as a new shortcut, not used as one
		guard !ShortcutRecorderGate.shared.isRecording else { return }
		if !isRepeat {
			KeyboardDiagnostics.shared.recordShortcut(.dictation, backend: activeBackend)
		}
		guard let audioManager else { return }
		let settings = RecordingControlSettings()
		activation.mode = settings.activationMode
		activation.holdThreshold = settings.holdThreshold
		let action = activation.keyDown(
			at: pressedAt, isRepeat: isRepeat, isSessionActive: audioManager.isSessionActive,
			source: source)
		perform(action, on: audioManager)
	}

	@MainActor
	private func textKeyUp(at releasedAt: Date) {
		guard let audioManager else { return }
		let action = activation.keyUp(
			at: releasedAt, isSessionActive: audioManager.isSessionActive)
		if action != .none {
			logger.info("Text shortcut released after hold; stopping recording")
		}
		perform(action, on: audioManager)
	}

	@MainActor
	private func perform(_ action: ActivationAction, on audioManager: AudioManager) {
		guard action != .none else { return }
		if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
			NSHapticFeedbackManager.defaultPerformer
				.perform(.levelChange, performanceTime: .now)
		}
		switch action {
		case .start:
			audioManager.startRecordingSession()
		case .stop:
			audioManager.requestStop()
		case .none:
			break
		}
	}

	private func handleFileSelectionHotKey() {
		let backend = activeBackend
		Task { @MainActor in
			KeyboardDiagnostics.shared.recordShortcut(.fileSelection, backend: backend)
			logger.info("File selection shortcut activated")

			// Prevent duplicate processing
			guard !isProcessingFileOperation else {
				logger.info("File operation already in progress, ignoring shortcut")
				return
			}

			isProcessingFileOperation = true
			defer { isProcessingFileOperation = false }

			// Check if haptic feedback is enabled
			if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
				NSHapticFeedbackManager.defaultPerformer
					.perform(.levelChange, performanceTime: .now)
			}

			// First, try to get selected files from Finder
			let finderSelection = await getFinderSelectedFiles()
			if !finderSelection.isEmpty {
				logger.info("Found \(finderSelection.count) selected files in Finder")
				await handleSelectedFiles(finderSelection)
				return
			}

			// Check if there's a URL in the clipboard
			let pasteboard = NSPasteboard.general
			if let clipboardString = pasteboard.string(forType: .string),
				let url = URL(string: clipboardString),
				url.scheme == "http" || url.scheme == "https"
			{
				logger.info("Found URL in clipboard: \(clipboardString)")
				await handleClipboardURL(url)
			} else {
				// Open file selection dialog as fallback
				await openFileSelectionDialog()
			}
		}
	}

	private func getFinderSelectedFiles() async -> [URL] {
		let script = """
			tell application "Finder"
			    set selectedItems to selection
			    set filePaths to {}
			    repeat with selectedItem in selectedItems
			        if class of selectedItem is document file then
			            set end of filePaths to POSIX path of (selectedItem as alias)
			        end if
			    end repeat
			    return filePaths
			end tell
			"""

		let appleScript = NSAppleScript(source: script)
		var error: NSDictionary?
		let result = appleScript?.executeAndReturnError(&error)

		if let error = error {
			let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
			switch errorCode {
			case -1751:
				logger.info("AppleScript: User canceled or no files selected in Finder")
			case -1743:
				logger.error("AppleScript: Finder is not running or accessible")
			case -1700:
				logger.error("AppleScript: Access denied to Finder")
			default:
				logger.error("AppleScript error: \(error)")
			}
			return []
		}

		if let result = result {
			// Handle the result - it might be a list or a single value
			let paths = extractPathsFromAppleScriptResult(result)
			let urls = paths.compactMap { path -> URL? in
				return URL(fileURLWithPath: path)
			}
			return urls.filter { url in
				let fileExtension = url.pathExtension.lowercased()
				return SupportedFileTypes.allFormats.contains(fileExtension)
			}
		}

		return []
	}

	private func extractPathsFromAppleScriptResult(_ result: NSAppleEventDescriptor) -> [String] {
		var paths: [String] = []

		// Check if it's a list
		if result.descriptorType == typeAEList {
			let listSize = result.numberOfItems
			// Guard against empty lists to avoid Range error
			guard listSize > 0 else { return paths }

			for i in 1...listSize {
				if let item = result.atIndex(i),
					let path = item.stringValue
				{
					paths.append(path)
				}
			}
		} else if let singlePath = result.stringValue {
			// Single item
			paths.append(singlePath)
		}

		return paths
	}

	@MainActor
	private func handleSelectedFiles(_ urls: [URL]) async {
		logger.info("Adding \(urls.count) selected audio files to transcription queue")

		guard let queueManager = queueManager else {
			logger.error("TranscriptionQueueManager not available, falling back to direct processing")
			await handleSelectedFilesDirectly(urls)
			return
		}

		// Add all files to the queue
		queueManager.addFiles(urls)
		logger.info("Added \(urls.count) files to transcription queue")

		// Show a notification that files were added to queue
		let notification = NSUserNotification()
		notification.title = String(localized: "Files Added to Queue")
		notification.subtitle = "\(urls.count) file(s) queued for transcription"
		notification.informativeText = urls.map { $0.lastPathComponent }.joined(separator: ", ")
		NSUserNotificationCenter.default.deliver(notification)
	}

	@MainActor
	private func handleSelectedFilesDirectly(_ urls: [URL]) async {
		logger.info("Processing \(urls.count) selected audio files directly")

		guard let fileManager = fileTranscriptionManager else {
			logger.error("FileTranscriptionManager not available")
			return
		}

		// For now, we'll process the first file (can be enhanced for multiple files)
		guard let firstFile = urls.first else { return }

		do {
			logger.info("Starting transcription for: \(firstFile.lastPathComponent)")

			let result = try await fileManager.transcribeFile(at: firstFile)

			// Show the result in a notification or window
			await showTranscriptionResult(for: firstFile.lastPathComponent, result: result)

		} catch {
			logger.error("Transcription failed: \(error)")
			showTranscriptionError(error)
		}
	}

	@MainActor
	private func showTranscriptionResult(for filename: String, result: String) async {
		// Create a simple notification for now
		let notification = NSUserNotification()
		notification.title = String(localized: "Transcription Complete")
		notification.subtitle = filename
		notification.informativeText = String(result.prefix(100)) + (result.count > 100 ? "..." : "")

		NSUserNotificationCenter.default.deliver(notification)

		// Also copy to clipboard
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(result, forType: .string)

		// Save to file
		await saveTranscriptionToFile(result, originalFilename: filename)
	}

	private func saveTranscriptionToFile(_ transcription: String, originalFilename: String) async {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let timestamp = formatter.string(from: Date())

		let sanitizedOriginalName =
			originalFilename
			.replacingOccurrences(of: ".", with: "_")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: ":", with: "_")

		let transcriptionFilename = "transcription_\(sanitizedOriginalName)_\(timestamp).txt"

		// Get the user's Desktop directory
		let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
		let fileURL = desktopURL.appendingPathComponent(transcriptionFilename)

		do {
			try transcription.write(to: fileURL, atomically: true, encoding: .utf8)
			logger.info("Transcription saved to: \(fileURL.path)")
		} catch {
			logger.error("Failed to save transcription to file: \(error.localizedDescription)")
		}
	}

	@MainActor
	private func showTranscriptionError(_ error: Error) {
		let notification = NSUserNotification()
		notification.title = String(localized: "Transcription Failed")
		notification.informativeText = error.localizedDescription

		NSUserNotificationCenter.default.deliver(notification)
	}

	@MainActor
	private func openFileSelectionDialog() async {
		logger.info("Opening file selection dialog")
		let openPanel = NSOpenPanel()
		openPanel.title = String(localized: "Select Audio or Video Files to Transcribe")
		openPanel.message = String(localized: "Choose audio or video files for transcription")
		openPanel.allowsMultipleSelection = true
		openPanel.canChooseDirectories = false
		openPanel.canChooseFiles = true

		openPanel.allowedContentTypes = [
			.audio,
			.video,
			.mp3,
			.mpeg4Audio,
			.wav,
			.aiff,
			.movie,
			.quickTimeMovie,
			.avi,
		]

		let response = openPanel.runModal()

		if response == .OK {
			let selectedURLs = openPanel.urls
			logger.info(
				"Selected \(selectedURLs.count) file(s): \(selectedURLs.map { $0.lastPathComponent })")

			guard let queueManager = queueManager else {
				logger.error("TranscriptionQueueManager not available, falling back to direct processing")
				await processFilesDirectly(selectedURLs)
				return
			}

			// Add files to queue
			queueManager.addFiles(selectedURLs)
			logger.info("Added \(selectedURLs.count) files to transcription queue")

			// Show notification
			let notification = NSUserNotification()
			notification.title = String(localized: "Files Added to Queue")
			notification.subtitle = "\(selectedURLs.count) file(s) queued for transcription"
			notification.informativeText = selectedURLs.map { $0.lastPathComponent }.joined(
				separator: ", ")
			NSUserNotificationCenter.default.deliver(notification)
		} else {
			logger.info("File selection cancelled")
		}
	}

	@MainActor
	private func processFilesDirectly(_ urls: [URL]) async {
		guard let fileManager = fileTranscriptionManager else {
			logger.error("FileTranscriptionManager not available")
			return
		}

		// Transcribe selected files directly
		do {
			if urls.count == 1 {
				let result = try await fileManager.transcribeFile(at: urls[0])
				logger.userText("Transcription completed", result)

				// Copy result to clipboard
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				pasteboard.setString(result, forType: .string)
				logger.info("Result copied to clipboard")
			} else {
				let results = try await fileManager.transcribeFiles(at: urls)
				let combinedResult = results.enumerated().map { index, result in
					"File \(index + 1) (\(urls[index].lastPathComponent)):\n\(result)"
				}.joined(separator: "\n\n")

				logger.info("Batch transcription completed")

				// Copy combined results to clipboard
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				pasteboard.setString(combinedResult, forType: .string)
				logger.info("Combined results copied to clipboard")
			}
		} catch {
			logger.error("Transcription failed: \(error.localizedDescription)")
		}
	}

	@MainActor
	private func handleClipboardURL(_ url: URL) async {
		logger.info("Adding clipboard URL to transcription queue: \(url.absoluteString)")

		guard let queueManager = queueManager else {
			logger.error("TranscriptionQueueManager not available, falling back to direct processing")
			await handleClipboardURLDirectly(url)
			return
		}

		// Add URL to queue
		queueManager.addFile(url)
		logger.info("Added URL to transcription queue")

		// Show notification
		let notification = NSUserNotification()
		notification.title = String(localized: "URL Added to Queue")
		notification.subtitle = "Network file queued for transcription"
		notification.informativeText = url.absoluteString
		NSUserNotificationCenter.default.deliver(notification)
	}

	private func handleClipboardURLDirectly(_ url: URL) async {
		logger.info("Processing clipboard URL directly: \(url.absoluteString)")

		guard let fileManager = fileTranscriptionManager,
			let downloader = networkDownloader
		else {
			logger.error("FileTranscriptionManager or NetworkFileDownloader not available")
			return
		}

		do {
			// Check if it's a YouTube URL
			if isYouTubeURL(url) {
				logger.info("Detected YouTube URL, using YouTube transcription manager")
				let youtubeManager = await YouTubeTranscriptionManager(
					fileTranscriptionManager: fileManager,
					networkDownloader: downloader
				)
				let result = try await youtubeManager.transcribeYouTubeURL(url)

				// Show the result
				await showTranscriptionResult(for: "YouTube Video", result: result)

			} else {
				// Handle as regular network file
				let result: String =
					try await downloader.downloadAndTranscribe(
						from: url,
						using: fileManager,
						withTimestamps: false,
						deleteAfterTranscription: autoDeleteDownloadedFiles
					) as! String

				let filename = url.lastPathComponent.isEmpty ? "Network File" : url.lastPathComponent
				await showTranscriptionResult(for: filename, result: result)
			}

			logger.info("URL transcription completed")

		} catch {
			logger.error("URL transcription failed: \(error.localizedDescription)")
			await showTranscriptionError(error)
		}
	}

	private func isYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
			|| host == "m.youtube.com"
	}

	deinit {
		if let recordingStateObserver {
			NotificationCenter.default.removeObserver(recordingStateObserver)
		}
		CarbonHotKeyCenter.shared.unregisterAll()
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = fileSelectionGlobalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = fileSelectionLocalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = modifierGlobalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = modifierLocalMonitor {
			NSEvent.removeMonitor(monitor)
		}
	}
}
