import Darwin
import Foundation
import WhisperaHerdr
import WhisperaAgents
import WhisperaLink

/// herdr-core (`hc`) socket client: JSON-RPC 2.0, one message per line, one short-lived
/// connection per call. The socket is the owner's own (mode 0600 in the owner's state folder).
///
/// `allowedMethods` is closed: the reads and writes the phone's agent controls need, and
/// nothing that manages the core, other machines, files or labels. Every address it is given
/// was found in hc's current listing first (`HerdrCoreDirectory`).
final class HerdrCoreClient: @unchecked Sendable {
	static let generation = 1
	static let connectTimeout: TimeInterval = 1
	static let callTimeout: TimeInterval = 5
	/// `terminal.send` and `terminal.keys` wait for ~3 s of quiet at the keyboard first.
	static let inputTimeout: TimeInterval = 20
	static let maxLine = 8 * 1024 * 1024
	static let allowedMethods: Set<String> = [
		"hello", "terminal.list", "terminal.get", "terminal.read", "terminal.send", "terminal.keys", "terminal.run",
		"terminal.kill", "terminal.rm", "events.subscribe",
	]
	/// What a core must offer before its terminals are listed at all.
	static let requiredMethods: Set<String> = [
		"terminal.list", "terminal.get", "terminal.read", "terminal.send", "terminal.keys", "events.subscribe",
	]
	static let requiredFeatures: Set<String> = ["status", "events"]

	/// What `hello` said, when it said enough.
	struct Capabilities: Equatable {
		var version: String
		var methods: Set<String>
		var features: Set<String>
		var canStart: Bool { methods.contains("terminal.run") }
		var canRemove: Bool { methods.isSuperset(of: ["terminal.kill", "terminal.rm"]) }
	}

	let socketPath: String
	private let lock = NSLock()
	private var detected: (at: Date, capabilities: Capabilities?)?
	/// How long a detection answer is reused.
	var detectionTTL: TimeInterval = 5
	private var counter = 0

	init(socketPath: String) {
		self.socketPath = socketPath
	}

	static func connect(_ path: String) throws -> UnixConnection {
		guard FileManager.default.fileExists(atPath: path) else {
			throw APIError(503, "hc_unavailable", "herdr-core socket not found")
		}
		do {
			return try UnixConnection.connect(path: path, timeout: connectTimeout)
		} catch is UnixConnection.SocketTimeout {
			throw APIError(504, "hc_timeout", "herdr-core connect timed out")
		} catch {
			throw APIError(503, "hc_unavailable", "herdr-core socket refused the connection")
		}
	}

	private func nextID() -> Int {
		lock.lock()
		defer { lock.unlock() }
		counter += 1
		return counter
	}

