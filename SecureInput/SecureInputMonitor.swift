import AppKit
import Carbon
import Darwin
import Observation

struct SecureInputCulprit: Equatable, Sendable {
	let pid: pid_t
	let name: String
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

/// A single re-registrable hotkey on its own CarbonHotKeyCenter, so rebuilding the
/// shared center's shortcuts never drops the secure input fallback.
final class CarbonHotKey {
	private let center = CarbonHotKeyCenter()
	private var registrationID: UInt32?
	private(set) var registeredSpec: CarbonHotKeySpec?
	var action: (() -> Void)?
	var releaseAction: (() -> Void)?

	deinit {
		unregister()
	}

	func register(_ spec: CarbonHotKeySpec) -> Bool {
		if registeredSpec == spec, registrationID != nil { return true }
		unregister()
		do {
			registrationID = try center.register(
				spec,
				onRelease: { [weak self] in self?.releaseAction?() },
				handler: { [weak self] in self?.action?() })
		} catch {
			return false
		}
		registeredSpec = spec
		return true
	}

	func unregister() {
		if let registrationID { center.unregister(id: registrationID) }
		registrationID = nil
		registeredSpec = nil
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

	func configure(
		hotKeySpec: @escaping () -> CarbonHotKeySpec?, action: @escaping () -> Void,
		release: (() -> Void)? = nil
	) {
		hotKeySpecProvider = hotKeySpec
		hotKey.action = action
		hotKey.releaseAction = release
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
		stateMachine = SecureInputStateMachine()
		isEnabled = false
		isSustained = false
		culprit = nil
		fallbackStatus = .inactive
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
