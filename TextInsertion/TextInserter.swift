import AppKit
import ApplicationServices
import CoreGraphics

protocol KeyEventPosting {
	/// Without Accessibility access `CGEvent.post` is a silent no-op, so nothing typed or pasted
	/// would arrive and nothing would say so.
	var canPostEvents: Bool { get }
	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
	func postUnicode(_ units: [UniChar])
}

extension KeyEventPosting {
	var canPostEvents: Bool { true }
}

struct CGKeyEventPoster: KeyEventPosting {
	var canPostEvents: Bool { AXIsProcessTrusted() }

	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		let source = CGEventSource(stateID: .combinedSessionState)
		let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
		let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
		keyDown?.flags = flags
		keyUp?.flags = flags
		keyDown?.post(tap: .cghidEventTap)
		keyUp?.post(tap: .cghidEventTap)
		// A key-up that still carries Command leaves the session believing Command is held, so
		// the next mouse click became a Cmd-click (a menu-bar icon then starts a rearrange drag
		// instead of opening its menu) until the user pressed and released Command.
		for modifier in Self.modifierKeyCodes(in: flags) {
			let release = CGEvent(keyboardEventSource: source, virtualKey: modifier, keyDown: false)
			release?.flags = []
			release?.post(tap: .cghidEventTap)
		}
	}

	static func modifierKeyCodes(in flags: CGEventFlags) -> [CGKeyCode] {
		var codes: [CGKeyCode] = []
		if flags.contains(.maskCommand) { codes.append(KeyCode.command) }
		if flags.contains(.maskShift) { codes.append(KeyCode.shift) }
		if flags.contains(.maskAlternate) { codes.append(KeyCode.option) }
		if flags.contains(.maskControl) { codes.append(KeyCode.control) }
		return codes
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
	static let command: CGKeyCode = 0x37
	static let shift: CGKeyCode = 0x38
	static let option: CGKeyCode = 0x3A
	static let control: CGKeyCode = 0x3B
}

/// Why a transcript did not reach the focused app, so the user hears about it instead of the
/// words silently disappearing.
enum InsertionProblem: Equatable, Sendable {
	case accessibilityDenied(transcriptOnClipboard: Bool)
	/// Cmd-V was sent but no app read the transcript.
	case notPasted(transcriptOnClipboard: Bool)

	var message: String {
		switch self {
		case .accessibilityDenied(true):
			return String(
				localized:
					"Whispera couldn't paste because Accessibility access is off. The transcript is on the clipboard. Turn Whispera on in System Settings > Privacy & Security > Accessibility."
			)
		case .accessibilityDenied(false):
			return String(
				localized:
					"Whispera couldn't type because Accessibility access is off. Turn Whispera on in System Settings > Privacy & Security > Accessibility."
			)
		case .notPasted(true):
			return String(
				localized:
					"No app took the paste, so the transcript was left on the clipboard. Click where the text should go and press Cmd-V."
			)
		case .notPasted(false):
			return String(
				localized:
					"No app took the paste. Secure Input was on, so the text was not kept on the clipboard."
			)
		}
	}
}

@MainActor
final class TextInserter {
	static let shared = TextInserter()

	private let pasteboard: NSPasteboard
	private let settingsProvider: () -> TextInsertionSettings
	private let keyPoster: KeyEventPosting
	private let isSecureInputActive: () -> Bool
	private let logger = AppLogger.shared.general
	private let typingStepDelayMs = 4
	private let autoSubmitDelayMs = 50
	/// Upper bound on waiting for the target app to read the transcript before restoring.
	private let readTimeoutMs: Int
	private let captureDeadlineMs: Int
	private var pendingInsertion: Task<Void, Never>?
	/// Called on the main actor when a transcript could not be delivered.
	var onProblem: ((InsertionProblem) -> Void)?
	/// Awaited before keystrokes are posted, so Whispera's own menu-bar popover can close and
	/// hand focus back; with it open the Cmd-V went to the popover and the transcript was lost.
	var prepareForKeystrokes: (@MainActor () async -> Void)?

	static let defaultReadTimeoutMs = 1500