	/// Sends one request and returns its `result` (an object for every allowed method).
	func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = callTimeout) throws -> [String: Any] {
		guard Self.allowedMethods.contains(method), method != "events.subscribe" else {
			throw APIError(500, "internal", "herdr-core method not allowed by the bridge")
		}
		try CancelToken.checkCurrent()
		let id = nextID()
		let connection = try Self.connect(socketPath)
		defer { connection.close() }
		let deadline = Date().addingTimeInterval(timeout)
		var answer: [String: Any]?
		do {
			try connection.sendLine(Self.request(id, method, params), timeout: min(timeout, 2))
			while answer == nil {
				switch try connection.readLine(timeout: min(deadline.timeIntervalSinceNow, 0.25), limit: Self.maxLine) {
				case .timeout:
					try CancelToken.checkCurrent()
					if deadline.timeIntervalSinceNow > 0 { continue }
					throw APIError(504, "hc_timeout", "herdr-core did not answer in \(Int(timeout)) s")
				case .eof:
					throw APIError(503, "hc_unavailable", "herdr-core closed the connection")
				case .line(let line):
					guard let decoded = WireJSON.decodeObject(line) else {
						throw APIError(502, "hc_error", "herdr-core sent malformed JSON", extra: ["hc_kind": "malformed"])
					}
					if WireJSON.strictInt(decoded["id"]) == id { answer = decoded }
				}
			}
		} catch let error as APIError {
			throw error
		} catch let cancelled as RequestCancelled {
			throw cancelled
		} catch is UnixConnection.SocketTimeout {
			throw APIError(504, "hc_timeout", "herdr-core did not answer in \(Int(timeout)) s")
		} catch {
			throw APIError(503, "hc_unavailable", "herdr-core socket error")
		}
		if let error = answer?["error"] as? [String: Any] { throw Self.mapError(error) }
		guard let result = answer?["result"] as? [String: Any] else {
			throw APIError(502, "hc_error", "herdr-core answered without a result", extra: ["hc_kind": "malformed"])
		}
		return result
	}

	static func request(_ id: Int, _ method: String, _ params: [String: Any]) -> [String: Any] {
		["jsonrpc": "2.0", "id": id, "method": method, "params": params]
	}

	/// JSON-RPC errors by their stable `data.kind`.
	static func mapError(_ error: [String: Any]) -> APIError {
		let kind = (error["data"] as? [String: Any])?["kind"] as? String ?? "unknown"
		let message = String((error["message"] as? String ?? kind).prefix(200))
		let extra: [String: Any] = ["hc_kind": kind]
		switch kind {
		case "not_found", "machine_unknown":
			return APIError(404, "not_found", "agent not found", extra: extra)
		case "finished":
			return APIError(404, "not_found", "the terminal has finished", extra: extra)
		case "blocked":
			return APIError(409, "agent_blocked", "agent is blocked on a prompt; nothing was sent", extra: extra)
		case "status_mismatch":
			return APIError(409, "agent_busy", "the agent's status changed; nothing was sent", extra: extra)
		case "live":
			return APIError(409, "still_running", "the terminal is still running", extra: extra)
		case "name_taken":
			return APIError(409, "name_taken", "a terminal with that name is running", extra: extra)
		case "invalid_params":
			return APIError(400, "bad_request", "herdr-core refused the request: " + message, extra: extra)
		case "unavailable":
			return APIError(503, "hc_unavailable", "herdr-core is unavailable: " + message, extra: extra)
		default:
			return APIError(502, "hc_error", "herdr-core error: " + message, extra: extra)
		}
	}

	/// `hello` at generation 1: capabilities when the core offers the methods and features the
	/// bridge needs, else nil (an older or newer core, or another program on the socket).
	func hello(timeout: TimeInterval = 2) throws -> Capabilities? {
		let result = try call("hello", ["generation": Self.generation], timeout: timeout)
		return Self.capabilities(result)
	}

	static func capabilities(_ result: [String: Any]) -> Capabilities? {
		guard WireJSON.strictInt(result["generation"]) == generation,
			let methods = (result["methods"] as? [String]).map(Set.init), methods.isSuperset(of: requiredMethods),
			let features = (result["features"] as? [String]).map(Set.init), features.isSuperset(of: requiredFeatures)
		else { return nil }
		return Capabilities(version: result["version"] as? String ?? "", methods: methods, features: features)
	}

	/// Detection, cached `detectionTTL`: nil while hc is absent, down or not capable enough.
	func capabilities(fresh: Bool = false) -> Capabilities? {
		lock.lock()
		if !fresh, let detected, Date().timeIntervalSince(detected.at) < detectionTTL {
			lock.unlock()
			return detected.capabilities
		}
		lock.unlock()
		let found = CancelToken.withoutCancellation { (try? hello()) ?? nil }
		lock.lock()
		detected = (Date(), found)
		lock.unlock()
		return found
	}

	func forgetDetection() {
		lock.lock()
		detected = nil
		lock.unlock()
	}
}

/// herdr-core's terminals as agents: this Mac's and every machine its core is connected to
/// (`machine/t7`), all over the one local socket. No ssh and no polling: the core relays the
/// other machines itself, and `HerdrCoreSubscriber` follows their changes.
final class HerdrCoreDirectory: @unchecked Sendable {
	let client: HerdrCoreClient
	/// The `hc` CLI, for the terminal view's `hc attach --observe` (nil: no terminal view).
	let cli: String?
	/// Claude Code's per-process session files (`<pid>.json`), for transcripts.
	let claudeSessionsDir: String
	private let log: OpsLog

	static let maxKeys = 64
	/// The longest free-text answer pasted into an ask.
	static let maxAnswerText = 4000
	static let maxReadLines = 2000
	/// Key names hc takes (`terminal.keys`), beyond single characters and `shift+<letter>`.
	static let keyNames: Set<String> = [
		"enter", "esc", "tab", "shift+tab", "space", "backspace", "up", "down", "left", "right", "shift+left",
		"shift+right", "home", "end", "pageup", "pagedown", "delete", "ctrl+c", "ctrl+d", "ctrl+u", "ctrl+l", "ctrl+o",
		"ctrl+r", "ctrl+t", "ctrl+e", "ctrl+a", "ctrl+b", "ctrl+f", "ctrl+g", "ctrl+j", "ctrl+k", "ctrl+n", "ctrl+p",
		"ctrl+w", "ctrl+z", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
	]
	/// Programs the phone may start with `terminal.run` (argv[0]); never a shell or a path.
	///
	/// This keeps a typo or a confused client from starting an arbitrary program; it is not a
	/// containment boundary. A confirmed phone is trusted as the owner: its arguments and working
	/// directory pass through to the agent, and an agent CLI can itself run anything.
	static let startableKinds: Set<String> = Set(HerdrCoreAgent.knownAgents.values)

