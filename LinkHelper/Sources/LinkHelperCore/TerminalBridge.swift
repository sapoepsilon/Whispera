import Foundation
import WhisperaHerdr
import LinkHelperPTY

// Terminal (beta): a live view of an agent's pane on the phone, with keyboard input.
//
// Resize policy, and why. Verified against herdr 0.9.1 and tmux 3.7:
// - `herdr agent attach` / `herdr terminal attach` on a pseudo-terminal resize the herdr pane to
//   that terminal's size, and the pane stays that size after detach unless a Mac TUI client is
//   attached. A phone that attached that way would silently reflow the owner's Mac view.
// - `herdr terminal session control <pane>` over plain pipes, without --cols/--rows, attaches at
//   the pane's current size and does not resize it. Its stdout is JSON lines (`terminal.frame`
//   with base64 cursor-addressed repaints, the first one `full`), its stdin takes
//   `terminal.input` / `terminal.resize` / `terminal.release`. `terminal.scroll` is herdr's own
//   wheel handling: a full-screen app in the pane gets it as the app asked (wheel reports with
//   mouse tracking, arrow keys with alternate scroll), but a pane with scrollback moves herdr's
//   view of it, the Mac's view too. herdr's frames never carry the app's screen or mouse modes,
//   so the phone cannot tell; it asks with a `scroll` frame, and the helper sends
//   `terminal.scroll` only while `pane.get` says the pane has nothing to scroll back through.
// - tmux `attach-session -f ignore-size` attaches a client that never affects the window size.
//
// So the default mode is `mirror`: the phone NEVER changes the Mac pane's size. herdr runs control
// without a size; tmux runs on a pseudo-terminal sized to the window and attached ignore-size
// (still writable). The phone is told the pane size (`size` frames) and renders that grid.
//
// `fit` is opt-in ("Fit to phone"): the pane is resized to the phone's cols/rows (herdr
// `terminal.resize`; tmux re-attaches without ignore-size), after remembering the ORIGINAL size
// from before the first fit. Going back to mirror, the idle timeout, the end of the 30 s
// reconnect grace and any other session close restore it: herdr `terminal.resize` to the
// original then `terminal.release`; tmux needs nothing when another client is attached (tmux
// sizes the window from it), otherwise `resize-window -A`.
//
// Sessions: one per (device, agent), at most four per device. Each keeps a ring of its last 512
// output frames / 2 MiB, so a phone that reconnects within the grace with `resume=S&after=N` gets
// exactly the frames after N; when they are gone it gets `reset` and a fresh full repaint.
// herdr accepts one attached client per pane, so a new open of a herdr pane replaces the session
// on it from any device (`exit replaced`), and an attach refused because a non-phone client holds
// the pane is a 409 `terminal_busy` (never `--takeover`, which would steal it from the Mac).
// Input is rate limited per session, opens per device; the attach argv is built only from a
// validated pane id that exists, never from a command. Remote herdr machines are not supported.

/// The pane a terminal attaches to.
enum TerminalTarget: Equatable {
	case herdr(pane: String)
	/// The digits of a tmux pane id (`%12` → "12").
	case tmux(pane: String)
	/// A herdr-core address (`t9`, `mac-b/t7`), watched read-only.
	case herdrCore(address: String)
}

enum TerminalBackendEvent {
	/// VT bytes; `full` marks a complete repaint (the first after any attach). `size` is the
	/// pane size the bytes were drawn for.
	case output(Data, full: Bool, size: TerminalSize)
	case size(TerminalSize)
	/// Whether swipes go to the app (the pane has no scrollback), when that changed.
	case appScroll(Bool)
	case closed
}

/// One attach to one pane. Events arrive on a background thread.
protocol TerminalBackend: AnyObject, Sendable {
	var provider: String { get }
	/// The pane size, once known (herdr learns it from the first frame).
	var paneSize: TerminalSize? { get }
	/// Attaches in mirror mode (never resizing the pane).
	func start(_ sink: @escaping @Sendable (TerminalBackendEvent) -> Void) throws
	func write(_ data: Data) throws
	/// fit: makes the pane `size`.
	func resizePane(_ size: TerminalSize) throws
	/// Back to mirror, putting the pane back to `original`.
	func unfit(restore original: TerminalSize) throws
	/// Detaches and re-attaches, so a full repaint follows.
	func repaint() throws
	/// Ends the attach, first restoring `original` when the session had resized the pane.
	func stop(restore original: TerminalSize?)
	/// Takes `scroll` frames (said in `hello`).
	var scrollsApps: Bool { get }
	/// Drops input and never resizes (said in `hello` as `read_only`).
	var readOnly: Bool { get }
	/// Wheel notches (positive up) for a full-screen app in the pane; never moves a view of
	/// the pane's scrollback. Returns whether they were sent.
	func scrollApp(_ notches: Int) throws -> Bool
}

extension TerminalBackend {
	var scrollsApps: Bool { false }
	var readOnly: Bool { false }
	func scrollApp(_ notches: Int) throws -> Bool { false }
}