	init(
		pasteboard: NSPasteboard = .general,
		keyPoster: KeyEventPosting = CGKeyEventPoster(),
		readTimeoutMs: Int = TextInserter.defaultReadTimeoutMs,
		captureDeadlineMs: Int = ClipboardSnapshot.defaultCaptureDeadlineMs,
		isSecureInputActive: @escaping () -> Bool = { SecureDictation.isSecureInputActive },
		settingsProvider: @escaping () -> TextInsertionSettings = { .current }
	) {
		self.pasteboard = pasteboard
		self.keyPoster = keyPoster
		self.isSecureInputActive = isSecureInputActive
		self.readTimeoutMs = readTimeoutMs
		self.captureDeadlineMs = captureDeadlineMs
		self.settingsProvider = settingsProvider
	}

	// Serialized so a live segment never restores the clipboard under the next segment's paste
	@discardableResult
	func insert(_ text: String, context: InsertionContext, concealed: Bool = false) -> Task<Void, Never> {
		let previous = pendingInsertion
		let task = Task { @MainActor [weak self] in
			await previous?.value
			await self?.perform(text, context: context, concealed: concealed)
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
			guard settings.shouldAutoSubmitAfterLiveSession, self.keyPoster.canPostEvents else { return }
			await self.sleep(milliseconds: self.autoSubmitDelayMs)
			self.keyPoster.postKey(KeyCode.returnKey, flags: settings.autoSubmitKey.flags)
		}
		pendingInsertion = task
		return task
	}