	init(
		socketPath: String, cli: String? = nil, claudeSessionsDir: String = NSHomeDirectory() + "/.claude/sessions",
		log: OpsLog = .null
	) {
		client = HerdrCoreClient(socketPath: socketPath)
		self.cli = cli
		self.claudeSessionsDir = claudeSessionsDir
		self.log = log
	}

	var capabilities: HerdrCoreClient.Capabilities? { client.capabilities() }
	var isAvailable: Bool { capabilities != nil }

	static func machineObject(_ name: String?, label: String?) -> [String: Any] {
		guard let name else { return AgentDirectory.machineObject(AgentMachine.localID, AgentDirectory.localLabel) }
		return AgentDirectory.machineObject(name, label ?? name)
	}

	/// hc's listing: live terminals here and on connected machines, plus the machine lines.
	func rawListing() throws -> (terminals: [[String: Any]], machines: [[String: Any]]) {
		guard isAvailable else { throw APIError(503, "hc_unavailable", "herdr-core is not running") }
		let result = try client.call("terminal.list", [:])
		let terminals = (result["terminals"] as? [[String: Any]] ?? []).filter { $0["state"] as? String == "live" }
		return (terminals, result["machines"] as? [[String: Any]] ?? [])
	}

	/// The agent object of one terminal, with its machine named as hc's machine list names it.
	func project(_ terminal: [String: Any], machines: [[String: Any]]) -> [String: Any]? {
		guard let address = terminal["address"] as? String, let id = HerdrCoreID.id(address: address) else { return nil }
		let machine = HerdrCoreID.machine(id)
		let label = machine.flatMap { name in
			machines.first { $0["name"] as? String == name }.flatMap { $0["host"] as? String }
		}
		return HerdrCoreAgent.agent(terminal, machine: Self.machineObject(machine, label: label ?? machine))
	}

	/// The agents and the machine statuses for `GET /v1/agents`.
	func list() throws -> (agents: [[String: Any]], machines: [[String: Any]]) {
		let (terminals, machines) = try rawListing()
		let agents = terminals.compactMap { project($0, machines: machines) }
		let statuses = machines.compactMap { row -> [String: Any]? in
			guard let name = row["name"] as? String, HerdrCoreID.isValidMachine(name) else { return nil }
			var status: [String: Any] = [
				"id": name, "label": row["host"] as? String ?? name, "provider": "hc",
				"status": row["state"] as? String == "connected" ? "ok" : "unreachable",
			]
			if let why = row["why"] as? String, !why.isEmpty { status["error"] = String(why.prefix(200)) }
			return status
		}
		return (agents, statuses)
	}

	/// The address behind a phone's id, only when hc lists it as live right now.
	func validated(_ id: String) throws -> (address: String, terminal: [String: Any], machines: [[String: Any]]) {
		guard let address = HerdrCoreID.address(id) else { throw APIError(400, "bad_request", "Invalid herdr-core terminal") }
		let (terminals, machines) = try rawListing()
		guard let terminal = terminals.first(where: { $0["address"] as? String == address }) else {
			throw APIError(404, "not_found", "agent not found")
		}
		return (address, terminal, machines)
	}

	func get(_ id: String) throws -> [String: Any] {
		let (_, terminal, machines) = try validated(id)
		guard let agent = project(terminal, machines: machines) else { throw APIError(404, "not_found", "agent not found") }
		return agent
	}

	/// `visible` reads only the screen; any other source the screen plus `lines` of history.
	/// hc reads text only. While the program works, is blocked or errs, hc returns just the
	/// screen (`complete: false`): marked `truncated` and `historyPartial`, as herdr's busy read.
	func read(_ id: String, source: String, lines: Int) throws -> [String: Any] {
		guard HerdrClient.readSources.contains(source) else {
			throw APIError(400, "bad_request", "herdr-core has no \(source) read")
		}
		let (address, _, _) = try validated(id)
		let history = source == HerdrClient.visibleSource ? 0 : max(1, min(lines, Self.maxReadLines))
		let result = try client.call("terminal.read", ["terminal": address, "lines": history])
		var answer: [String: Any] = [
			"id": id, "source": source, "text": result["text"] as? String ?? "", "revision": NSNull(),
			"truncated": result["complete"] as? Bool == false, "format": "text",
		]
		if result["complete"] as? Bool == false, result["why"] is String { answer["historyPartial"] = true }
		return answer
	}

