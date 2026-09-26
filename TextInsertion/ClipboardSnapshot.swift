import AppKit

struct ClipboardSnapshot: Equatable {
	struct Representation: Equatable {
		let type: NSPasteboard.PasteboardType
		let data: Data
	}

	/// What a capture found. Only `.captured` is ever written back.
	enum Capture: Equatable {
		case captured(ClipboardSnapshot)
		/// A password manager or another tool marked the content concealed or transient, so it
		/// must not be republished as a fresh clipboard entry that outlives its auto-clear.
		case sensitive
		/// Too large to hold in memory for a paste; the clipboard is left with the transcript.
		case tooLarge
	}

	struct Limits: Equatable, Sendable {
		var maxRepresentationBytes = 16 * 1024 * 1024
		var maxTotalBytes = 32 * 1024 * 1024
	}

	static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

	/// Promised and dynamic flavors make the owning app render or export on demand, which can
	/// take seconds, so they are never read for a snapshot.
	static func isSkippedType(_ type: NSPasteboard.PasteboardType) -> Bool {
		let raw = type.rawValue
		return raw.hasPrefix("dyn.") || raw.hasPrefix("com.apple.pasteboard.promised")
			|| raw.contains("NSFilePromise") || raw == "NSPromiseContentsPboardType"
			|| raw == "com.apple.NSFilePromiseItemMetaData"
	}

	static func isSensitive(types: [NSPasteboard.PasteboardType]) -> Bool {
		types.contains(concealedType) || types.contains(ClipboardWriter.transientType)
	}

	let items: [[Representation]]

	var isEmpty: Bool { items.isEmpty }

	var byteCount: Int {
		items.reduce(0) { total, item in total + item.reduce(0) { $0 + $1.data.count } }
	}

	static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
		if case .captured(let snapshot) = inspect(pasteboard) { return snapshot }
		return ClipboardSnapshot(items: [])
	}

	static func inspect(_ pasteboard: NSPasteboard, limits: Limits = Limits()) -> Capture {
		let pasteboardItems = pasteboard.pasteboardItems ?? []
		if pasteboardItems.contains(where: { isSensitive(types: $0.types) }) {
			return .sensitive
		}
		var total = 0
		var items: [[Representation]] = []
		for item in pasteboardItems {
			var representations: [Representation] = []
			for type in item.types where !isSkippedType(type) {
				guard let data = item.data(forType: type) else { continue }
				total += data.count
				if data.count > limits.maxRepresentationBytes || total > limits.maxTotalBytes {
					return .tooLarge
				}
				representations.append(Representation(type: type, data: data))
			}
			if !representations.isEmpty { items.append(representations) }
		}
		return .captured(ClipboardSnapshot(items: items))
	}

	/// Reading every flavor can block while other apps produce their data, so it runs off the
	/// main actor. NSPasteboard is documented as safe to use from any thread.
	static func inspectInBackground(_ pasteboard: NSPasteboard, limits: Limits = Limits()) async -> Capture {
		let box = UncheckedPasteboard(pasteboard: pasteboard)
		return await Task.detached(priority: .userInitiated) {
			inspect(box.pasteboard, limits: limits)
		}.value
	}

	func restore(to pasteboard: NSPasteboard) {
		pasteboard.clearContents()
		guard !items.isEmpty else { return }
		let pasteboardItems = items.map { representations -> NSPasteboardItem in
			let item = NSPasteboardItem()
			for representation in representations {
				item.setData(representation.data, forType: representation.type)
			}
			return item
		}
		pasteboard.writeObjects(pasteboardItems)
	}
}

private struct UncheckedPasteboard: @unchecked Sendable {
	let pasteboard: NSPasteboard
}

/// Serves the transcript lazily so Whispera learns when the target app actually reads it, and
/// restores the previous clipboard only after that instead of after a fixed guess.
final class PasteReadReceipt: NSObject, NSPasteboardItemDataProvider {
	private let text: String
	private(set) var readCount = 0
	private var waiters: [CheckedContinuation<Void, Never>] = []

	init(text: String) {
		self.text = text
	}

	var wasRead: Bool { readCount > 0 }

	func pasteboard(
		_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
	) {
		item.setString(text, forType: type)
		readCount += 1
		let pending = waiters
		waiters.removeAll()
		pending.forEach { $0.resume() }
	}

	func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

	/// Returns true once the data was read, false when `timeoutMs` passes first.
	@MainActor
	func waitForRead(timeoutMs: Int) async -> Bool {
		if wasRead { return true }
		let timeout = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 0)) * 1_000_000)
			self?.resumeWaiters()
		}
		await withCheckedContinuation { continuation in
			if wasRead {
				continuation.resume()
			} else {
				waiters.append(continuation)
			}
		}
		timeout.cancel()
		return wasRead
	}

	private func resumeWaiters() {
		let pending = waiters
		waiters.removeAll()
		pending.forEach { $0.resume() }
	}
}

enum ClipboardWriter {
	// nspasteboard.org markers: clipboard managers skip transient, auto-generated content
	static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
	static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

	@discardableResult
	static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) -> Int {
		pasteboard.clearContents()
		let item = NSPasteboardItem()
		item.setString(text, forType: .string)
		if transient {
			item.setData(Data(), forType: transientType)
			item.setData(Data(), forType: autoGeneratedType)
		}
		pasteboard.writeObjects([item])
		return pasteboard.changeCount
	}

	/// Writes the transcript through `receipt` so the first read can be observed.
	@discardableResult
	static func write(_ receipt: PasteReadReceipt, to pasteboard: NSPasteboard, transient: Bool) -> Int {
		pasteboard.clearContents()
		let item = NSPasteboardItem()
		item.setDataProvider(receipt, forTypes: [.string])
		if transient {
			item.setData(Data(), forType: transientType)
			item.setData(Data(), forType: autoGeneratedType)
		}
		pasteboard.writeObjects([item])
		return pasteboard.changeCount
	}

	static func shouldRestore(currentChangeCount: Int, changeCountAfterWrite: Int) -> Bool {
		currentChangeCount == changeCountAfterWrite
	}
}