/// The minimal environment an attach client runs with: never the helper's own (account
/// bearer, relay settings).
enum TerminalEnvironment {
	static func base() -> [String: String] {
		[
			"TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(),
			"USER": NSUserName(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
		]
	}
}

// MARK: herdr

/// `herdr terminal session control <pane>` over pipes.
final class HerdrControlBackend: TerminalBackend, @unchecked Sendable {
	let provider = "herdr"
	private let herdr: String
	private let pane: String
	private let environment: [String: String]
	private let lock = NSLock()
	private var process: Process?
	private var stdin: Int32 = -1
	private var generation = 0
	private var size: TerminalSize?
	private var sink: (@Sendable (TerminalBackendEvent) -> Void)?
	private var stopped = false
	private let client: HerdrClient

	init(herdr: String, pane: String, socket: String, client: HerdrClient? = nil) {
		self.herdr = herdr
		self.pane = pane
		self.client = client ?? HerdrClient(socketPath: socket)
		var env = TerminalEnvironment.base()
		env["HERDR_SOCKET_PATH"] = socket
		if let config = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"], !config.isEmpty {
			env["HERDR_CONFIG_PATH"] = config
		}
		environment = env
	}

	var paneSize: TerminalSize? {
		lock.lock()
		defer { lock.unlock() }
		return size
	}

	func start(_ sink: @escaping @Sendable (TerminalBackendEvent) -> Void) throws {
		lock.lock()
		self.sink = sink
		lock.unlock()
		try launch()
		let thread = Thread { [weak self] in self?.watchScrollback() }
		thread.name = "link.terminal.herdr.scroll"
		thread.start()
	}

	/// Polls `pane.get` (read-only) for whether the pane has scrollback, and reports changes:
	/// the phone sends its swipes to the app only while it has none.
	private func watchScrollback() {
		var last: Bool?
		while true {
			lock.lock()
			let done = stopped
			let sink = self.sink
			lock.unlock()
			if done { return }
			if let info = try? HerdrClient.expect(client.call("pane.get", ["pane_id": pane], timeout: 2), "pane_info") {
				let app = Self.hasNoScrollback(info)
				if app != last {
					last = app
					sink?(.appScroll(app))
				}
			}
			usleep(Self.scrollPollMicroseconds)
		}
	}

	static let scrollPollMicroseconds: useconds_t = 750_000

	private func launch() throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: herdr)
		process.arguments = ["terminal", "session", "control", pane]
		process.environment = environment
		let input = Pipe()
		let output = Pipe()
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			throw APIError(503, "terminal_unavailable", "could not start herdr terminal control")
		}
		let writeFD = input.fileHandleForWriting.fileDescriptor
		_ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
		lock.lock()
		generation += 1
		let mine = generation
		self.process = process
		stdin = writeFD
		lock.unlock()
		let handle = output.fileHandleForReading
		// Keep the pipe objects alive with the process.
		let keep = (input, output)
		let thread = Thread { [weak self] in
			_ = keep
			self?.readLoop(handle.fileDescriptor, generation: mine)
		}
		thread.name = "link.terminal.herdr"
		thread.start()
	}

	private func readLoop(_ fd: Int32, generation mine: Int) {
		var pending = Data()
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		var first = true
		while true {
			let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
			if count < 0, errno == EINTR { continue }
			guard count > 0 else { break }
			pending.append(contentsOf: buffer[0..<count])
			while let newline = pending.firstIndex(of: 0x0A) {
				let line = pending[pending.startIndex..<newline]
				pending.removeSubrange(pending.startIndex...newline)
				guard let event = Self.parse(Data(line)) else { continue }
				lock.lock()
				let current = generation == mine && !stopped
				var out: TerminalBackendEvent?
				switch event {
				case .frame(let bytes, let full, let frameSize):
					size = frameSize
					out = .output(bytes, full: full || first, size: frameSize)
					first = false
				case .closed:
					out = .closed
				}
				let sink = self.sink
				lock.unlock()
				if current, let out { sink?(out) }
			}
		}
		lock.lock()
		let current = generation == mine && !stopped
		let sink = self.sink
		lock.unlock()
		if current { sink?(.closed) }
	}

	enum Line: Equatable {
		case frame(Data, full: Bool, size: TerminalSize)
		case closed
	}

	/// One stdout line of `terminal session control`.
	static func parse(_ line: Data) -> Line? {
		guard let object = WireJSON.decodeObject(line), let type = object["type"] as? String else { return nil }
		switch type {
		case "terminal.frame":
			guard let encoded = object["bytes"] as? String, let bytes = Data(base64Encoded: encoded),
				let width = WireJSON.strictInt(object["width"]), let height = WireJSON.strictInt(object["height"])
			else { return nil }
			return .frame(bytes, full: object["full"] as? Bool ?? false, size: TerminalSize(cols: width, rows: height))
		case "terminal.closed": return .closed
		default: return nil
		}
	}

	private func send(_ object: [String: Any]) throws {
		var line = WireJSON.encode(object)
		line.append(0x0A)
		lock.lock()
		defer { lock.unlock() }
		guard stdin >= 0 else { throw APIError(410, "terminal_closed", "the terminal has ended") }
		try line.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				let wrote = Darwin.write(stdin, raw.baseAddress!.advanced(by: offset), raw.count - offset)
				if wrote < 0 {
					if errno == EINTR || errno == EAGAIN { continue }
					throw APIError(410, "terminal_closed", "the terminal has ended")
				}
				offset += wrote
			}
		}
	}

	func write(_ data: Data) throws {
		try send(["type": "terminal.input", "bytes": data.base64EncodedString()])
	}

	func resizePane(_ size: TerminalSize) throws {
		try send(["type": "terminal.resize", "cols": size.cols, "rows": size.rows])
	}

	func unfit(restore original: TerminalSize) throws { try resizePane(original) }

	let scrollsApps = true

	func scrollApp(_ notches: Int) throws -> Bool {
		guard notches != 0 else { return false }
		let info = try HerdrClient.expect(client.call("pane.get", ["pane_id": pane]), "pane_info")
		guard Self.hasNoScrollback(info) else { return false }
		let direction = notches > 0 ? "up" : "down"
		for _ in 0..<min(abs(notches), TerminalFrame.maxScrollNotches) {
			try send(["type": "terminal.scroll", "direction": direction, "lines": 1])
		}
		return true
	}

	/// `pane.get`'s answer for a pane whose view cannot move: at the bottom with no scrollback,
	/// as on the alternate screen. Anything else (or no `scroll` at all) is a no.
	static func hasNoScrollback(_ info: [String: Any]) -> Bool {
		guard let pane = info["pane"] as? [String: Any], let scroll = pane["scroll"] as? [String: Any],
			let max = WireJSON.strictInt(scroll["max_offset_from_bottom"]),
			let offset = WireJSON.strictInt(scroll["offset_from_bottom"])
		else { return false }
		return max == 0 && offset == 0
	}

	func repaint() throws {
		terminate(release: true)
		try launch()
	}

	/// Releases (optionally) and ends the current control process.
	private func terminate(release: Bool) {
		if release { try? send(["type": "terminal.release"]) }
		lock.lock()
		let process = self.process
		let fd = stdin
		self.process = nil
		stdin = -1
		generation += 1
		lock.unlock()
		if fd >= 0 { Darwin.close(fd) }
		guard let process else { return }
		// Synchronously: herdr allows one attached client per terminal, so the next attach
		// (a repaint, or the session replacing this one) must wait until this one is gone.
		for _ in 0..<40 where process.isRunning { usleep(25_000) }
		if process.isRunning {
			process.terminate()
			process.waitUntilExit()
		}
	}

	func stop(restore original: TerminalSize?) {
		if let original { try? resizePane(original) }
		lock.lock()
		stopped = true
		lock.unlock()
		terminate(release: true)
	}
}