	/// Pastes the prompt and presses Enter (`terminal.send`, after hc's quiet wait). hc refuses
	/// a blocked program: that is the phone's 409, never a forced send.
	func send(_ text: String, id: String) throws -> [String: Any] {
		guard !text.isEmpty, text.unicodeScalars.count <= AgentSubmissions.maxText, !text.contains("\u{0}") else {
			throw APIError(400, "bad_request", "text is empty or too long")
		}
		let (address, terminal, machines) = try validated(id)
		// hc refuses it too; checked here first so a blocked agent's dialog never sees the text.
		if HerdrCoreAgent.status(terminal) == "blocked" {
			throw APIError(409, "agent_blocked", "agent is blocked on a prompt; nothing was sent")
		}
		let result = try client.call(
			"terminal.send", ["terminal": address, "text": text], timeout: HerdrCoreClient.inputTimeout)
		var agent = project(terminal, machines: machines) ?? ["id": id]
		if let status = result["status"] as? String, HerdrCoreAgent.statuses.contains(status) { agent["status"] = status }
		return ["agent": agent, "waited": false]
	}

	static func isValidKey(_ key: String) -> Bool {
		if keyNames.contains(key.lowercased()) { return true }
		if key.hasPrefix("shift+"), key.count == 7, let letter = key.last, letter.isASCII, letter.isLowercase { return true }
		guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return false }
		return scalar.value >= 0x21 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
	}

	func sendKeys(_ keys: [String], id: String) throws -> [String: Any] {
		guard !keys.isEmpty, keys.count <= Self.maxKeys, keys.allSatisfy(Self.isValidKey) else {
			throw APIError(400, "bad_request", "keys must be key names such as esc, enter or ctrl+c")
		}
		let (address, _, _) = try validated(id)
		_ = try client.call(
			"terminal.keys", ["terminal": address, "keys": keys.map { Self.keyNames.contains($0.lowercased()) ? $0.lowercased() : $0 }],
			timeout: HerdrCoreClient.inputTimeout)
		return ["id": id, "keys": keys.count]
	}

	/// Starts an agent in a new terminal (`terminal.run`): argv is the kind and the phone's
	/// arguments, never a shell line; `on` is a machine hc lists. The name the owner gave goes
	/// in a label, so it can never collide with a running terminal's name.
	/// The argv[0] allowlist (`startableKinds`) is not a sandbox: the phone's arguments and cwd
	/// are passed through as given, because a confirmed phone is fully trusted.
	func start(_ request: AgentStart, machine: String?) throws -> [String: Any] {
		guard let capabilities, capabilities.canStart else {
			throw APIError(503, "hc_unavailable", "herdr-core cannot start terminals here")
		}
		guard Self.startableKinds.contains(request.kind) else {
			throw APIError(400, "bad_request", "kind must be an agent herdr-core can run, such as claude or codex")
		}
		var params: [String: Any] = [
			"argv": [request.kind] + request.args, "labels": [HerdrCoreAgent.nameLabel: request.name], "no_parent": true,
			"no_notify": true,
		]
		if let machine {
			guard HerdrCoreID.isValidMachine(machine), try rawListing().machines.contains(where: { $0["name"] as? String == machine })
			else { throw APIError(404, "not_found", "no such herdr-core machine") }
			params["on"] = machine
		}
		if let cwd = request.cwd {
			params["cwd"] = machine == nil && cwd.hasPrefix("~") ? NSString(string: cwd).expandingTildeInPath : cwd
		}
		let started = try client.call("terminal.run", params, timeout: Double(request.timeoutMS) / 1000 + 5)
		let machines = (try? rawListing().machines) ?? []
		guard let agent = project(started, machines: machines) else {
			throw APIError(502, "hc_error", "terminal.run returned no address", extra: ["hc_kind": "malformed"])
		}
		log("hc.start", ["detail": "kind=\(request.kind) remote=\(machine != nil)"])
		return ["agent": agent]
	}

	/// Ends and removes a terminal the phone's list shows as an agent: a plain shell is never
	/// closed from the phone, and a terminal already gone answers `already_gone`.
	func remove(_ id: String) throws -> [String: Any] {
		guard let capabilities, capabilities.canRemove else {
			throw APIError(503, "hc_unavailable", "herdr-core cannot remove terminals here")
		}
		let address: String
		do {
			let found = try validated(id)
			guard HerdrCoreAgent.kind(found.terminal) != nil else {
				throw APIError(409, "not_an_agent", "Only agents can be removed from the phone; close this terminal on the Mac")
			}
			address = found.address
		} catch let error as APIError where error.code == "not_found" {
			return AgentDirectory.removed(id, alreadyGone: true)
		}
		do {
			_ = try client.call("terminal.kill", ["terminal": address], timeout: 15)
			_ = try client.call("terminal.rm", ["terminal": address])
		} catch let error as APIError where error.code == "not_found" {
			return AgentDirectory.removed(id, alreadyGone: true)
		}
		log("hc.remove", ["detail": "removed"])
		return AgentDirectory.removed(id, alreadyGone: false)
	}

	func askTerminal(_ id: String) throws -> HerdrCoreAskTerminal {
		let (address, _, _) = try validated(id)
		let client = self.client
		return HerdrCoreAskTerminal(address: address) { method, params in
			guard ["terminal.read", "terminal.keys", "terminal.get", "terminal.send"].contains(method),
				params["terminal"] as? String == address
			else { throw APIError(500, "internal", "herdr-core ask call not allowed") }
			if method == "terminal.send" {
				// An ask's free-text answer that keys cannot spell (`?`, quotes, non-ASCII):
				// pasted into the form with Enter, which is the driver's next key anyway.
				guard let text = params["text"] as? String, !text.isEmpty,
					text.unicodeScalars.count <= Self.maxAnswerText,
					text == PastedText.sanitize(text), params.count == 3, params["force"] as? Bool == true
				else { throw APIError(400, "bad_request", "an answer is plain text") }
				return try client.call(method, params, timeout: HerdrCoreClient.inputTimeout)
			}
			if method == "terminal.keys" {
				let keys = params["keys"] as? [String] ?? []
				guard !keys.isEmpty, keys.count <= Self.maxKeys, keys.allSatisfy(Self.isValidKey) else {
					throw APIError(400, "bad_request", "keys must be key names")
				}
				return try client.call(method, params, timeout: HerdrCoreClient.inputTimeout)
			}
			return try client.call(method, params)
		}
	}

	// MARK: Transcripts

	/// A local terminal's agent in the shape the transcript store reads herdr's agents in:
	/// `agent`, `name`, `cwd`, and for Claude Code the session id of its process (from
	/// `~/.claude/sessions/<pid>.json`, Claude's own private file: anything unexpected there
	/// just leaves the session unnamed). nil for other machines' terminals and non-agents.
	func transcriptInfo(_ id: String) throws -> [String: Any]? {
		guard HerdrCoreID.address(id) != nil, !HerdrCoreID.isRemote(id) else { return nil }
		let terminal: [String: Any]
		do {
			terminal = try validated(id).terminal
		} catch let error as APIError where error.code == "not_found" {
			return nil
		}
		return transcriptInfo(terminal: terminal)
	}

	func transcriptInfo(terminal: [String: Any]) -> [String: Any]? {
		guard let address = terminal["address"] as? String, let id = HerdrCoreID.id(address: address),
			!HerdrCoreID.isRemote(id), let kind = HerdrCoreAgent.kind(terminal)
		else { return nil }
		let agent = HerdrCoreAgent.agent(terminal, machine: Self.machineObject(nil, label: nil)) ?? [:]
		var info: [String: Any] = ["pane_id": id, "agent": kind, "name": agent["name"] ?? NSNull()]
		if let cwd = agent["cwd"] as? String { info["cwd"] = cwd }
		let pid = WireJSON.strictInt((terminal["foreground"] as? [String: Any])?["pid"])
		if kind == "claude", let pid, let session = claudeSessionID(pid: pid) {
			info["agent_session"] = ["kind": "id", "value": session, "agent": "claude"]
		}
		return info
	}

	func transcriptInfos() -> [[String: Any]] {
		((try? rawListing().terminals) ?? []).compactMap { transcriptInfo(terminal: $0) }
	}

	static let maxSessionFile = 256 * 1024

	/// `sessionId` from `<dir>/<pid>.json` when the file is a small regular file of the owner's
	/// that names the same pid. Never follows a link; never reads anything else in the folder.
	func claudeSessionID(pid: Int) -> String? {
		guard pid > 0 else { return nil }
		let path = claudeSessionsDir + "/\(pid).json"
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
			attributes[.type] as? FileAttributeType == .typeRegular,
			(attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
			let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maxSessionFile,
			let data = FileManager.default.contents(atPath: path),
			let object = WireJSON.decodeObject(data), WireJSON.strictInt(object["pid"]) == pid,
			let session = object["sessionId"] as? String, SessionLocator.isValidSessionID(session)
		else { return nil }
		return session
	}
}

