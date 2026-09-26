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
	// There is no notification for secure input, so it is polled, but only while the answer can
	// matter: the fallback is on or a view shows the state, and the screens are awake. While it is
	// off the poll is slow and tolerant so the system can coalesce the wakeup; app switches, which
	// is when secure input usually changes, trigger an immediate check. Once it is on, the poll
	// speeds up to notice the sustained hold and the release promptly.
	static let idlePollInterval: TimeInterval = 6
	static let idlePollTolerance: TimeInterval = 3
	static let activePollInterval: TimeInterval = 1
	static let activePollTolerance: TimeInterval = 0.5

	private(set) var isEnabled = false
	private(set) var isSustained = false
	private(set) var culprit: SecureInputCulprit?
	private(set) var fallbackStatus: FallbackStatus = .inactive

	@ObservationIgnored private var stateMachine = SecureInputStateMachine()
	@ObservationIgnored private var timer: Timer?
	@ObservationIgnored private(set) var currentPollInterval: TimeInterval?
	/// Set by `start()`: the dictation shortcut relies on event monitors, which secure input blinds.
	@ObservationIgnored private var started = false
	/// Screens asleep or the session switched away; nobody can press the shortcut.
	@ObservationIgnored private var suspended = false
	@ObservationIgnored private var visibleViews = 0
	@ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
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
		guard !started else { return }
		started = true
		observeWorkspace()
		poll()
		updatePolling()
		logger.info("Secure input monitor started")
	}

	var isPolling: Bool { timer != nil }

	func stop() {
		started = false
		suspended = false
		stopObservingWorkspace()
		updatePolling()
		hotKey.unregister()
		stateMachine = SecureInputStateMachine()
		setIfChanged(\.isEnabled, false)
		setIfChanged(\.isSustained, false)
		setIfChanged(\.culprit, nil)
		setIfChanged(\.fallbackStatus, .inactive)
	}

	func poll(now: Date = Date()) {
		let transition = stateMachine.update(enabled: isSecureInputEnabled(), now: now)
		setIfChanged(\.isEnabled, stateMachine.isEnabled)
		setIfChanged(\.isSustained, stateMachine.isSustained)

		switch transition {
		case .none:
			return
		case .enabled:
			logger.debug("Secure event input enabled")
			updatePolling()
		case .sustained:
			logger.info("Secure event input sustained; global shortcut monitors are blind")
			reconcileFallback()
			lookUpCulprit()
		case .disabled(let wasSustained):
			logger.debug("Secure event input disabled")
			setIfChanged(\.culprit, nil)
			if wasSustained { reconcileFallback() }
			updatePolling()
		}
	}

	/// A banner or settings row showing the state keeps it fresh even with the fallback off.
	func viewDidAppear() {
		visibleViews += 1
		if started { poll() }
		updatePolling()
	}

	func viewDidDisappear() {
		visibleViews = max(visibleViews - 1, 0)
		updatePolling()
	}

	func suspend() {
		guard !suspended else { return }
		suspended = true
		updatePolling()
	}

	func resume() {
		guard suspended else { return }
		suspended = false
		if started { poll() }
		updatePolling()
	}

	private var desiredPollInterval: TimeInterval? {
		guard started, !suspended, isFallbackEnabled || visibleViews > 0 else { return nil }
		return stateMachine.isEnabled ? Self.activePollInterval : Self.idlePollInterval
	}

	private func updatePolling() {
		let desired = desiredPollInterval
		guard desired != currentPollInterval || (desired != nil) != (timer != nil) else { return }
		timer?.invalidate()
		timer = nil
		currentPollInterval = desired
		guard let desired else { return }
		let timer = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.poll() }
		}
		timer.tolerance = desired == Self.activePollInterval ? Self.activePollTolerance : Self.idlePollTolerance
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	private func observeWorkspace() {
		guard workspaceObservers.isEmpty else { return }
		let center = NSWorkspace.shared.notificationCenter
		func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (SecureInputMonitor) -> Void)
			-> NSObjectProtocol
		{
			center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self else { return }
					handler(self)
				}
			}
		}
		workspaceObservers = [
			observe(NSWorkspace.didActivateApplicationNotification) { monitor in
				if monitor.timer != nil { monitor.poll() }
			},
			observe(NSWorkspace.screensDidSleepNotification) { $0.suspend() },
			observe(NSWorkspace.sessionDidResignActiveNotification) { $0.suspend() },
			observe(NSWorkspace.screensDidWakeNotification) { $0.resume() },
			observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume() },
		]
	}

	private func stopObservingWorkspace() {
		let center = NSWorkspace.shared.notificationCenter
		workspaceObservers.forEach { center.removeObserver($0) }
		workspaceObservers = []
	}

	// Browsers toggle secure input on every password-field focus; only a sustained hold is shown
	// to the user, so the ioreg subprocess is spawned for that and not for each brief toggle.
	private func lookUpCulprit() {
		Task { [weak self] in
			let culprit = await SecureInputCulpritLookup.lookup()
			guard let self, self.isSustained else { return }
			self.setIfChanged(\.culprit, culprit)
			if let culprit {
				self.logger.info("Secure event input held by pid \(culprit.pid) (\(culprit.name))")
			}
		}
	}

	// Assigning an unchanged value to an @Observable property still invalidates every view that
	// reads it, which would redraw the menu bar popover and Settings on every poll.
	private func setIfChanged<Value: Equatable>(
		_ keyPath: ReferenceWritableKeyPath<SecureInputMonitor, Value>, _ value: Value
	) {
		guard self[keyPath: keyPath] != value else { return }
		self[keyPath: keyPath] = value
	}

	func reconcileFallback() {
		updatePolling()
		guard isSustained else {
			hotKey.unregister()
			setIfChanged(\.fallbackStatus, .inactive)
			return
		}
		guard isFallbackEnabled else {
			hotKey.unregister()
			setIfChanged(\.fallbackStatus, .disabledByUser)
			return
		}
		guard let spec = hotKeySpecProvider(), hotKey.register(spec) else {
			hotKey.unregister()
			setIfChanged(\.fallbackStatus, .unavailable)
			logger.error("Secure input fallback hotkey could not be registered")
			return
		}
		if fallbackStatus != .active {
			logger.info("Secure input fallback hotkey registered")
		}
		setIfChanged(\.fallbackStatus, .active)
	}
}