// MARK: tmux

/// A process on a pseudo-terminal the helper owns (tmux's attach client).
final class PTYProcess: @unchecked Sendable {
	private let master: Int32
	private let pid: pid_t
	private let lock = NSLock()
	private var closed = false

	init(command: [String], environment: [String], size: TerminalSize, onOutput: @escaping (Data) -> Void,
		onExit: @escaping () -> Void) throws
	{
		var fd: Int32 = -1
		let spawned = Self.withCStrings(command) { argv in
			Self.withCStrings(environment) { envp in
				wl_pty_spawn(command[0], argv, envp, UInt16(size.cols), UInt16(size.rows), &fd)
			}
		}
		guard spawned > 0, fd >= 0 else {
			throw APIError(503, "terminal_unavailable", "could not start the terminal (errno \(errno))")
		}
		pid = spawned
		master = fd
		let thread = Thread {
			var buffer = [UInt8](repeating: 0, count: 64 * 1024)
			while true {
				let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
				if count < 0, errno == EINTR { continue }
				guard count > 0 else { break }
				onOutput(Data(buffer[0..<count]))
			}
			onExit()
		}
		thread.name = "link.terminal.pty"
		thread.start()
	}

	private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
		var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
		pointers.append(nil)
		defer { pointers.forEach { free($0) } }
		return body(pointers)
	}

	func write(_ data: Data) throws {
		lock.lock()
		defer { lock.unlock() }
		guard !closed else { throw APIError(410, "terminal_closed", "the terminal has ended") }
		try data.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				let wrote = Darwin.write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
				if wrote < 0 {
					if errno == EINTR || errno == EAGAIN { continue }
					throw APIError(410, "terminal_closed", "the terminal has ended")
				}
				offset += wrote
			}
		}
	}

	func resize(_ size: TerminalSize) {
		_ = wl_pty_resize(master, UInt16(size.cols), UInt16(size.rows))
	}

	func close() {
		lock.lock()
		let already = closed
		closed = true
		lock.unlock()
		guard !already else { return }
		kill(pid, SIGHUP)
		Darwin.close(master)
		var status: Int32 = 0
		DispatchQueue.global().async { [pid] in
			for _ in 0..<20 {
				if waitpid(pid, &status, WNOHANG) != 0 { return }
				usleep(50_000)
			}
			kill(pid, SIGKILL)
			waitpid(pid, &status, 0)
		}
	}
}

/// `tmux attach-session` on a pseudo-terminal: `-f ignore-size` and sized to the window in
/// mirror mode, a plain attach at the phone's size in fit mode.
final class TmuxTerminalBackend: TerminalBackend, @unchecked Sendable {
	let provider = "tmux"
	private let tmux: String
	private let socketArgs: [String]
	private let pane: String
	private let lock = NSLock()
	private var pty: PTYProcess?
	private var generation = 0
	private var ignoreSize = true
	private var size: TerminalSize?
	private var sink: (@Sendable (TerminalBackendEvent) -> Void)?
	private var stopped = false

