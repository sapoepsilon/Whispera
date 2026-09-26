import AppKit
import CoreGraphics

protocol KeyEventPosting {
	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
	func postUnicode(_ units: [UniChar])
}

struct CGKeyEventPoster: KeyEventPosting {
	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		let source = CGEventSource(stateID: .combinedSessionState)
		let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
		let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
		keyDown?.flags = flags
		keyUp?.flags = flags
		keyDown?.post(tap: .cghidEventTap)
		keyUp?.post(tap: .cghidEventTap)
	}

	func postUnicode(_ units: [UniChar]) {
		let source = CGEventSource(stateID: .combinedSessionState)
		let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
		let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
		// Cleared so a still-held hotkey modifier does not turn typed letters into shortcuts
		keyDown?.flags = []
		keyUp?.flags = []
		keyDown?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
		keyUp?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
		keyDown?.post(tap: .cghidEventTap)
		keyUp?.post(tap: .cghidEventTap)
	}
}

enum KeyCode {
	static let v: CGKeyCode = 0x09
	static let returnKey: CGKeyCode = 0x24
}

@MainActor
final class TextInserter {
	static let shared = TextInserter()

	private let pasteboard: NSPasteboard
	private let settingsProvider: () -> TextInsertionSettings
	private let keyPoster: KeyEventPosting
	private let logger = AppLogger.shared.general
	private let typingStepDelayMs = 4
	private let autoSubmitDelayMs = 50
	/// Upper bound on waiting for the target app to read the transcript before restoring.
	private let readTimeoutMs: Int
	private var pendingInsertion: Task<Void, Never>?

	static let defaultReadTimeoutMs = 1500

	init(
		pasteboard: NSPasteboard = .general,
		keyPoster: KeyEventPosting = CGKeyEventPoster(),
		readTimeoutMs: Int = TextInserter.defaultReadTimeoutMs,
		settingsProvider: @escaping () -> TextInsertionSettings = { .current }
	) {
		self.pasteboard = pasteboard
		self.keyPoster = keyPoster
		self.readTimeoutMs = readTimeoutMs
		self.settingsProvider = settingsProvider
	}

	// Serialized so a live segment never restores the clipboard under the next segment's paste
	@discardableResult
	func insert(_ text: String, context: InsertionContext) -> Task<Void, Never> {
		let previous = pendingInsertion
		let task = Task { @MainActor [weak self] in
			await previous?.value
			await self?.perform(text, context: context)
		}
		pendingInsertion = task
		return task
	}

	/// Live dictation types segment by segment, so auto-submit fires once when the session
	/// ends, queued behind the session's last segment.
	@discardableResult
	func submitAfterLiveSession() -> Task<Void, Never> {
		let previous = pendingInsertion
		let task = Task { @MainActor [weak self] in
			await previous?.value
			guard let self else { return }
			let settings = self.settingsProvider()
			guard settings.shouldAutoSubmitAfterLiveSession else { return }
			await self.sleep(milliseconds: self.autoSubmitDelayMs)
			self.keyPoster.postKey(KeyCode.returnKey, flags: settings.autoSubmitKey.flags)
		}
		pendingInsertion = task
		return task
	}

	private func perform(_ rawText: String, context: InsertionContext) async {
		guard !rawText.isEmpty else { return }
		let settings = settingsProvider()
		let text = settings.preparedText(rawText, for: context)
		let method = settings.effectiveMethod(for: context)
		var inserted = true

		switch method {
		case .commandV:
			await pasteViaClipboard(text, settings: settings)
		case .typeCharacters:
			await typeCharacters(text)
		case .copyOnly:
			ClipboardWriter.write(text, to: pasteboard, transient: false)
		case .externalScript:
			inserted = await runScript(text, settings: settings)
		}

		if context == .finalTranscript, settings.clipboardHandling == .keepTranscript,
			method == .typeCharacters || method == .externalScript
		{
			ClipboardWriter.write(text, to: pasteboard, transient: false)
		}

		if inserted, settings.shouldAutoSubmit(for: context) {
			await sleep(milliseconds: autoSubmitDelayMs)
			keyPoster.postKey(KeyCode.returnKey, flags: settings.autoSubmitKey.flags)
		}
	}

	private func typeCharacters(_ text: String) async {
		for step in TypingPlan.steps(for: text) {
			switch step {
			case .text(let units):
				keyPoster.postUnicode(units)
			}
			await sleep(milliseconds: typingStepDelayMs)
		}
	}

	private func runScript(_ text: String, settings: TextInsertionSettings) async -> Bool {
		do {
			try await ExternalScriptRunner.run(path: settings.externalScriptPath, text: text)
			logger.info("Insertion script finished for a \(text.count)-character transcript")
			return true
		} catch {
			// Keep the words recoverable when the script cannot deliver them
			ClipboardWriter.write(text, to: pasteboard, transient: false)
			logger.error(
				"Insertion script failed, transcript copied to clipboard: \(error.localizedDescription)")
			return false
		}
	}

	private func pasteViaClipboard(_ text: String, settings: TextInsertionSettings) async {
		let restoreClipboard = settings.clipboardHandling == .restore
		let capture = restoreClipboard ? await ClipboardSnapshot.inspectInBackground(pasteboard) : nil
		let receipt = PasteReadReceipt(text: text)
		let changeCountAfterWrite = ClipboardWriter.write(
			receipt, to: pasteboard, transient: restoreClipboard)

		await sleep(milliseconds: settings.pasteDelayBeforeMs)
		keyPoster.postKey(KeyCode.v, flags: .maskCommand)
		guard let capture else { return }

		// Apps read the pasteboard asynchronously after Cmd-V, Electron and remote desktops often
		// well past 100 ms, so restoring on a timer can paste the old clipboard instead.
		let wasRead = await receipt.waitForRead(timeoutMs: max(readTimeoutMs, settings.pasteDelayAfterMs))
		await sleep(milliseconds: settings.pasteDelayAfterMs)
		if !wasRead {
			logger.info("No app read the transcript within \(readTimeoutMs) ms of Cmd-V")
		}

		guard
			ClipboardWriter.shouldRestore(
				currentChangeCount: pasteboard.changeCount, changeCountAfterWrite: changeCountAfterWrite)
		else {
			logger.info("Clipboard changed during paste; leaving the newer content in place")
			return
		}
		switch capture {
		case .captured(let snapshot):
			snapshot.restore(to: pasteboard)
			logger.debug("Restored clipboard (\(snapshot.items.count) item(s)) after paste")
		case .sensitive:
			pasteboard.clearContents()
			logger.info("Previous clipboard was concealed or transient; cleared instead of restoring it")
		case .tooLarge:
			logger.info("Previous clipboard was too large to snapshot; leaving the transcript in place")
		}
	}

	private func sleep(milliseconds: Int) async {
		guard milliseconds > 0 else { return }
		try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
	}
}