	private func perform(_ rawText: String, context: InsertionContext, concealed: Bool) async {
		guard !rawText.isEmpty else { return }
		let settings = settingsProvider()
		let text = settings.preparedText(rawText, for: context)
		let method = settings.effectiveMethod(for: context)
		// Checked again here because live segments reach the inserter without going through the
		// dictation's own secure-input check
		let concealed = concealed || isSecureInputActive()
		var inserted = true

		if method == .commandV || method == .typeCharacters, !keyPoster.canPostEvents {
			// Live segments are all in history; one segment alone on the clipboard would mislead.
			// A secret is never left behind, even to rescue it.
			let copied = context == .finalTranscript && !concealed
			if copied {
				ClipboardWriter.write(text, to: pasteboard, transient: false)
			}
			logger.error("Accessibility access is off; cannot post keystrokes, transcript copied: \(copied)")
			onProblem?(.accessibilityDenied(transcriptOnClipboard: copied))
			return
		}

		if method == .commandV || method == .typeCharacters {
			await prepareForKeystrokes?()
		}

		switch method {
		case .commandV:
			inserted = await pasteViaClipboard(
				text, settings: settings, concealed: concealed,
				confirmRead: settings.shouldAutoSubmit(for: context))
		case .typeCharacters:
			await typeCharacters(text)
		case .copyOnly:
			ClipboardWriter.write(text, to: pasteboard, transient: false, concealed: concealed)
		case .externalScript:
			inserted = await runScript(text, settings: settings, concealed: concealed)
		}

		// A secret typed into a password field is not left behind on the clipboard
		if context == .finalTranscript, settings.clipboardHandling == .keepTranscript, !concealed,
			method == .typeCharacters || method == .externalScript
		{
			ClipboardWriter.write(text, to: pasteboard, transient: false)
		}

		// Return pressed after a paste nobody took would submit whatever app is now in front
		if inserted, settings.shouldAutoSubmit(for: context), keyPoster.canPostEvents {
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

	private func runScript(_ text: String, settings: TextInsertionSettings, concealed: Bool) async -> Bool {
		do {
			try await ExternalScriptRunner.run(
				path: settings.externalScriptPath, approval: settings.externalScriptApproval, text: text)
			logger.info("Insertion script finished for a \(text.count)-character transcript")
			return true
		} catch {
			// Keep the words recoverable when the script cannot deliver them
			ClipboardWriter.write(text, to: pasteboard, transient: false, concealed: concealed)
			logger.error(
				"Insertion script failed, transcript copied to clipboard: \(error.localizedDescription)")
			return false
		}
	}

	/// Returns whether the target app read the transcript. `confirmRead` makes the "keep
	/// transcript" mode wait for that too, because auto-submit must not press Return blind.
	private func pasteViaClipboard(
		_ text: String, settings: TextInsertionSettings, concealed: Bool, confirmRead: Bool
	) async -> Bool {
		let restoreClipboard = settings.clipboardHandling == .restore
		let capture =
			restoreClipboard
			? await ClipboardSnapshot.inspectInBackground(pasteboard, deadlineMs: captureDeadlineMs) : nil
		let receipt = PasteReadReceipt(text: text)
		let changeCountAfterWrite = ClipboardWriter.write(
			receipt, to: pasteboard, transient: restoreClipboard, concealed: concealed)

		await sleep(milliseconds: settings.pasteDelayBeforeMs)
		keyPoster.postKey(KeyCode.v, flags: .maskCommand)
		let pastedAt = ContinuousClock.now
		guard let capture else {
			if concealed {
				// "Keep transcript" never applies to a secret: take it back once the app has read it
				let wasRead = await holdAfterPaste(since: pastedAt, receipt: receipt, settings: settings)
				if pasteboard.changeCount == changeCountAfterWrite {
					pasteboard.clearContents()
				}
				if !wasRead { onProblem?(.notPasted(transcriptOnClipboard: false)) }
				return wasRead
			}
			guard confirmRead else { return true }
			let wasRead = await receipt.waitForRead(timeoutMs: max(readTimeoutMs, settings.pasteDelayAfterMs))
			if !wasRead { onProblem?(.notPasted(transcriptOnClipboard: true)) }
			return wasRead
		}

		let wasRead = await holdAfterPaste(since: pastedAt, receipt: receipt, settings: settings)

		guard
			ClipboardWriter.shouldRestore(
				currentChangeCount: pasteboard.changeCount, changeCountAfterWrite: changeCountAfterWrite)
		else {
			logger.info("Clipboard changed during paste; leaving the newer content in place")
			return wasRead
		}
		if !wasRead {
			if concealed {
				restorePrevious(capture)
				onProblem?(.notPasted(transcriptOnClipboard: false))
			} else {
				// Restoring now would leave the transcript nowhere but history
				ClipboardWriter.write(text, to: pasteboard, transient: false)
				logger.info("Nothing read the transcript; leaving it on the clipboard instead of restoring")
				onProblem?(.notPasted(transcriptOnClipboard: true))
			}
			return false
		}
		restorePrevious(capture)
		return true
	}

	private func restorePrevious(_ capture: ClipboardSnapshot.Capture) {
		switch capture {
		case .captured(let snapshot):
			snapshot.restore(to: pasteboard)
			logger.debug("Restored clipboard (\(snapshot.items.count) item(s)) after paste")
		case .sensitive:
			pasteboard.clearContents()
			logger.info("Previous clipboard was concealed or transient; cleared instead of restoring it")
		case .tooLarge:
			logger.info("Previous clipboard was too large to snapshot; leaving the transcript in place")
		case .timedOut:
			logger.info("Previous clipboard did not answer in time; leaving the transcript in place")
		}
	}

	/// Apps read the pasteboard asynchronously after Cmd-V, Electron and remote desktops often
	/// well past 100 ms. A read receipt alone cannot tell the target app apart from a clipboard
	/// watcher that read the transcript before Cmd-V was even posted, so restoring waits for both
	/// a read and a minimum hold measured from Cmd-V.
	@discardableResult
	private func holdAfterPaste(
		since pastedAt: ContinuousClock.Instant, receipt: PasteReadReceipt, settings: TextInsertionSettings
	) async -> Bool {
		let wasRead = await receipt.waitForRead(timeoutMs: max(readTimeoutMs, settings.pasteDelayAfterMs))
		await sleep(milliseconds: settings.pasteDelayAfterMs)
		if !wasRead {
			logger.info("No app read the transcript within \(readTimeoutMs) ms of Cmd-V")
		}
		let hold = Duration.milliseconds(TextInsertionSettings.clampedHold(settings.clipboardRestoreHoldMs))
		let remaining = pastedAt + hold - ContinuousClock.now
		if remaining > .zero {
			try? await Task.sleep(for: remaining)
		}
		return wasRead
	}

	private func sleep(milliseconds: Int) async {
		guard milliseconds > 0 else { return }
		try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
	}
}
