import Darwin
import Foundation
import WhisperaLink

/// `POST /v1/agents`, validated.
struct AgentStart: Equatable {
	var name: String
	var kind: String
	/// `local`, a herdr machine id, or nil (local, or the machine of a remote `paneID`).
	var machine: String?
	var paneID: String?
	var workspaceID: String?
	var cwd: String?
	var args: [String]
	var timeoutMS: Int
}

/// Where an agent id points: a pane of this Mac's herdr, or `m_<machine id>.<pane id>` — a pane
/// on another herdr machine reached through the herdr CLI.
enum AgentRef: Equatable {
	case local(String)
	case remote(machine: String, pane: String)

	static let remotePrefix = "m_"

	init(_ id: String) {
		if id.hasPrefix(Self.remotePrefix), let dot = id.firstIndex(of: ".") {
			let machine = String(id[id.index(id.startIndex, offsetBy: 2)..<dot])
			let pane = String(id[id.index(after: dot)...])
			if HerdrCLI.isValidMachineID(machine), !pane.isEmpty {
				self = .remote(machine: machine, pane: pane)
				return
			}
		}
		self = .local(id)
	}

	static func remoteID(machine: String, pane: String) -> String {
		remotePrefix + machine + "." + pane
	}
}

/// The herdr CLI, for the machines this Mac's herdr knows (`herdr machine list`) and every call
/// on them (`herdr --machine <id> agent …`, JSON on stdout). Each run has a hard timeout and is
/// killed with its whole process group when it overruns, so a hung ssh never holds a request.
final class HerdrCLI: @unchecked Sendable {
	struct Machine: Equatable {
		var id: String
		var label: String
	}

	static let listTimeout: TimeInterval = 8
	static let callTimeout: TimeInterval = 8
	static let promptWaitTimeout: TimeInterval = 35
	static let cacheTTL: TimeInterval = 5
	static let maxOutput = 8 * 1024 * 1024

	let path: String?
	private let lock = NSLock()
	private var machineCache: (at: Date, machines: [Machine])?

	init(configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
		path = Self.resolve(configured, environment: environment)
	}

	/// An absolute or relative path is used as given; a bare name is looked up on PATH, then
	/// in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin (launchd's PATH has none of them).
	static func resolve(_ configured: String, environment: [String: String]) -> String? {
		let name = configured.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty else { return nil }
		let manager = FileManager.default
		if name.contains("/") { return manager.isExecutableFile(atPath: name) ? name : nil }
		let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
		var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
		directories += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
		for directory in directories where !directory.isEmpty {
			let candidate = directory + "/" + name
			if manager.isExecutableFile(atPath: candidate) { return candidate }
		}
		return nil
	}

	static func isValidMachineID(_ id: String) -> Bool {
		(1...40).contains(id.utf8.count)
			&& id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
	}

	struct RunResult {
		var status: Int32
		var stdout: Data
		var stderr: Data
	}

	/// Runs the CLI with `arguments` (no shell), killing it and its children after `timeout`.
	func run(_ arguments: [String], timeout: TimeInterval) throws -> RunResult {
		guard let path else { throw APIError(503, "herdr_unavailable", "herdr CLI not found") }
		return try Self.spawn(path, arguments, timeout: timeout)
	}