/// Follows `events.subscribe`: hc's snapshot, then each fact change in order, here and on the
/// machines the core is connected to, with a heartbeat every 15 s. Publishes the phone's
/// `agent.status` and `agents.changed` events. A connection that goes quiet past the
/// heartbeats, closes or reports `missed` is replaced, and the fresh snapshot is compared with
/// what was last known so no change is lost across the gap.
final class HerdrCoreSubscriber: @unchecked Sendable {
	enum State: String { case unknown, up, down, absent }

	/// Events that change which terminals exist or what they are called.
	static let setEvents: Set<String> = ["created", "lost", "restarted", "finished", "removed", "labels"]
	static let heartbeatTimeout: TimeInterval = 45

	private let directory: HerdrCoreDirectory
	private let emit: (String, [String: Any]) -> Void
	private let log: OpsLog
	private let backoffBase: TimeInterval
	private let backoffMax: TimeInterval
	var heartbeatTimeout = HerdrCoreSubscriber.heartbeatTimeout
	private let lock = NSLock()
	private var currentState = State.unknown
	private var stopped = false
	private var connection: UnixConnection?
	private let stopSignal = DispatchSemaphore(value: 0)
	/// Live terminals by agent id: their last projection.
	private var known: [String: [String: Any]] = [:]
	private var seq = 0
	private(set) var connections = 0

