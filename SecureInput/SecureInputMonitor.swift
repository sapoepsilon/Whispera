import AppKit
import Carbon
import Darwin
import Observation

struct SecureInputCulprit: Equatable, Sendable {
	let pid: pid_t
	let name: String
}

struct CarbonHotKeySpec: Equatable, Sendable {
	let keyCode: UInt32
	let modifiers: UInt32
}

enum CarbonHotKeyMapping {
	static let globeKeyCode: UInt16 = 63

	// Carbon cannot register the Globe/Fn key, so that shortcut has no fallback
	static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CarbonHotKeySpec? {
		guard keyCode != globeKeyCode else { return nil }
		var carbonModifiers: UInt32 = 0
		if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
		if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
		if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
		if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
		return CarbonHotKeySpec(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
	}
}

enum SecureInputCulpritLookup {
	static func pid(fromIORegOutput output: String) -> pid_t? {
		let marker = "\"kCGSSessionSecureInputPID\"="
		for line in output.split(separator: "\n") {
			guard let range = line.range(of: marker) else { continue }
			let digits = line[range.upperBound...].prefix { $0.isNumber }
			if let pid = pid_t(digits), pid > 0 { return pid }
		}
		return nil
	}

	static func processName(for pid: pid_t) -> String {
		if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
			return name
		}
		var buffer = [CChar](repeating: 0, count: 1024)
		if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
			return String(cString: buffer)
		}
		return "a process that is no longer running"
	}

	// Apple documents no API for the holder; the IORegistry session PID is best effort
	static func lookup() async -> SecureInputCulprit? {
		await Task.detached(priority: .utility) { () -> SecureInputCulprit? in
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
			process.arguments = ["-l", "-w", "0", "-d", "1", "-k", "IOConsoleUsers"]
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = FileHandle.nullDevice
			do {
				try process.run()
			} catch {
				return nil
			}
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			guard let output = String(data: data, encoding: .utf8),
				let pid = pid(fromIORegOutput: output)
			else { return nil }
			return SecureInputCulprit(pid: pid, name: processName(for: pid))
		}.value
	}
}

struct SecureInputStateMachine: Equatable {
	enum Transition: Equatable {
		case none
		case enabled
		case sustained
		case disabled(wasSustained: Bool)
	}

	static let sustainThreshold: TimeInterval = 3

	private(set) var isEnabled = false
	private(set) var isSustained = false
	private(set) var enabledSince: Date?

	mutating func update(enabled: Bool, now: Date) -> Transition {
		if !enabled {
			guard isEnabled else { return .none }
			let wasSustained = isSustained
			isEnabled = false
			isSustained = false
			enabledSince = nil
			return .disabled(wasSustained: wasSustained)
		}
		if !isEnabled {
			isEnabled = true
			enabledSince = now
			return .enabled
		}
		if !isSustained, let since = enabledSince,
			now.timeIntervalSince(since) >= Self.sustainThreshold
		{
			isSustained = true
			return .sustained
		}
		return .none
	}
}

final class CarbonHotKey {
	private static let signature: OSType = 0x5748_5350
	private var hotKeyRef: EventHotKeyRef?
	private var handlerRef: EventHandlerRef?
	private(set) var registeredSpec: CarbonHotKeySpec?
	var action: (() -> Void)?

	deinit {
		unregister()
		if let handlerRef { RemoveEventHandler(handlerRef) }
	}