	init(tmux: String, socket: String?, pane: String) {
		self.tmux = tmux
		socketArgs = socket.map { ["-S", $0] } ?? []
		self.pane = pane
	}

	var paneSize: TerminalSize? {
		lock.lock()
		defer { lock.unlock() }
		return size
	}

	private func run(_ args: [String]) -> String? {
		guard let result = try? HerdrCLI.spawn(tmux, socketArgs + args, timeout: 3), result.status == 0 else { return nil }
		return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	func windowSize() -> TerminalSize? {
		guard let text = run(["display-message", "-p", "-t", "%" + pane, "#{window_width} #{window_height}"]) else {
			return nil
		}
		let parts = text.split(separator: " ").compactMap { Int($0) }
		guard parts.count == 2 else { return nil }
		return TerminalSize(cols: parts[0], rows: parts[1])
	}

	func start(_ sink: @escaping @Sendable (TerminalBackendEvent) -> Void) throws {
		guard let window = windowSize() else { throw APIError(404, "not_found", "agent not found") }
		lock.lock()
		self.sink = sink
		size = window
		lock.unlock()
		try attach(ignoreSize: true, size: window)
		let thread = Thread { [weak self] in self?.pollWindow() }
		thread.name = "link.terminal.tmux-size"
		thread.start()
	}

	private func attach(ignoreSize: Bool, size: TerminalSize) throws {
		let flags = ignoreSize ? ["-f", "ignore-size"] : []
		let argv = [tmux] + socketArgs + ["attach-session"] + flags + ["-t", "%" + pane]
		let env = TerminalEnvironment.base().map { "\($0.key)=\($0.value)" }
		lock.lock()
		generation += 1
		let mine = generation
		let old = pty
		pty = nil
		self.ignoreSize = ignoreSize
		lock.unlock()
		old?.close()
		let first = FirstFlag()
		let process = try PTYProcess(
			command: argv, environment: env, size: size,
			onOutput: { [weak self] data in
				guard let self else { return }
				self.lock.lock()
				let current = self.generation == mine && !self.stopped
				let sink = self.sink
				let size = self.size ?? size
				self.lock.unlock()
				if current { sink?(.output(data, full: first.take(), size: size)) }
			},
			onExit: { [weak self] in
				guard let self else { return }
				self.lock.lock()
				let current = self.generation == mine && !self.stopped
				let sink = self.sink
				self.lock.unlock()
				if current { sink?(.closed) }
			})
		lock.lock()
		pty = process
		lock.unlock()
	}

	private final class FirstFlag: @unchecked Sendable {
		private let lock = NSLock()
		private var first = true
		func take() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			let was = first
			first = false
			return was
		}
	}

	/// A mirror attach follows the window: when the Mac resizes it, so does our terminal.
	private func pollWindow() {
		while true {
			Thread.sleep(forTimeInterval: 1)
			lock.lock()
			let done = stopped
			lock.unlock()
			if done { return }
			guard let window = windowSize() else { continue }
			lock.lock()
			let changed = window != size
			size = window
			let mirror = ignoreSize
			let pty = self.pty
			let sink = self.sink
			lock.unlock()
			guard changed else { continue }
			if mirror { pty?.resize(window) }
			sink?(.size(window))
		}
	}

	func write(_ data: Data) throws {
		lock.lock()
		let pty = self.pty
		lock.unlock()
		guard let pty else { throw APIError(410, "terminal_closed", "the terminal has ended") }
		try pty.write(data)
	}

	func resizePane(_ size: TerminalSize) throws {
		lock.lock()
		let mirror = ignoreSize
		let pty = self.pty
		lock.unlock()
		if mirror {
			try attach(ignoreSize: false, size: size)
		} else {
			pty?.resize(size)
		}
	}

	private func otherClients() -> Bool {
		guard let session = run(["display-message", "-p", "-t", "%" + pane, "#{session_id}"]),
			let clients = run(["list-clients", "-t", session, "-F", "#{client_tty}"])
		else { return true }
		return !clients.isEmpty
	}

	private func restoreWindow() {
		if !otherClients() { _ = run(["resize-window", "-A", "-t", "%" + pane]) }
	}

	func unfit(restore original: TerminalSize) throws {
		let window = windowSize() ?? original
		try attach(ignoreSize: true, size: window)
		restoreWindow()
	}

	func repaint() throws {
		lock.lock()
		let mirror = ignoreSize
		let size = self.size
		lock.unlock()
		guard let size else { throw APIError(410, "terminal_closed", "the terminal has ended") }
		try attach(ignoreSize: mirror, size: size)
	}

	func stop(restore original: TerminalSize?) {
		lock.lock()
		stopped = true
		let pty = self.pty
		self.pty = nil
		lock.unlock()
		pty?.close()
		if original != nil {
			// Let tmux see the client go before deciding whether anyone else sizes the window.
			usleep(100_000)
			restoreWindow()
		}
	}
}

// MARK: Session

