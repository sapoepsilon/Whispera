import AppKit
import CoreGraphics

protocol KeyEventPosting {
	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
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
	private var pendingInsertion: Task<Void, Never>?

	init(
		pasteboard: NSPasteboard = .general,
		keyPoster: KeyEventPosting = CGKeyEventPoster(),
		settingsProvider: @escaping () -> TextInsertionSettings = { .current }
	) {
		self.pasteboard = pasteboard
		self.keyPoster = keyPoster
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

	private func perform(_ text: String, context: InsertionContext) async {
		guard !text.isEmpty else { return }
		let settings = settingsProvider()
		await pasteViaClipboard(text, settings: settings)
	}

	private func pasteViaClipboard(_ text: String, settings: TextInsertionSettings) async {
		let restoreClipboard = settings.clipboardHandling == .restore
		let snapshot = restoreClipboard ? ClipboardSnapshot.capture(from: pasteboard) : nil
		let changeCountAfterWrite = ClipboardWriter.write(
			text, to: pasteboard, transient: restoreClipboard)

		await sleep(milliseconds: settings.pasteDelayBeforeMs)
		keyPoster.postKey(KeyCode.v, flags: .maskCommand)
		await sleep(milliseconds: settings.pasteDelayAfterMs)

		guard let snapshot else { return }
		if ClipboardWriter.shouldRestore(
			currentChangeCount: pasteboard.changeCount, changeCountAfterWrite: changeCountAfterWrite)
		{
			snapshot.restore(to: pasteboard)
			logger.debug("Restored clipboard (\(snapshot.items.count) item(s)) after paste")
		} else {
			logger.info("Clipboard changed during paste; leaving the newer content in place")
		}
	}

	private func sleep(milliseconds: Int) async {
		guard milliseconds > 0 else { return }
		try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
	}
}