	static func spawn(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> RunResult {
		var outPipe: [Int32] = [0, 0]
		var errPipe: [Int32] = [0, 0]
		guard pipe(&outPipe) == 0 else { throw APIError(500, "internal", "pipe failed") }
		guard pipe(&errPipe) == 0 else {
			Darwin.close(outPipe[0])
			Darwin.close(outPipe[1])
			throw APIError(500, "internal", "pipe failed")
		}
		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
		posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
		for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		// Its own process group, so a timeout kills ssh and whatever else it started.
		posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
		posix_spawnattr_setpgroup(&attributes, 0)
		let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
		defer { for pointer in argv { free(pointer) } }
		var pid: pid_t = 0
		let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
		Darwin.close(outPipe[1])
		Darwin.close(errPipe[1])
		defer {
			Darwin.close(outPipe[0])
			Darwin.close(errPipe[0])
		}
		guard spawned == 0 else { throw APIError(503, "herdr_unavailable", "herdr CLI could not start") }

		var out = Data()
		var err = Data()
		var open: [Int32] = [outPipe[0], errPipe[0]]
		let deadline = Date().addingTimeInterval(timeout)
		var timedOut = false
		var buffer = [UInt8](repeating: 0, count: 65536)
		while !open.isEmpty {
			let remaining = deadline.timeIntervalSinceNow
			if remaining <= 0 {
				timedOut = true
				break
			}
			var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
			let ready = poll(&fds, nfds_t(fds.count), Int32(min(remaining, 1) * 1000))
			if ready < 0 {
				if errno == EINTR { continue }
				break
			}
			for entry in fds where entry.revents != 0 {
				let count = read(entry.fd, &buffer, buffer.count)
				if count <= 0 {
					open.removeAll { $0 == entry.fd }
				} else if entry.fd == outPipe[0] {
					out.append(buffer, count: count)
				} else if err.count < 16 * 1024 {
					err.append(buffer, count: count)
				}
			}
			if out.count > maxOutput {
				timedOut = true
				break
			}
		}
		if timedOut { kill(-pid, SIGKILL) }
		var status: Int32 = 0
		while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
		if timedOut { throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s") }
		let exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
		return RunResult(status: exit, stdout: out, stderr: err)
	}

	/// The enabled machines (`herdr machine list --json`), cached `cacheTTL` seconds. No CLI,
	/// or a CLI that fails, means no machines.
	func machines() -> [Machine] {
		lock.lock()
		if let cache = machineCache, Date().timeIntervalSince(cache.at) < Self.cacheTTL {
			lock.unlock()
			return cache.machines
		}
		lock.unlock()
		var found: [Machine] = []
		if path != nil, let result = try? run(["machine", "list", "--json"], timeout: Self.listTimeout),
			result.status == 0,
			let list = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [[String: Any]]
		{
			for item in list where (item["enabled"] as? Bool) ?? false {
				guard let id = item["id"] as? String, Self.isValidMachineID(id),
					!found.contains(where: { $0.id == id })
				else { continue }
				let label = (item["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? id
				found.append(Machine(id: id, label: label))
			}
		}
		lock.lock()
		machineCache = (Date(), found)
		lock.unlock()
		return found
	}

	/// One API command on `machine`: `herdr --machine <id> <arguments…>`, answered like the
	/// socket (`{"result":{…}}` or `{"error":{"code","message"}}`).
	func call(machine: String, _ arguments: [String], timeout: TimeInterval = callTimeout) throws -> [String: Any] {
		let result = try run(["--machine", machine] + arguments, timeout: timeout)
		guard let object = WireJSON.decodeObject(Self.lastJSONLine(result.stdout)) else {
			let detail = String(decoding: result.stderr.prefix(200), as: UTF8.self)
				.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
			throw APIError(503, "herdr_unavailable", "machine unreachable" + (detail.isEmpty ? "" : ": " + detail))
		}
		if let error = object["error"] as? [String: Any] {
			throw HerdrClient.mapError(error["code"] as? String, error["message"] as? String)
		}
		return object["result"] as? [String: Any] ?? [:]
	}

	/// A command that prints plain text on success (`agent read`) and a JSON error otherwise.
	func text(machine: String, _ arguments: [String], timeout: TimeInterval = callTimeout) throws -> String {
		let result = try run(["--machine", machine] + arguments, timeout: timeout)
		if result.status != 0, let object = WireJSON.decodeObject(Self.lastJSONLine(result.stdout)),
			let error = object["error"] as? [String: Any]
		{
			throw HerdrClient.mapError(error["code"] as? String, error["message"] as? String)
		}
		guard result.status == 0 else {
			let detail = String(decoding: result.stderr.prefix(200), as: UTF8.self)
				.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
			throw APIError(503, "herdr_unavailable", "machine unreachable" + (detail.isEmpty ? "" : ": " + detail))
		}
		return String(decoding: result.stdout, as: UTF8.self)
	}

	/// The CLI may print progress before its JSON line.
	static func lastJSONLine(_ data: Data) -> Data {
		let lines = data.split(separator: UInt8(ascii: "\n")).filter { $0.first == UInt8(ascii: "{") }
		return lines.last.map { Data($0) } ?? data
	}
}

/// Every agent the phone can see: this Mac's herdr over its socket, plus each enabled herdr
/// machine through the CLI (contract §2). One unreachable machine never fails the list.
final class AgentDirectory: @unchecked Sendable {
	static let localLabel = "This Mac"

	let local: HerdrClient
	let cli: HerdrCLI
	private let log: OpsLog
	private let lock = NSLock()
	private var listCache: [String: (at: Date, result: Result<[[String: Any]], APIError>)] = [:]

	init(local: HerdrClient, cli: HerdrCLI, log: OpsLog = .null) {
		self.local = local
		self.cli = cli
		self.log = log
	}

	static func machineObject(_ id: String, _ label: String) -> [String: Any] { ["id": id, "label": label] }

	static func mapLocal(_ info: [String: Any]) -> [String: Any] {
		var agent = HerdrClient.mapAgent(info)
		agent["machine"] = machineObject(AgentMachine.localID, localLabel)
		return agent
	}

	static func mapRemote(_ info: [String: Any], machine: HerdrCLI.Machine) -> [String: Any] {
		var agent = HerdrClient.mapAgent(info)
		if let pane = info["pane_id"] as? String { agent["id"] = AgentRef.remoteID(machine: machine.id, pane: pane) }
		agent["machine"] = machineObject(machine.id, machine.label)
		return agent
	}

	private func machine(_ id: String) throws -> HerdrCLI.Machine {
		guard let found = cli.machines().first(where: { $0.id == id }) else {
			throw APIError(404, "not_found", "no such herdr machine")
		}
		return found
	}

	/// A machine's raw agent list, cached `HerdrCLI.cacheTTL` seconds (failures too).
	func remoteAgents(_ machine: HerdrCLI.Machine, fresh: Bool = false) -> Result<[[String: Any]], APIError> {
		lock.lock()
		if !fresh, let cached = listCache[machine.id], Date().timeIntervalSince(cached.at) < HerdrCLI.cacheTTL {
			lock.unlock()
			return cached.result
		}
		lock.unlock()
		let result: Result<[[String: Any]], APIError>
		do {
			let answer = try HerdrClient.expect(
				cli.call(machine: machine.id, ["agent", "list"], timeout: HerdrCLI.listTimeout), "agent_list")
			result = .success(answer["agents"] as? [[String: Any]] ?? [])
		} catch let error as APIError {
			result = .failure(error)
		} catch {
			result = .failure(APIError(503, "herdr_unavailable", "machine unreachable"))
		}
		lock.lock()
		listCache[machine.id] = (Date(), result)
		lock.unlock()
		return result
	}

	private func invalidate(_ machineID: String) {
		lock.lock()
		listCache[machineID] = nil
		lock.unlock()
	}

	/// `GET /v1/agents`.
	func list() throws -> [String: Any] {
		let machines = cli.machines()
		let results = ResultsBox(count: machines.count)
		let group = DispatchGroup()
		for (index, machine) in machines.enumerated() {
			group.enter()
			DispatchQueue.global().async {
				results.set(index, self.remoteAgents(machine))
				group.leave()
			}
		}
		var agents: [[String: Any]] = []
		var statuses: [[String: Any]] = []
		var version: Any = NSNull()
		do {
			let listed = try local.listAgents()
			agents = (listed["agents"] as? [[String: Any]] ?? []).map {
				var agent = $0
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				return agent
			}
			version = listed["herdr_version"] ?? NSNull()
			statuses.append(["id": AgentMachine.localID, "label": Self.localLabel, "status": "ok"])
		} catch let error as APIError {
			// Without other machines the list is this Mac's herdr, and its error is the answer.
			guard !machines.isEmpty else { throw error }
			statuses.append([
				"id": AgentMachine.localID, "label": Self.localLabel, "status": "unreachable", "error": error.message,
			])
		}
		group.wait()
		for (index, machine) in machines.enumerated() {
			switch results.get(index) {
			case .success(let raw):
				agents += raw.map { Self.mapRemote($0, machine: machine) }
				statuses.append(["id": machine.id, "label": machine.label, "status": "ok"])
			case .failure(let error):
				statuses.append([
					"id": machine.id, "label": machine.label, "status": "unreachable", "error": error.message,
				])
			case nil:
				statuses.append([
					"id": machine.id, "label": machine.label, "status": "unreachable", "error": "no answer",
				])
			}
		}
		return ["agents": agents, "herdr_version": version, "machines": statuses]
	}

	private final class ResultsBox: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [Result<[[String: Any]], APIError>?]
		init(count: Int) { values = Array(repeating: nil, count: count) }
		func set(_ index: Int, _ value: Result<[[String: Any]], APIError>) {
			lock.lock()
			values[index] = value
			lock.unlock()
		}
		func get(_ index: Int) -> Result<[[String: Any]], APIError>? {
			lock.lock()
			defer { lock.unlock() }
			return values[index]
		}
	}

	func get(_ id: String) throws -> [String: Any] {
		switch AgentRef(id) {
		case .local(let pane):
			var answer = try local.getAgent(pane)
			if var agent = answer["agent"] as? [String: Any] {
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				answer["agent"] = agent
			}
			return answer
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			let result = try HerdrClient.expect(cli.call(machine: machine.id, ["agent", "get", pane]), "agent_info")
			return ["agent": Self.mapRemote(result["agent"] as? [String: Any] ?? [:], machine: machine)]
		}
	}

	func read(_ id: String, source: String, lines: Int) throws -> [String: Any] {
		switch AgentRef(id) {
		case .local(let pane):
			return try local.read(pane, source: source, lines: lines)
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			do {
				return try readRemote(id, machine: machine, pane: pane, source: source, lines: lines)
			} catch let error as APIError
				where source != HerdrClient.visibleSource && HerdrClient.isBusyRead(error)
			{
				// Same refusal as the local socket's while the agent works (HerdrClient.read).
				var answer = try readRemote(
					id, machine: machine, pane: pane, source: HerdrClient.visibleSource, lines: lines)
				answer["truncated"] = true
				return answer
			}
		}
	}

	private func readRemote(_ id: String, machine: HerdrCLI.Machine, pane: String, source: String, lines: Int) throws
		-> [String: Any]
	{
		// `agent read` prints the text itself, not JSON; errors still come as JSON.
		let text = try cli.text(
			machine: machine.id,
			["agent", "read", pane, "--source", source, "--lines", String(lines), "--format", "text"])
		return ["id": id, "source": source, "text": text, "revision": NSNull(), "truncated": false]
	}

	func prompt(_ id: String, text: String, wait: (until: [String], timeoutMS: Int)?) throws -> [String: Any] {
		switch AgentRef(id) {
		case .local(let pane):
			var answer = try local.prompt(pane, text: text, wait: wait)
			if var agent = answer["agent"] as? [String: Any] {
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				answer["agent"] = agent
			}
			return answer
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			// The CLI reads options anywhere and has no `--`: text that looks like an option
			// would not reach the agent as typed.
			guard !text.hasPrefix("-") else {
				throw APIError(400, "bad_request", "a prompt for another machine cannot start with '-'")
			}
			var arguments = ["agent", "prompt", pane, text]
			var timeout = HerdrCLI.callTimeout
			if let wait {
				let ms = max(0, min(wait.timeoutMS, HerdrClient.maxPromptWaitMS))
				arguments += ["--wait"] + wait.until.flatMap { ["--until", $0] } + ["--timeout", String(ms)]
				timeout = HerdrCLI.promptWaitTimeout
			}
			defer { invalidate(machine.id) }
			let result = try HerdrClient.expect(cli.call(machine: machine.id, arguments, timeout: timeout), "agent_prompted")
			return [
				"agent": Self.mapRemote(result["agent"] as? [String: Any] ?? [:], machine: machine), "waited": wait != nil,
			]
		}
	}

	func sendKeys(_ id: String, keys: [String]) throws -> [String: Any] {
		switch AgentRef(id) {
		case .local(let pane):
			return try local.sendKeys(pane, keys: keys)
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			defer { invalidate(machine.id) }
			guard !keys.contains(where: { $0.hasPrefix("-") }) else {
				throw APIError(400, "bad_request", "keys must be key names such as esc, enter or ctrl+c")
			}
			_ = try cli.call(machine: machine.id, ["agent", "send-keys", pane] + keys)
			return ["id": id, "keys": keys.count]
		}
	}

	/// Starts an agent; without a pane, in the root pane of a new tab (`tab.create`).
	func start(_ request: AgentStart) throws -> [String: Any] {
		var machineID = request.machine.flatMap { $0 == AgentMachine.localID ? nil : $0 }
		var pane = request.paneID
		if let given = pane, case .remote(let owner, let raw) = AgentRef(given) {
			guard machineID == nil || machineID == owner else {
				throw APIError(400, "bad_request", "pane_id is on another machine")
			}
			machineID = owner
			pane = raw
		}
		guard let machineID else {
			let target = try pane ?? local.createTab(workspaceID: request.workspaceID, cwd: request.cwd, label: request.name)
			var answer = try local.start(
				name: request.name, kind: request.kind, paneID: target, args: request.args, timeoutMS: request.timeoutMS)
			if var agent = answer["agent"] as? [String: Any] {
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				answer["agent"] = agent
			}
			return answer
		}
		let machine = try machine(machineID)
		defer { invalidate(machine.id) }
		let target: String
		if let pane {
			target = pane
		} else {
			var arguments = ["tab", "create", "--label", request.name, "--no-focus"]
			if let workspace = request.workspaceID { arguments += ["--workspace", workspace] }
			if let cwd = request.cwd { arguments += ["--cwd", cwd] }
			let created = try HerdrClient.expect(cli.call(machine: machine.id, arguments), "tab_created")
			guard let root = (created["root_pane"] as? [String: Any])?["pane_id"] as? String else {
				throw APIError(502, "herdr_error", "tab.create returned no root pane", extra: ["herdr_code": "unexpected_type"])
			}
			target = root
		}
		var arguments = [
			"agent", "start", request.name, "--kind", request.kind, "--pane", target, "--timeout", String(request.timeoutMS),
		]
		if !request.args.isEmpty { arguments += ["--"] + request.args }
		let result = try HerdrClient.expect(
			cli.call(machine: machine.id, arguments, timeout: Double(request.timeoutMS) / 1000 + HerdrCLI.callTimeout),
			"agent_started")
		return ["agent": Self.mapRemote(result["agent"] as? [String: Any] ?? [:], machine: machine)]
	}
}

/// Polls the remote herdr machines while a phone listens (an SSE stream is open) and publishes
/// what changed as the same `agent.status` / `agents.changed` events the local subscription
/// sends.
final class RemoteAgentPoller: @unchecked Sendable {
	private let directory: AgentDirectory
	private let interval: TimeInterval
	private let isListening: () -> Bool
	private let emit: (String, [String: Any]) -> Void
	private let lock = NSLock()
	private var stopped = false
	private let wake = DispatchSemaphore(value: 0)
	/// remote agent id → status, per machine; nil entry = machine unreachable last time.
	private var baseline: [String: [String: String]?]?

	init(
		directory: AgentDirectory, interval: TimeInterval, isListening: @escaping () -> Bool,
		emit: @escaping (String, [String: Any]) -> Void
	) {
		self.directory = directory
		self.interval = interval
		self.isListening = isListening
		self.emit = emit
	}

	func start() {
		let thread = Thread { [self] in
			while !isStopped {
				if isListening() { pollOnce() } else { reset() }
				_ = wake.wait(timeout: .now() + interval)
			}
		}
		thread.name = "herdr-remote-poll"
		thread.start()
	}

	func stop() {
		lock.lock()
		stopped = true
		lock.unlock()
		wake.signal()
	}

	private var isStopped: Bool {
		lock.lock()
		defer { lock.unlock() }
		return stopped
	}

	private func reset() {
		lock.lock()
		baseline = nil
		lock.unlock()
	}

	/// One poll: the first only records what is there.
	func pollOnce() {
		var now: [String: [String: String]?] = [:]
		var agents: [String: [String: Any]] = [:]
		for machine in directory.cli.machines() {
			switch directory.remoteAgents(machine, fresh: true) {
			case .success(let raw):
				var statuses: [String: String] = [:]
				for info in raw {
					let agent = AgentDirectory.mapRemote(info, machine: machine)
					guard let id = agent["id"] as? String else { continue }
					statuses[id] = agent["status"] as? String ?? "unknown"
					agents[id] = agent
				}
				now[machine.id] = statuses
			case .failure:
				now[machine.id] = .some(nil)
			}
		}
		lock.lock()
		let previous = baseline
		baseline = now
		lock.unlock()
		guard let previous else { return }
		var changedSet = Set(previous.keys) != Set(now.keys)
		for (machine, current) in now {
			let before = previous[machine] ?? nil
			guard let current else {
				if before != nil { changedSet = true }
				continue
			}
			guard let before else {
				changedSet = true
				continue
			}
			if Set(before.keys) != Set(current.keys) { changedSet = true }
			for (id, status) in current.sorted(by: { $0.key < $1.key }) {
				guard let old = before[id], old != status, let agent = agents[id] else { continue }
				emit(
					"agent.status",
					[
						"id": id, "status": status, "agent": agent["agent"] ?? NSNull(), "title": agent["title"] ?? NSNull(),
						"workspace_id": agent["workspace_id"] ?? NSNull(), "machine": agent["machine"] ?? NSNull(),
					])
			}
		}
		if changedSet { emit("agents.changed", [:]) }
	}
}