	init(
		directory: HerdrCoreDirectory, emit: @escaping (String, [String: Any]) -> Void, log: OpsLog = .null,
		backoffBase: TimeInterval = 1, backoffMax: TimeInterval = 30
	) {
		self.directory = directory
		self.emit = emit
		self.log = log
		self.backoffBase = backoffBase
		self.backoffMax = backoffMax
	}

	var state: State {
		lock.lock()
		defer { lock.unlock() }
		return currentState
	}

	func start() {
		let thread = Thread { [self] in run() }
		thread.name = "hc-subscriber"
		thread.start()
	}

	func stop() {
		lock.lock()
		stopped = true
		let open = connection
		lock.unlock()
		open?.close()
		stopSignal.signal()
	}

	private var isStopped: Bool {
		lock.lock()
		defer { lock.unlock() }
		return stopped
	}

	private func waitStopped(_ delay: TimeInterval) -> Bool {
		if isStopped { return true }
		_ = stopSignal.wait(timeout: .now() + delay)
		if isStopped {
			stopSignal.signal()
			return true
		}
		return false
	}

	private func setState(_ new: State) {
		lock.lock()
		let old = currentState
		currentState = new
		lock.unlock()
		guard old != new else { return }
		if new == .up {
			log("hc.up")
			if old == .down { emit("agents.changed", [:]) }
		} else if old == .up {
			// What was known stays: the next snapshot is compared with it, so a status that
			// changed while the connection was down is still reported.
			log("hc.down")
			lock.lock()
			let had = !known.isEmpty
			lock.unlock()
			if had { emit("agents.changed", [:]) }
		}
	}

	private func run() {
		var delay = backoffBase
		while !isStopped {
			guard directory.client.capabilities(fresh: true) != nil else {
				setState(currentStateIsUnknownOrAbsent ? .absent : .down)
				if waitStopped(delay) { return }
				delay = min(delay * 2, backoffMax)
				continue
			}
			let opened: UnixConnection
			do {
				opened = try open()
			} catch {
				log("hc.subscribe_failed", ["detail": (error as? APIError)?.code ?? "\(type(of: error))"])
				setState(.down)
				if waitStopped(delay) { return }
				delay = min(delay * 2, backoffMax)
				continue
			}
			delay = backoffBase
			lock.lock()
			connection = opened
			lock.unlock()
			setState(.up)
			pump(opened)
			opened.close()
			if isStopped { return }
			directory.client.forgetDetection()
			setState(.down)
			if waitStopped(delay) { return }
			delay = min(delay * 2, backoffMax)
		}
	}

	private var currentStateIsUnknownOrAbsent: Bool {
		let now = state
		return now == .unknown || now == .absent
	}

	/// Subscribes and applies the snapshot it answers with.
	private func open() throws -> UnixConnection {
		let connection = try HerdrCoreClient.connect(directory.client.socketPath)
		do {
			let id = 1
			try connection.sendLine(HerdrCoreClient.request(id, "events.subscribe", [:]))
			let deadline = Date().addingTimeInterval(HerdrCoreClient.callTimeout)
			while true {
				switch try connection.readLine(timeout: deadline.timeIntervalSinceNow, limit: HerdrCoreClient.maxLine) {
				case .timeout: throw APIError(504, "hc_timeout", "subscribe timed out")
				case .eof: throw APIError(503, "hc_unavailable", "EOF during subscribe")
				case .line(let line):
					guard let message = WireJSON.decodeObject(line), WireJSON.strictInt(message["id"]) == id else { continue }
					if let error = message["error"] as? [String: Any] { throw HerdrCoreClient.mapError(error) }
					let result = message["result"] as? [String: Any] ?? [:]
					lock.lock()
					connections += 1
					lock.unlock()
					applySnapshot(result)
					return connection
				}
			}
		} catch {
			connection.close()
			throw error
		}
	}