	func register(_ spec: CarbonHotKeySpec) -> Bool {
		if registeredSpec == spec, hotKeyRef != nil { return true }
		unregister()
		guard installHandlerIfNeeded() else { return false }
		let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
		var ref: EventHotKeyRef?
		let status = RegisterEventHotKey(
			spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
		guard status == noErr, let ref else { return false }
		hotKeyRef = ref
		registeredSpec = spec
		return true
	}

	func unregister() {
		if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
		hotKeyRef = nil
		registeredSpec = nil
	}

	private func installHandlerIfNeeded() -> Bool {
		if handlerRef != nil { return true }
		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		let userData = Unmanaged.passUnretained(self).toOpaque()
		let status = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, _, userData in
				guard let userData else { return OSStatus(eventNotHandledErr) }
				let hotKey = Unmanaged<CarbonHotKey>.fromOpaque(userData).takeUnretainedValue()
				DispatchQueue.main.async { hotKey.action?() }
				return noErr
			},
			1, &eventType, userData, &handlerRef)
		return status == noErr
	}
}

@MainActor
@Observable
final class SecureInputMonitor {
	enum Keys {
		static let fallbackEnabled = "secureInputHotkeyFallback"
	}

	enum FallbackStatus: Equatable {
		case inactive
		case active
		case unavailable
		case disabledByUser
	}

	static let shared = SecureInputMonitor()
	static let pollInterval: TimeInterval = 1

	private(set) var isEnabled = false
	private(set) var isSustained = false
	private(set) var culprit: SecureInputCulprit?
	private(set) var fallbackStatus: FallbackStatus = .inactive

	@ObservationIgnored private var stateMachine = SecureInputStateMachine()
	@ObservationIgnored private var timer: Timer?
	@ObservationIgnored private let hotKey = CarbonHotKey()
	@ObservationIgnored private let isSecureInputEnabled: () -> Bool
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private var hotKeySpecProvider: () -> CarbonHotKeySpec? = { nil }
	@ObservationIgnored private let logger = AppLogger.shared.general

	init(
		defaults: UserDefaults = .standard,
		isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }
	) {
		self.defaults = defaults
		self.isSecureInputEnabled = isSecureInputEnabled
	}

	var isFallbackEnabled: Bool {
		defaults.object(forKey: Keys.fallbackEnabled) as? Bool ?? true
	}

	var showsWarning: Bool {
		isSustained && fallbackStatus != .active
	}

	func configure(hotKeySpec: @escaping () -> CarbonHotKeySpec?, action: @escaping () -> Void) {
		hotKeySpecProvider = hotKeySpec
		hotKey.action = action
		reconcileFallback()
	}

	func start() {
		guard timer == nil else { return }
		poll()
		let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.poll() }
		}
		timer.tolerance = 0.25
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
		logger.info("Secure input monitor started")
	}

	func stop() {
		timer?.invalidate()
		timer = nil
		hotKey.unregister()
	}

	func poll(now: Date = Date()) {
		let transition = stateMachine.update(enabled: isSecureInputEnabled(), now: now)
		isEnabled = stateMachine.isEnabled
		isSustained = stateMachine.isSustained

		switch transition {
		case .none:
			return
		case .enabled:
			logger.info("Secure event input enabled")
			Task { [weak self] in
				let culprit = await SecureInputCulpritLookup.lookup()
				guard let self, self.isEnabled else { return }
				self.culprit = culprit
				if let culprit {
					self.logger.info("Secure event input held by pid \(culprit.pid) (\(culprit.name))")
				}
			}
		case .sustained:
			logger.info("Secure event input sustained; global shortcut monitors are blind")
			reconcileFallback()
		case .disabled(let wasSustained):
			logger.info("Secure event input disabled")
			culprit = nil
			if wasSustained { reconcileFallback() }
		}
	}

	func reconcileFallback() {
		guard isSustained else {
			hotKey.unregister()
			fallbackStatus = .inactive
			return
		}
		guard isFallbackEnabled else {
			hotKey.unregister()
			fallbackStatus = .disabledByUser
			return
		}
		guard let spec = hotKeySpecProvider(), hotKey.register(spec) else {
			hotKey.unregister()
			fallbackStatus = .unavailable
			logger.error("Secure input fallback hotkey could not be registered")
			return
		}
		if fallbackStatus != .active {
			logger.info("Secure input fallback hotkey registered")
		}
		fallbackStatus = .active
	}
}