/// One phone's terminal on one agent. Survives disconnects for the grace period; at most one
/// stream (WebSocket or SSE) is attached at a time, identified by a generation number.
final class PhoneTerminalSession: @unchecked Sendable {
	enum Next {
		/// Frames with the position they were sent at (the output seq, for SSE `id:`).
		case frames([(UInt64, Data)])
		case timeout
		/// Another stream took this session over, or this one fell too far behind.
		case superseded
		/// The session ended; its `exit` frame was the last one delivered.
		case ended
	}

	static let maxOutboxBytes = 8 << 20

	let id: String
	let agentID: String
	let device: DeviceRecord
	var deviceID: String { device.deviceID }
	let backend: TerminalBackend
	let idleTimeout: Double
	private let clock: () -> Double
	private let log: (String, [String: Any?]) -> Void
	private let condition = NSCondition()
	private let control = NSLock()
	private var ring = TerminalRing()
	private var outbox: [(UInt64, Data)] = []
	private var outboxBytes = 0
	private var generation = 0
	private var attached = false
	private var detachedAt: Double?
	private var lastInputAt: Double
	private(set) var mode: TerminalMode
	private var phoneSize: TerminalSize
	private var paneSize: TerminalSize?
	/// The backend's last word on where swipes go (herdr only).
	private var appScroll: Bool?
	private var originalSize: TerminalSize?
	private var exitReason: TerminalExit?
	private var limiter: TerminalInputLimiter
	private var echoSince: DispatchTime?
	private var lastEchoLog: Double = 0

	init(
		agentID: String, device: DeviceRecord, backend: TerminalBackend, mode: TerminalMode, phoneSize: TerminalSize,
		idleTimeout: Double, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
		log: @escaping (String, [String: Any?]) -> Void = { _, _ in }
	) {
		id = "term_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
		self.agentID = agentID
		self.device = device
		self.backend = backend
		self.mode = mode
		self.phoneSize = phoneSize
		self.idleTimeout = idleTimeout
		self.clock = clock
		self.log = log
		lastInputAt = clock()
		limiter = TerminalInputLimiter(now: clock())
	}

	/// Attaches the backend (mirror) and waits up to `timeout` for the pane size; then applies
	/// fit if asked.
	func start(timeout: TimeInterval) throws {
		try backend.start { [weak self] event in self?.receive(event) }
		condition.lock()
		let deadline = Date().addingTimeInterval(timeout)
		while paneSize == nil, exitReason == nil {
			if !condition.wait(until: deadline) { break }
		}
		if paneSize == nil { paneSize = backend.paneSize }
		let refused = exitReason != nil && ring.lastSeq == 0
		condition.unlock()
		if refused {
			// herdr refuses a second attached client (a Mac `herdr terminal attach`, say).
			throw APIError(409, "terminal_busy", "another terminal client is attached to this pane")
		}
		if mode == .fit { applyMode(.fit) }
	}

	var isEnded: Bool {
		condition.lock()
		defer { condition.unlock() }
		return exitReason != nil
	}

	var currentSize: TerminalSize {
		condition.lock()
		defer { condition.unlock() }
		return paneSize ?? phoneSize
	}

	/// Starts a stream: hello, then the replay after `after` (nil: everything kept, for a new
	/// session). A resume that cannot be honoured gets a reset and a fresh repaint instead.
	/// Returns the stream's generation and whether the resume was honoured.
	@discardableResult
	func attach(after: UInt64?) -> (generation: Int, resumed: Bool) {
		condition.lock()
		generation += 1
		let mine = generation
		attached = true
		detachedAt = nil
		outbox.removeAll()
		outboxBytes = 0
		let replay = ring.frames(after: after ?? 0)
		let resumed = after != nil && replay != nil
		let hello = TerminalFrame.encodeHello(
			session: id, size: paneSize ?? phoneSize, mode: mode, provider: backend.provider, resumed: resumed,
			idleTimeout: Int(idleTimeout), scroll: backend.scrollsApps, appScroll: appScroll, readOnly: backend.readOnly)
		enqueue(ring.lastSeq, hello)
		if let replay { for entry in replay { enqueue(entry.position, entry.frame) } }
		condition.broadcast()
		condition.unlock()
		if replay == nil {
			control.lock()
			let repainted = (try? backend.repaint()) != nil
			control.unlock()
			if !repainted { end(.ended) }
		}
		return (mine, resumed)
	}

	func detach(_ generation: Int) {
		condition.lock()
		if generation == self.generation, attached {
			attached = false
			detachedAt = clock()
			outbox.removeAll()
			outboxBytes = 0
		}
		condition.unlock()
	}

	func next(_ generation: Int, timeout: TimeInterval) -> Next {
		condition.lock()
		defer { condition.unlock() }
		let deadline = Date().addingTimeInterval(timeout)
		while generation == self.generation, outbox.isEmpty, exitReason == nil {
			if !condition.wait(until: deadline) { break }
		}
		guard generation == self.generation else { return .superseded }
		if !outbox.isEmpty {
			let out = outbox
			outbox.removeAll()
			outboxBytes = 0
			return .frames(out)
		}
		return exitReason == nil ? .timeout : .ended
	}