	private func pump(_ connection: UnixConnection) {
		var lastHeard = Date()
		while !isStopped {
			let result: UnixConnection.LineResult
			do {
				result = try connection.readLine(timeout: 0.5, limit: HerdrCoreClient.maxLine)
			} catch {
				log("hc.subscription_lost", ["detail": "line_too_long"])
				return
			}
			switch result {
			case .timeout:
				if Date().timeIntervalSince(lastHeard) > heartbeatTimeout {
					log("hc.subscription_lost", ["detail": "no_heartbeat"])
					return
				}
			case .eof:
				return
			case .line(let line):
				lastHeard = Date()
				guard let message = WireJSON.decodeObject(line) else { continue }
				if message["error"] != nil, message["method"] == nil {
					log("hc.subscription_error", ["detail": "error"])
					return
				}
				guard handle(message) else { return }
			}
		}
	}

	/// One notification; false when the connection should be replaced.
	@discardableResult
	func handle(_ message: [String: Any]) -> Bool {
		guard let method = message["method"] as? String else { return true }
		let params = message["params"] as? [String: Any] ?? [:]
		switch method {
		case "heartbeat":
			return true
		case "missed":
			// The core dropped events for this subscriber: its fresh snapshot replaces ours.
			log("hc.missed")
			if params["terminals"] is [[String: Any]] {
				applySnapshot(params)
				return true
			}
			return false
		case "event":
			apply(params)
			return true
		default:
			return true
		}
	}

	private func apply(_ event: [String: Any]) {
		let eventSeq = WireJSON.strictInt(event["seq"]) ?? 0
		lock.lock()
		// After a `missed` snapshot, events not above its seq are already in it.
		if eventSeq > 0, eventSeq <= seq {
			lock.unlock()
			return
		}
		if eventSeq > 0 { seq = eventSeq }
		lock.unlock()
		guard let type = event["type"] as? String, let address = event["terminal"] as? String,
			let id = HerdrCoreID.id(address: address)
		else { return }
		let data = event["data"] as? [String: Any] ?? [:]
		switch type {
		case "status":
			lock.lock()
			guard var agent = known[id] else {
				lock.unlock()
				emit("agents.changed", [:])
				return
			}
			let old = agent["status"] as? String
			var terminal: [String: Any] = ["address": address]
			terminal["status"] = data["status"]
			let status = HerdrCoreAgent.status(terminal)
			agent["status"] = status
			if let kind = HerdrCoreAgent.blockedKind(terminal) { agent["status_kind"] = kind } else { agent["status_kind"] = nil }
			if let app = (data["status"] as? [String: Any])?["app"] as? String, let kind = HerdrCoreAgent.knownAgents[app.lowercased()] {
				agent["agent"] = kind
				agent["display_agent"] = kind
			}
			known[id] = agent
			lock.unlock()
			if old != status { emit("agent.status", Self.statusEvent(agent)) }
		case "title":
			lock.lock()
			if var agent = known[id], let title = HerdrCoreAgent.clean(data["title"]) {
				agent["title"] = title
				known[id] = agent
			}
			lock.unlock()
		case "created", "restarted", "labels":
			refresh(id)
			emit("agents.changed", [:])
		case "lost", "finished", "removed":
			lock.lock()
			known[id] = nil
			lock.unlock()
			emit("agents.changed", [:])
		default:
			break
		}
	}

	/// A created or relabelled terminal's projection, from hc (one `terminal.list`).
	private func refresh(_ id: String) {
		guard let (terminals, machines) = try? directory.rawListing() else { return }
		lock.lock()
		defer { lock.unlock() }
		for terminal in terminals {
			guard let agent = directory.project(terminal, machines: machines), let found = agent["id"] as? String, found == id
			else { continue }
			known[id] = agent
		}
	}

	private func applySnapshot(_ result: [String: Any]) {
		let terminals = (result["terminals"] as? [[String: Any]] ?? []).filter { $0["state"] as? String == "live" }
		let machines = (try? directory.rawListing().machines) ?? []
		var fresh: [String: [String: Any]] = [:]
		for terminal in terminals {
			guard let agent = directory.project(terminal, machines: machines), let id = agent["id"] as? String else { continue }
			fresh[id] = agent
		}
		lock.lock()
		let previous = known
		let first = connections <= 1 && previous.isEmpty
		known = fresh
		seq = WireJSON.strictInt(result["seq"]) ?? seq
		lock.unlock()
		guard !first else { return }
		var changedSet = Set(previous.keys) != Set(fresh.keys)
		for (id, agent) in fresh.sorted(by: { $0.key < $1.key }) {
			guard let before = previous[id] else { continue }
			if before["status"] as? String != agent["status"] as? String { emit("agent.status", Self.statusEvent(agent)) }
			if before["name"] as? String != agent["name"] as? String { changedSet = true }
		}
		if changedSet { emit("agents.changed", [:]) }
	}

