import AppKit
import Carbon.HIToolbox

enum HotkeyBackend: String, CaseIterable, Identifiable, Sendable {
	/// NSEvent global and local monitors: needs Accessibility, sees the key but cannot stop
	/// it from also reaching the frontmost app.
	case eventMonitor
	/// Carbon RegisterEventHotKey: no Accessibility needed, swallows the key so the front app
	/// never receives it, but cannot bind Fn/Globe.
	case carbon

	static let defaultsKey = "hotkeyBackend"

	var id: String { rawValue }

	var title: String {
		switch self {
		case .eventMonitor: return String(localized: "Event monitor")
		case .carbon: return String(localized: "System hotkey")
		}
	}

	var summary: String {
		switch self {
		case .eventMonitor:
			return String(
				localized: "Default. Needs Accessibility. The shortcut also reaches the app you are typing in.")
		case .carbon:
			return String(
				localized:
					"Registers the dictation shortcut as a system hotkey, so the front app never sees it. Fn/Globe cannot be used. The file shortcut is still only observed, so it keeps working in other apps."
			)
		}
	}

	static func preferred(in defaults: UserDefaults = .standard) -> HotkeyBackend {
		defaults.string(forKey: defaultsKey).flatMap(HotkeyBackend.init(rawValue:)) ?? .eventMonitor
	}
}

struct CarbonHotKeySpec: Equatable, Sendable {
	let keyCode: UInt32
	let modifiers: UInt32
}

enum CarbonHotKeyMapping {
	static let functionKeyCode: UInt16 = 63

	static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
		var modifiers: UInt32 = 0
		if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
		if flags.contains(.option) { modifiers |= UInt32(optionKey) }
		if flags.contains(.control) { modifiers |= UInt32(controlKey) }
		if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
		return modifiers
	}

	static func isSupported(keyCode: UInt16) -> Bool {
		keyCode != functionKeyCode
	}

	// Carbon cannot register the Globe/Fn key, so that shortcut has no Carbon equivalent
	static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CarbonHotKeySpec? {
		guard isSupported(keyCode: keyCode) else { return nil }
		return CarbonHotKeySpec(keyCode: UInt32(keyCode), modifiers: carbonModifiers(from: modifiers))
	}
}

enum CarbonHotKeyError: LocalizedError, Equatable {
	case unsupportedKey
	case alreadyTaken
	case failed(OSStatus)

	var errorDescription: String? {
		switch self {
		case .unsupportedKey: return String(localized: "Fn/Globe shortcuts cannot be registered as a system hotkey")
		case .alreadyTaken: return String(localized: "Another app already owns this shortcut")
		case .failed(let status): return String(localized: "RegisterEventHotKey failed (\(Int(status)))")
		}
	}
}

/// Owns every Carbon hotkey the app registers and routes presses to their handlers on the main queue.
final class CarbonHotKeyCenter {
	static let shared = CarbonHotKeyCenter()

	// 'WHSP'
	private static let signature: OSType = 0x5748_5350

	// InstallEventHandler rejects a second identical handler on the application target
	// (eventHandlerAlreadyInstalledErr), so one process-wide handler fans out to every center.
	private static var handlerInstalled = false
	private static var nextID: UInt32 = 1
	private static let centers = NSHashTable<CarbonHotKeyCenter>.weakObjects()

	private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: () -> Void, onRelease: (() -> Void)?)] = [:]

	init() {
		Self.centers.add(self)
	}

	deinit {
		unregisterAll()
	}

	var registeredCount: Int { hotKeys.count }

	@discardableResult
	func register(
		keyCode: UInt16, modifiers: NSEvent.ModifierFlags, onRelease: (() -> Void)? = nil,
		handler: @escaping () -> Void
	) throws -> UInt32 {
		guard let spec = CarbonHotKeyMapping.spec(keyCode: keyCode, modifiers: modifiers) else {
			throw CarbonHotKeyError.unsupportedKey
		}
		return try register(spec, onRelease: onRelease, handler: handler)
	}

	@discardableResult
	func register(_ spec: CarbonHotKeySpec, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void)
		throws -> UInt32
	{
		try installHandlerIfNeeded()

		let id = Self.nextID
		Self.nextID += 1
		var ref: EventHotKeyRef?
		let status = RegisterEventHotKey(
			spec.keyCode,
			spec.modifiers,
			EventHotKeyID(signature: Self.signature, id: id),
			GetApplicationEventTarget(),
			0,
			&ref
		)
		guard status == noErr, let ref else {
			throw status == eventHotKeyExistsErr ? CarbonHotKeyError.alreadyTaken : CarbonHotKeyError.failed(status)
		}
		hotKeys[id] = (ref, handler, onRelease)
		return id
	}

	func unregister(id: UInt32) {
		guard let entry = hotKeys.removeValue(forKey: id) else { return }
		UnregisterEventHotKey(entry.ref)
	}

	func unregisterAll() {
		for id in Array(hotKeys.keys) {
			unregister(id: id)
		}
	}

	fileprivate static func fire(signature: OSType, id: UInt32, released: Bool) {
		guard signature == Self.signature else { return }
		for center in centers.allObjects {
			if let entry = center.hotKeys[id] {
				if released {
					entry.onRelease?()
				} else {
					entry.handler()
				}
				return
			}
		}
	}

	private func installHandlerIfNeeded() throws {
		guard !Self.handlerInstalled else { return }
		var eventTypes = [
			EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
			EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
		]
		let status = InstallEventHandler(
			GetApplicationEventTarget(), carbonHotKeyCallback, eventTypes.count, &eventTypes, nil, nil)
		guard status == noErr else { throw CarbonHotKeyError.failed(status) }
		Self.handlerInstalled = true
	}
}

private let carbonHotKeyCallback: EventHandlerUPP = { _, event, _ in
	guard let event else { return OSStatus(eventNotHandledErr) }
	var hotKeyID = EventHotKeyID()
	let status = GetEventParameter(
		event,
		EventParamName(kEventParamDirectObject),
		EventParamType(typeEventHotKeyID),
		nil,
		MemoryLayout<EventHotKeyID>.size,
		nil,
		&hotKeyID
	)
	guard status == noErr else { return status }
	let signature = hotKeyID.signature
	let id = hotKeyID.id
	let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
	DispatchQueue.main.async {
		CarbonHotKeyCenter.fire(signature: signature, id: id, released: released)
	}
	return noErr
}