	/// Must hold `condition`.
	private func enqueue(_ position: UInt64, _ frame: Data) {
		outbox.append((position, frame))
		outboxBytes += frame.count
	}

	/// Must hold `condition`.
	private func emit(_ frame: Data, outputSeq: UInt64?) {
		ring.append(frame, outputSeq: outputSeq)
		guard attached else { return }
		enqueue(ring.lastSeq, frame)
		if outboxBytes > Self.maxOutboxBytes {
			// The stream cannot keep up: drop it; the phone resumes from the ring or repaints.
			generation += 1
			attached = false
			detachedAt = clock()
			outbox.removeAll()
			outboxBytes = 0
		}
		condition.broadcast()
	}

	private func receive(_ event: TerminalBackendEvent) {
		switch event {
		case .output(let bytes, let full, let size):
			condition.lock()
			guard exitReason == nil else { return condition.unlock() }
			if let since = echoSince {
				echoSince = nil
				let elapsed = Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
				let now = clock()
				if now - lastEchoLog >= 1 {
					lastEchoLog = now
					log("terminal.echo", ["agent": agentID, "detail": String(format: "%@_ms=%.1f", backend.provider, elapsed)])
				}
			}
			if full {
				paneSize = size
				emit(TerminalFrame.encodeReset(size), outputSeq: nil)
			} else if size != paneSize {
				paneSize = size
				emit(TerminalFrame.encodeSize(size), outputSeq: nil)
			}
			emit(TerminalFrame.encodeOutput(seq: ring.lastSeq + 1, bytes), outputSeq: ring.lastSeq + 1)
			// Also wakes `start`, which waits for the first frame's pane size.
			condition.broadcast()
			condition.unlock()
		case .size(let size):
			condition.lock()
			if exitReason == nil, size != paneSize {
				paneSize = size
				emit(TerminalFrame.encodeSize(size), outputSeq: nil)
			}
			condition.unlock()
		case .appScroll(let app):
			condition.lock()
			if exitReason == nil, app != appScroll {
				appScroll = app
				emit(TerminalFrame.encodeScrollState(app: app), outputSeq: nil)
			}
			condition.unlock()
		case .closed:
			end(.ended)
		}
	}

	/// Applies one phone frame. Answers the input seq once written (nil when dropped).
	@discardableResult
	func handle(_ frame: TerminalFrame.Client) throws -> UInt32? {
		switch frame {
		case .input(let seq, let bytes):
			condition.lock()
			guard exitReason == nil else {
				condition.unlock()
				throw APIError(410, "terminal_closed", "the terminal has ended")
			}
			let verdict = limiter.admit(bytes: bytes.count, now: clock())
			condition.unlock()
			switch verdict {
			case .drop: return nil
			case .abuse:
				end(.rateLimited)
				return nil
			case .accept: break
			}
			condition.lock()
			if echoSince == nil { echoSince = .now() }
			lastInputAt = clock()
			condition.unlock()
			control.lock()
			do { try backend.write(bytes) } catch {
				control.unlock()
				end(.ended)
				throw error
			}
			control.unlock()
			condition.lock()
			if attached {
				enqueue(ring.lastSeq, TerminalFrame.encodeAck(seq))
				condition.broadcast()
			}
			condition.unlock()
			return seq
		case .resize(let size):
			condition.lock()
			phoneSize = size
			let fit = mode == .fit
			condition.unlock()
			if fit {
				control.lock()
				try? backend.resizePane(size)
				control.unlock()
			}
			return nil
		case .mode(let mode):
			applyMode(mode)
			return nil
		case .scroll(let notches):
			condition.lock()
			guard exitReason == nil else {
				condition.unlock()
				throw APIError(410, "terminal_closed", "the terminal has ended")
			}
			// Each notch costs like a short report, so a fling stays within the input limits.
			let verdict = limiter.admit(bytes: abs(notches) * 16, now: clock())
			if verdict == .accept { lastInputAt = clock() }
			condition.unlock()
			switch verdict {
			case .drop: return nil
			case .abuse:
				end(.rateLimited)
				return nil
			case .accept: break
			}
			control.lock()
			_ = try? backend.scrollApp(notches)
			control.unlock()
			return nil
		}
	}

	func applyMode(_ next: TerminalMode) {
		control.lock()
		defer { control.unlock() }
		condition.lock()
		let previous = mode
		mode = next
		let phone = phoneSize
		let original = originalSize
		if next == .fit, original == nil { originalSize = paneSize ?? backend.paneSize }
		if next == .mirror { originalSize = nil }
		condition.unlock()
		switch next {
		case .fit:
			try? backend.resizePane(phone)
		case .mirror:
			guard previous == .fit, let original else { return }
			try? backend.unfit(restore: original)
		}
	}

	/// Ends the session once: the `exit` frame to an attached stream (unless `notify` is false),
	/// the pane's size back.
	func end(_ reason: TerminalExit, notify: Bool = true) {
		condition.lock()
		guard exitReason == nil else { return condition.unlock() }
		exitReason = reason
		if attached, notify { enqueue(ring.lastSeq, TerminalFrame.encodeExit(reason)) }
		let restore = originalSize
		originalSize = nil
		condition.broadcast()
		condition.unlock()
		control.lock()
		backend.stop(restore: restore)
		control.unlock()
		log("terminal.close", ["device": deviceID, "agent": agentID, "detail": "\(id) reason=\(reason.rawValue)"])
	}