	static func statusEvent(_ agent: [String: Any]) -> [String: Any] {
		var event: [String: Any] = [
			"id": agent["id"] ?? NSNull(), "status": agent["status"] ?? "unknown", "agent": agent["agent"] ?? NSNull(),
			"title": agent["title"] ?? NSNull(), "workspace_id": agent["workspace_id"] ?? NSNull(),
			"machine": agent["machine"] ?? NSNull(), "provider": "hc",
		]
		if let kind = agent["status_kind"] { event["status_kind"] = kind }
		return event
	}

	/// The agents as last seen (tests).
	func snapshot() -> [String: [String: Any]] {
		lock.lock()
		defer { lock.unlock() }
		return known
	}
}

// MARK: Terminal view

/// `hc attach --observe <address>` on a pseudo-terminal sized to the terminal: a live,
/// view-only mirror. Observe never types or resizes, so the owner's terminal is untouched;
/// the phone's keystrokes are dropped (prompts and keys go through the agent controls), and
/// fit mode stays a mirror.
final class HerdrCoreTerminalBackend: TerminalBackend, @unchecked Sendable {
	let provider = "hc"
	let readOnly = true
	private let cli: String
	private let address: String
	private let size: () -> TerminalSize?
	private let lock = NSLock()
	private var pty: PTYProcess?
	private var generation = 0
	private var current: TerminalSize?
	private var sink: (@Sendable (TerminalBackendEvent) -> Void)?
	private var stopped = false

	/// `size` reads the terminal's cells from hc (`terminal.get`).
	init(cli: String, address: String, size: @escaping () -> TerminalSize?) {
		self.cli = cli
		self.address = address
		self.size = size
	}

	var paneSize: TerminalSize? {
		lock.lock()
		defer { lock.unlock() }
		return current
	}

	func start(_ sink: @escaping @Sendable (TerminalBackendEvent) -> Void) throws {
		guard let window = size() else { throw APIError(404, "not_found", "agent not found") }
		lock.lock()
		self.sink = sink
		current = window
		lock.unlock()
		try attach(size: window)
		let thread = Thread { [weak self] in self?.follow() }
		thread.name = "link.terminal.hc-size"
		thread.start()
	}

	private func attach(size: TerminalSize) throws {
		let argv = [cli, "attach", "--observe", "--", address]
		let env = TerminalEnvironment.base().map { "\($0.key)=\($0.value)" }
		lock.lock()
		generation += 1
		let mine = generation
		let old = pty
		pty = nil
		lock.unlock()
		old?.close()
		let first = FirstOutput()
		let process = try PTYProcess(
			command: argv, environment: env, size: size,
			onOutput: { [weak self] data in
				guard let self else { return }
				self.lock.lock()
				let live = self.generation == mine && !self.stopped
				let sink = self.sink
				let size = self.current ?? size
				self.lock.unlock()
				if live { sink?(.output(data, full: first.take(), size: size)) }
			},
			onExit: { [weak self] in
				guard let self else { return }
				self.lock.lock()
				let live = self.generation == mine && !self.stopped
				let sink = self.sink
				self.lock.unlock()
				if live { sink?(.closed) }
			})
		lock.lock()
		pty = process
		lock.unlock()
	}

	private final class FirstOutput: @unchecked Sendable {
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

	/// Follows the terminal's size, so the mirror wraps where the Mac's view does.
	private func follow() {
		while true {
			Thread.sleep(forTimeInterval: 1)
			lock.lock()
			let done = stopped
			lock.unlock()
			if done { return }
			guard let window = size() else { continue }
			lock.lock()
			let changed = window != current
			current = window
			let pty = self.pty
			let sink = self.sink
			lock.unlock()
			guard changed else { continue }
			pty?.resize(window)
			sink?(.size(window))
		}
	}

	func write(_ data: Data) throws {}
	func resizePane(_ size: TerminalSize) throws {}
	func unfit(restore original: TerminalSize) throws {}

	func repaint() throws {
		lock.lock()
		let size = current
		lock.unlock()
		guard let size else { throw APIError(410, "terminal_closed", "the terminal has ended") }
		try attach(size: size)
	}

	func stop(restore original: TerminalSize?) {
		lock.lock()
		stopped = true
		let pty = self.pty
		self.pty = nil
		lock.unlock()
		pty?.close()
	}
}