	/// The janitor's verdict: why this session should end now, if it should.
	func expiry(now: Double, grace: Double) -> TerminalExit? {
		condition.lock()
		defer { condition.unlock() }
		guard exitReason == nil else { return nil }
		if now - lastInputAt >= idleTimeout { return .idle }
		if !attached, let since = detachedAt, now - since >= grace { return .ended }
		return nil
	}
}

// MARK: Bridge

/// The sessions, the open checks, and the janitor that ends idle, abandoned or revoked ones.
final class TerminalBridge: @unchecked Sendable {
	static let maxInputBytes = TerminalFrame.maxInputBytes
	static let sizeRange = TerminalFrame.sizeRange
	static let maxSessionsPerDevice = 4
	static let grace: Double = 30

	private let config: HelperConfig
	private let herdr: HerdrClient?
	private let herdrCLI: String?
	private let tmuxCLI: String?
	/// herdr-core's terminals (set by the daemon): their view is `hc attach --observe`.
	var herdrCore: HerdrCoreDirectory?
	private let log: (String, [String: Any?]) -> Void
	private let lock = NSLock()
	private var sessions: [String: PhoneTerminalSession] = [:]
	private var openLimiter = TerminalOpenLimiter()
	private var janitor: DispatchSourceTimer?
	let clock: () -> Double
	var grace = TerminalBridge.grace
	/// Whether a session's device may still use it (set by the daemon: revoked → `exit revoked`).
	var entitled: (DeviceRecord) -> Bool = { _ in true }
	/// Seams for tests: the attach for a target, and the check that its pane exists.
	lazy var makeBackend: (TerminalTarget) throws -> TerminalBackend = { [unowned self] in try realBackend($0) }
	lazy var checkTarget: (TerminalTarget) throws -> Void = { [unowned self] in try realCheck($0) }

	init(
		config: HelperConfig, herdr: HerdrClient? = nil, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
		log: @escaping (String, [String: Any?]) -> Void
	) {
		self.config = config
		self.herdr = herdr
		let environment = ProcessInfo.processInfo.environment
		herdrCLI = HerdrCLI.resolve(config.herdrCLI, environment: environment)
		tmuxCLI = HerdrCLI.resolve(config.tmuxCLI, environment: environment)
		self.clock = clock
		self.log = log
		let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.terminal.janitor"))
		timer.schedule(deadline: .now() + 1, repeating: 1)
		timer.setEventHandler { [weak self] in self?.sweep() }
		timer.resume()
		janitor = timer
	}

	deinit { janitor?.cancel() }

	private static func key(_ agentID: String, _ deviceID: String) -> String { deviceID + "|" + agentID }

	private static func isHerdr(_ target: TerminalTarget) -> Bool {
		if case .herdr = target { return true }
		return false
	}

	/// The pane an agent id names. Syntax only: no process runs for an id that fails here.
	static func parseTarget(_ agentID: String) throws -> TerminalTarget {
		if agentID.hasPrefix("tmux:") {
			let rest = agentID.dropFirst(5)
			guard rest.hasPrefix("p"), (2...12).contains(rest.count),
				rest.dropFirst().utf8.allSatisfy({ (48...57).contains($0) })
			else { throw APIError(400, "bad_request", "Invalid tmux pane") }
			return .tmux(pane: String(rest.dropFirst()))
		}
		if HerdrCoreID.isHerdrCore(agentID) {
			guard let address = HerdrCoreID.address(agentID) else { throw APIError(400, "bad_request", "Invalid herdr-core terminal") }
			return .herdrCore(address: address)
		}
		guard LinkAPI.isValidAgentID(agentID), !agentID.hasPrefix("-") else {
			throw APIError(400, "bad_request", "Invalid agent id")
		}
		guard case .local(let pane) = AgentRef(agentID) else {
			throw APIError(400, "not_supported", "terminals on other machines are not supported yet")
		}
		return .herdr(pane: pane)
	}

	private func realCheck(_ target: TerminalTarget) throws {
		switch target {
		case .herdr(let pane):
			guard let herdr else { throw APIError(503, "herdr_unavailable", "herdr is not reachable") }
			_ = try HerdrClient.expect(herdr.call("pane.get", ["pane_id": pane]), "pane_info")
		case .tmux(let pane):
			guard let tmux = tmuxCLI else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
			let socket = config.tmuxSocket.map { ["-S", $0] } ?? []
			let result = try HerdrCLI.spawn(tmux, socket + ["display-message", "-p", "-t", "%" + pane, "#{pane_id}"], timeout: 3)
			guard result.status == 0,
				String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "%" + pane
			else { throw APIError(404, "not_found", "agent not found") }
		case .herdrCore(let address):
			guard let herdrCore, let id = HerdrCoreID.id(address: address) else {
				throw APIError(503, "hc_unavailable", "herdr-core is not set up on this Mac")
			}
			_ = try herdrCore.validated(id)
		}
	}

	private func realBackend(_ target: TerminalTarget) throws -> TerminalBackend {
		switch target {
		case .herdr(let pane):
			guard let herdr = herdrCLI else { throw APIError(503, "herdr_unavailable", "herdr CLI not found") }
			return HerdrControlBackend(herdr: herdr, pane: pane, socket: config.herdrSocket, client: self.herdr)
		case .tmux(let pane):
			guard let tmux = tmuxCLI else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
			return TmuxTerminalBackend(tmux: tmux, socket: config.tmuxSocket, pane: pane)
		case .herdrCore(let address):
			guard let herdrCore, let cli = herdrCore.cli, let id = HerdrCoreID.id(address: address) else {
				throw APIError(503, "hc_unavailable", "The hc CLI is not installed on this Mac")
			}
			return HerdrCoreTerminalBackend(cli: cli, address: address) {
				guard let terminal = try? herdrCore.validated(id).terminal, let cols = WireJSON.strictInt(terminal["cols"]),
					let rows = WireJSON.strictInt(terminal["rows"]), cols > 0, rows > 0
				else { return nil }
				return TerminalSize(cols: cols, rows: rows)
			}
		}
	}

	/// Opens (or resumes) the device's terminal on an agent and attaches a stream to it.
	func open(
		agentID: String, device: DeviceRecord, size: TerminalSize, mode: TerminalMode, resume: String?, after: UInt64?
	) throws -> (session: PhoneTerminalSession, generation: Int) {
		let started = Date()
		lock.lock()
		let admitted = openLimiter.admit(device.deviceID, now: clock())
		lock.unlock()
		guard admitted else { throw APIError(429, "rate_limited", "too many terminal opens; retry in a minute") }
		let target = try Self.parseTarget(agentID)
		let key = Self.key(agentID, device.deviceID)
		if let resume {
			lock.lock()
			let existing = sessions[key]
			lock.unlock()
			if let existing, existing.id == resume, !existing.isEnded {
				let (generation, resumed) = existing.attach(after: after ?? 0)
				if existing.mode != mode { existing.applyMode(mode) }
				_ = try? existing.handle(.resize(size))
				log(
					"terminal.resume",
					[
						"device": device.deviceID, "agent": agentID,
						"detail": "\(existing.id) after=\(after ?? 0) resumed=\(resumed) ms=\(Int(-started.timeIntervalSinceNow * 1000))",
					])
				return (existing, generation)
			}
		}
		try checkTarget(target)
		lock.lock()
		let others = sessions.filter { $0.value.deviceID == device.deviceID && $0.key != key }.map(\.value)
		// herdr takes one attached client per pane: the newest open wins, on any device. The
		// old attach must be gone before the new one starts.
		let replaced = sessions.filter { entry in
			entry.key == key || (entry.value.agentID == agentID && Self.isHerdr(target))
		}
		for (oldKey, _) in replaced { sessions.removeValue(forKey: oldKey) }
		lock.unlock()
		if others.count >= Self.maxSessionsPerDevice {
			throw APIError(429, "too_many_terminals", "close another terminal first (at most 4 per device)")
		}
		for (_, old) in replaced { old.end(.replaced) }
		let backend = try makeBackend(target)
		let session = PhoneTerminalSession(
			agentID: agentID, device: device, backend: backend, mode: mode, phoneSize: size,
			idleTimeout: config.terminalIdleTimeout, clock: clock, log: log)
		do {
			try session.start(timeout: 3)
		} catch {
			session.end(.ended)
			throw error
		}
		lock.lock()
		let old = sessions.updateValue(session, forKey: key)
		lock.unlock()
		old?.end(.replaced)
		let (generation, _) = session.attach(after: nil)
		log(
			"terminal.open",
			[
				"device": device.deviceID, "agent": agentID,
				"detail":
					"\(session.id) \(backend.provider) \(mode.rawValue) pane=\(session.currentSize) phone=\(size) ms=\(Int(-started.timeIntervalSinceNow * 1000))",
			])
		return (session, generation)
	}

	/// The device's live session on an agent (`id` must match when given).
	func session(agentID: String, deviceID: String, id: String? = nil) throws -> PhoneTerminalSession {
		lock.lock()
		defer { lock.unlock() }
		guard let session = sessions[Self.key(agentID, deviceID)], !session.isEnded, id == nil || session.id == id
		else { throw APIError(404, "terminal_not_open", "open the terminal stream first") }
		return session
	}

	var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return sessions.count
	}

	/// Once a second: revoked devices, idle sessions and expired graces end; ended ones go.
	func sweep() {
		let now = clock()
		lock.lock()
		let all = sessions
		lock.unlock()
		for (key, session) in all {
			if !session.isEnded {
				if !entitled(session.device) {
					session.end(.revoked)
				} else if let reason = session.expiry(now: now, grace: grace) {
					session.end(reason)
				}
			}
			if session.isEnded {
				lock.lock()
				if sessions[key] === session { sessions.removeValue(forKey: key) }
				lock.unlock()
			}
		}
	}

	func closeAll() {
		lock.lock()
		let all = Array(sessions.values)
		sessions.removeAll()
		lock.unlock()
		// The helper is shutting down: no `exit` frame, so the phone treats it as a dropped
		// connection and reconnects (the next helper answers with a reset + full repaint).
		all.forEach { $0.end(.ended, notify: false) }
	}
}
