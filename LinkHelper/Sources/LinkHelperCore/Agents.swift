import Darwin
import Foundation
import WhisperaLink
import WhisperaAgents
import WhisperaHerdr

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
	/// `herdr` or `hc`; nil lets the Mac choose (`AgentDirectory.startsOnHerdrCore`).
	var provider: String? = nil
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
		var target: String? = nil
		/// herdr's session on that machine; the direct path only runs on the default one.
		var session: String? = nil
	}

	static let listTimeout: TimeInterval = 8
	static let callTimeout: TimeInterval = 8
	static let promptWaitTimeout: TimeInterval = 35
	static let cacheTTL: TimeInterval = 5
	static let maxOutput = 8 * 1024 * 1024

	/// Concurrent CLI runs per machine: a burst of phone requests queues here instead of
	/// opening a dozen ssh connections at once.
	static let maxConcurrentPerMachine = 4
	/// How long the direct path stays off for a machine whose remote herdr it could not find.
	static let directBackoff: TimeInterval = 300

	let path: String?
	/// ssh for the direct path (`ssh <target> herdr …`, one connection per call or batch);
	/// nil runs every call through `herdr --machine`.
	let sshPath: String?
	private let lock = NSLock()
	private var machineCache: (at: Date, machines: [Machine])?
	private var gates: [String: DispatchSemaphore] = [:]
	private var directOff: [String: Date] = [:]

	init(configured: String, ssh: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
		path = Self.resolve(configured, environment: environment)
		sshPath = ssh.flatMap { $0.isEmpty ? nil : $0 }.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
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

	/// Runs the CLI with `arguments` (no shell), killing it and its children after `timeout`, or
	/// as soon as the request it serves is cancelled (`CancelToken.current`).
	func run(_ arguments: [String], timeout: TimeInterval) throws -> RunResult {
		guard let path else { throw APIError(503, "herdr_unavailable", "herdr CLI not found") }
		return try Self.spawn(path, arguments, timeout: timeout)
	}

	static func spawn(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> RunResult {
		let token = CancelToken.current
		try token?.check()
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
		// The whole group (ssh, scp and what they started) dies with the request. The kill and
		// the reap take the same lock, so a late cancel never signals a recycled process group.
		let child = SpawnedGroup(pid: pid)
		let cancelHandler = token?.onCancel { child.kill() }
		defer { if let cancelHandler { token?.removeHandler(cancelHandler) } }

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
		if timedOut { child.kill() }
		let status = child.reap()
		if let reason = token?.reason { throw RequestCancelled(reason: reason) }
		if timedOut { throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s") }
		let exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
		return RunResult(status: exit, stdout: out, stderr: err)
	}

	/// A spawned process group that is killed at most until it is reaped.
	final class SpawnedGroup: @unchecked Sendable {
		private let pid: pid_t
		private let lock = NSLock()
		private var reaped = false

		init(pid: pid_t) { self.pid = pid }

		func kill() {
			lock.lock()
			defer { lock.unlock() }
			if !reaped { Darwin.kill(-pid, SIGKILL) }
		}

		/// Waits for the process and returns its wait status.
		func reap() -> Int32 {
			var status: Int32 = 0
			while true {
				lock.lock()
				let result = waitpid(pid, &status, WNOHANG)
				if result == pid || (result < 0 && errno != EINTR) { reaped = true }
				let done = reaped
				lock.unlock()
				if done { return status }
				usleep(5_000)
			}
		}
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
		// Cached for everyone: a cancelled request must not leave an empty list behind.
		if path != nil, let result = try? CancelToken.withoutCancellation({ try run(["machine", "list", "--json"], timeout: Self.listTimeout) }),
			result.status == 0,
			let list = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [[String: Any]]
		{
			for item in list where (item["enabled"] as? Bool) ?? false {
				guard let id = item["id"] as? String, Self.isValidMachineID(id),
					!found.contains(where: { $0.id == id })
				else { continue }
				let label = (item["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? id
				found.append(
					Machine(id: id, label: label, target: item["target"] as? String, session: item["session"] as? String))
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
		try Self.answer(try remote(machine, arguments, timeout: timeout))
	}

	static func answer(_ result: RunResult) throws -> [String: Any] {
		if let error = herdrError(result) { throw error }
		guard let object = WireJSON.decodeObject(lastJSONLine(result.stdout)) else {
			throw unreachable(result)
		}
		return object["result"] as? [String: Any] ?? [:]
	}

	/// A command that prints plain text on success (`agent read`) and a JSON error otherwise.
	func text(machine: String, _ arguments: [String], timeout: TimeInterval = callTimeout) throws -> String {
		let result = try remote(machine, arguments, timeout: timeout)
		guard result.status == 0 else { throw Self.herdrError(result) ?? Self.unreachable(result) }
		return String(decoding: result.stdout, as: UTF8.self)
	}

	/// Read-only commands on one machine in one round trip (direct path), else each through
	/// `herdr --machine`, concurrently. `timeouts[i]` bounds command i on the fallback path;
	/// the direct batch gets the longest of them.
	func batch(machine: String, _ commands: [[String]], timeouts: [TimeInterval]) -> [Result<[String: Any], APIError>] {
		precondition(commands.count == timeouts.count)
		if let direct = directBatch(machine, commands, timeout: timeouts.max() ?? Self.callTimeout, stderr: true) {
			return direct.map { $0.flatMap { segment in Result { try Self.answer(segment) }.mapError(Self.apiError) } }
		}
		let results = BatchBox(count: commands.count)
		let token = CancelToken.current
		DispatchQueue.concurrentPerform(iterations: commands.count) { index in
			CancelToken.with(token) {
				results.set(index, Result { try call(machine: machine, commands[index], timeout: timeouts[index]) }.mapError(Self.apiError))
			}
		}
		return results.all
	}

	/// Plain-text commands (`agent read`) in one round trip; a command that did not succeed
	/// there is run again on its own, for herdr's own error. Nil: no direct path.
	func batchText(machine: String, _ commands: [[String]], timeout: TimeInterval = callTimeout) -> [Result<String, APIError>]? {
		guard let direct = directBatch(machine, commands, timeout: timeout, stderr: false) else { return nil }
		return zip(commands, direct).map { command, result in
			switch result {
			case .success(let segment) where segment.status == 0:
				return .success(String(decoding: Self.trimSegment(segment.stdout), as: UTF8.self))
			case .failure(let error):
				return .failure(error)
			case .success:
				return Result { try text(machine: machine, command, timeout: timeout) }.mapError(Self.apiError)
			}
		}
	}

	/// A segment ends with the newline the end marker's printf starts with.
	static func trimSegment(_ data: Data) -> Data {
		var data = data
		if data.last == UInt8(ascii: "\n") { data.removeLast() }
		return data
	}

	/// Nil when the direct path does not apply or found no herdr (the caller falls back);
	/// otherwise one result per command, or every command failed with the connection's error.
	/// `stderr`: fold each command's stderr into its output (JSON commands), else drop it.
	private func directBatch(_ machine: String, _ commands: [[String]], timeout: TimeInterval, stderr: Bool)
		-> [Result<RunResult, APIError>]?
	{
		guard let target = directTarget(machine) else { return nil }
		do {
			return try withGate(machine, timeout: timeout) {
				let result = try Self.spawnDirect(
					sshPath!, target, commands, timeout: timeout, batch: true, stderr: stderr)
				switch Self.classify(result) {
				case .answer:
					let segments = Self.segments(result.stdout, count: commands.count)
					if segments.count == commands.count { return segments.map { .success($0) } }
					disableDirect(machine)
					return nil
				case .unsupported:
					disableDirect(machine)
					return nil
				case .unreachable:
					let error = Self.unreachable(result)
					return commands.map { _ in .failure(error) }
				}
			}
		} catch {
			let error = Self.apiError(error)
			return commands.map { _ in .failure(error) }
		}
	}

	private final class BatchBox: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [Result<[String: Any], APIError>]
		init(count: Int) { values = Array(repeating: .failure(APIError(503, "herdr_unavailable", "no answer")), count: count) }
		func set(_ index: Int, _ value: Result<[String: Any], APIError>) {
			lock.lock()
			values[index] = value
			lock.unlock()
		}
		var all: [Result<[String: Any], APIError>] {
			lock.lock()
			defer { lock.unlock() }
			return values
		}
	}

	static func apiError(_ error: Error) -> APIError {
		error as? APIError ?? APIError(503, "herdr_unavailable", "machine unreachable")
	}

	// MARK: Direct path

	/// One command on `machine`: over the direct path when it applies (one ssh connection,
	/// about one network round trip), else `herdr --machine`, which opens several ssh
	/// connections in a row per call. Only a remote with no herdr found falls back; a refused
	/// connection is the machine's answer, so a key is never sent twice.
	func remote(_ machine: String, _ arguments: [String], timeout: TimeInterval) throws -> RunResult {
		try withGate(machine, timeout: timeout) {
			if let target = directTarget(machine) {
				let result = try Self.spawnDirect(sshPath!, target, [arguments], timeout: timeout)
				switch Self.classify(result) {
				case .answer, .unreachable:
					var stripped = result
					stripped.stdout = Self.afterReady(result.stdout) ?? result.stdout
					return stripped
				case .unsupported:
					disableDirect(machine)
				}
			}
			return try run(["--machine", machine] + arguments, timeout: timeout)
		}
	}

	private func withGate<T>(_ machine: String, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
		lock.lock()
		let gate = gates[machine] ?? DispatchSemaphore(value: Self.maxConcurrentPerMachine)
		gates[machine] = gate
		lock.unlock()
		guard gate.wait(timeout: .now() + timeout) == .success else {
			throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s")
		}
		defer { gate.signal() }
		return try body()
	}

	/// A read-only sh script on `machine` over the direct ssh path, without herdr (the session
	/// logs of its agents). Compressed: logs are text. Throws when the path doesn't apply or
	/// the machine can't be reached.
	func shell(machine: String, script: String, timeout: TimeInterval) throws -> Data {
		guard let ssh = sshPath, let target = sshTarget(machine) else {
			throw APIError(503, "herdr_unavailable", "no ssh path to this machine")
		}
		return try withGate(machine, timeout: timeout) {
			try Self.spawnShell(ssh, target, script, timeout: timeout).stdout
		}
	}

	static func spawnShell(_ ssh: String, _ target: String, _ script: String, timeout: TimeInterval) throws -> RunResult {
		guard isValidTarget(target), !script.contains("\0") else { throw APIError(400, "bad_request", "bad ssh target") }
		let connect = max(1, min(5, Int(timeout.rounded(.down)) - 1))
		let result = try spawn(
			ssh,
			[
				"-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connect)", "-o", "ServerAliveInterval=5",
				"-o", "ServerAliveCountMax=2", "-o", "LogLevel=ERROR", "-o", "Compression=yes", "-T", "--", target, script,
			],
			timeout: timeout)
		guard result.status == 0 else { throw unreachable(result) }
		return result
	}

	/// The machine's saved ssh target on herdr's default session (any herdr on it or not).
	func sshTarget(_ machine: String) -> String? {
		guard let found = machines().first(where: { $0.id == machine }), let target = found.target, Self.isValidTarget(target),
			found.session == nil || found.session == "default"
		else { return nil }
		return target
	}

	/// The machine's ssh target when the direct path applies: ssh configured, a plain target,
	/// herdr's default session and no recent "herdr not found".
	func directTarget(_ machine: String) -> String? {
		guard sshPath != nil, let target = sshTarget(machine) else { return nil }
		lock.lock()
		defer { lock.unlock() }
		if let until = directOff[machine], until > Date() { return nil }
		return target
	}

	private func disableDirect(_ machine: String) {
		lock.lock()
		directOff[machine] = Date().addingTimeInterval(Self.directBackoff)
		lock.unlock()
	}

	static func isValidTarget(_ target: String) -> Bool {
		!target.isEmpty && !target.hasPrefix("-") && target.utf8.count <= 255
			&& target.unicodeScalars.allSatisfy {
				$0.isASCII && (CharacterSet.alphanumerics.contains($0) || "@._-:[]".unicodeScalars.contains($0))
			}
	}

	static let readyMarker = "whispera-link-herdr-ready"
	static let endMarker = "whispera-link-herdr-end"
	static let notFound = "whispera-link: herdr not found"

	/// POSIX single quotes: nothing inside is expanded.
	static func shellQuote(_ text: String) -> String {
		"'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// The remote shell script: finds herdr (a non-interactive ssh shell's PATH rarely has
	/// ~/.local/bin), prints a ready marker so login-shell noise is skipped, then runs one
	/// command as herdr itself (`exec`: its stdout, stderr and exit status) or several, each
	/// followed by an end marker with its exit status (their stderr folded into stdout).
	static func directScript(_ commands: [[String]], batch: Bool = false, stderr: Bool = true) -> String {
		var script =
			#"H=$(command -v herdr 2>/dev/null); for C in "$H" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do [ -n "$C" ] && [ -x "$C" ] && break; C=; done; "#
			+ #"[ -n "$C" ] || { echo '"# + notFound + #"' >&2; exit 127; }; "#
			+ "printf '\\n%s\\n' '" + readyMarker + "'; "
		let quoted = commands.map { $0.map(shellQuote).joined(separator: " ") }
		if !batch, quoted.count == 1 {
			script += #"exec "$C" "# + quoted[0]
		} else {
			for command in quoted {
				script += #""$C" "# + command + (stderr ? " 2>&1" : " 2>/dev/null") + "; printf '\\n%s %s\\n' '" + endMarker + #"' "$?"; "#
			}
		}
		return script
	}

	static func spawnDirect(
		_ ssh: String, _ target: String, _ commands: [[String]], timeout: TimeInterval, batch: Bool = false, stderr: Bool = true
	) throws -> RunResult {
		guard commands.allSatisfy({ $0.allSatisfy { !$0.contains("\0") } }) else {
			throw APIError(400, "bad_request", "arguments cannot contain NUL")
		}
		let connect = max(1, min(5, Int(timeout.rounded(.down)) - 1))
		return try spawn(
			ssh,
			[
				"-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connect)", "-o", "ServerAliveInterval=5",
				"-o", "ServerAliveCountMax=2", "-o", "LogLevel=ERROR", "-T", "--", target, directScript(commands, batch: batch, stderr: stderr),
			],
			timeout: timeout)
	}

	enum DirectOutcome { case answer, unsupported, unreachable }

	/// A herdr answer (the ready marker came back), no herdr on the remote, or no remote.
	static func classify(_ result: RunResult) -> DirectOutcome {
		if afterReady(result.stdout) != nil { return .answer }
		// Exit 0 without the marker: a shell that ran something else. Neither ran herdr.
		if result.status == 0 || (result.status == 127 && String(decoding: result.stderr, as: UTF8.self).contains(notFound)) {
			return .unsupported
		}
		return .unreachable
	}

	/// Output after the ready marker line; nil without one.
	static func afterReady(_ data: Data) -> Data? {
		let marker = Data(("\n" + readyMarker + "\n").utf8)
		guard let range = data.range(of: marker) else { return nil }
		return data.subdata(in: range.upperBound..<data.endIndex)
	}

	/// A batch's output split at its end markers into one result per command.
	static func segments(_ data: Data, count: Int) -> [RunResult] {
		guard let body = afterReady(data) else { return [] }
		var results: [RunResult] = []
		var current = Data()
		for line in body.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
			let text = String(decoding: line, as: UTF8.self)
			if text.hasPrefix(endMarker + " "), let status = Int32(text.dropFirst(endMarker.count + 1)) {
				results.append(RunResult(status: status, stdout: current, stderr: current))
				current = Data()
			} else {
				current.append(contentsOf: line)
				current.append(UInt8(ascii: "\n"))
			}
		}
		return results.count == count ? results : []
	}

	/// herdr's own `{"error":{…}}` answer. The CLI prints it on stderr with a non-zero exit
	/// (herdr 0.9.1, `--machine` and local alike) and older builds printed it on stdout, so
	/// both are checked; a refusal is a herdr answer, never an unreachable machine.
	static func herdrError(_ result: RunResult) -> APIError? {
		for stream in [result.stderr, result.stdout] {
			if let object = WireJSON.decodeObject(lastJSONLine(stream)), let error = object["error"] as? [String: Any] {
				return HerdrClient.mapError(error["code"] as? String, error["message"] as? String)
			}
		}
		return nil
	}

	/// No herdr answer at all: ssh or the remote herdr is down.
	static func unreachable(_ result: RunResult) -> APIError {
		let detail = String(decoding: result.stderr.prefix(200), as: UTF8.self)
			.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
		return APIError(503, "herdr_unavailable", "machine unreachable" + (detail.isEmpty ? "" : ": " + detail))
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
	let tmux: TmuxDirectory?
	/// herdr-core's terminals, here and on the machines its core is connected to.
	let hc: HerdrCoreDirectory?
	private let log: OpsLog
	private let lock = NSLock()
	private var listCache: [String: (at: Date, result: Result<[[String: Any]], APIError>)] = [:]
	/// The machine lists being fetched: every caller that needs one waits for the same fetch.
	private var flights: [String: Flight] = [:]
	/// How long a machine's last good list is served (marked `stale`) while a newer one is
	/// fetched in the background.
	static let staleTTL: TimeInterval = 60
	/// The clock of the list cache (tests move it).
	var now: () -> Date = Date.init
	/// The verified interrupt, stop and start (tests shorten its timing).
	var control = AgentControl()

	init(local: HerdrClient, cli: HerdrCLI, log: OpsLog = .null, tmux: TmuxDirectory? = nil, hc: HerdrCoreDirectory? = nil) {
		self.local = local
		self.tmux = tmux
		self.hc = hc
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

	private final class Flight: @unchecked Sendable {
		let done = DispatchGroup()
		var result: Result<[[String: Any]], APIError>?
	}

	/// A machine's raw agent list, cached `HerdrCLI.cacheTTL` seconds (failures too).
	/// `fresh` skips the cache (the status poller) but still joins a fetch under way.
	func remoteAgents(_ machine: HerdrCLI.Machine, fresh: Bool = false) -> Result<[[String: Any]], APIError> {
		remoteListing(machine, fresh: fresh).result
	}

	/// The list plus whether it is a last-known one: a good list older than `cacheTTL` but
	/// younger than `staleTTL` is answered at once while a background fetch replaces it, so a
	/// phone never waits on ssh for a list it saw a few seconds ago.
	func remoteListing(_ machine: HerdrCLI.Machine, fresh: Bool = false) -> (
		result: Result<[[String: Any]], APIError>, stale: Bool
	) {
		let now = self.now()
		lock.lock()
		if !fresh, let cached = listCache[machine.id] {
			let age = now.timeIntervalSince(cached.at)
			if age < HerdrCLI.cacheTTL {
				lock.unlock()
				return (cached.result, false)
			}
			if case .success = cached.result, age < Self.staleTTL {
				lock.unlock()
				refreshInBackground(machine)
				return (cached.result, true)
			}
		}
		lock.unlock()
		return (fetch(machine), false)
	}

	private func refreshInBackground(_ machine: HerdrCLI.Machine) {
		lock.lock()
		let running = flights[machine.id] != nil
		lock.unlock()
		guard !running else { return }
		DispatchQueue.global(qos: .utility).async { _ = self.fetch(machine) }
	}

	/// One fetch per machine at a time; callers that arrive while it runs share its answer.
	private func fetch(_ machine: HerdrCLI.Machine) -> Result<[[String: Any]], APIError> {
		lock.lock()
		if let flight = flights[machine.id] {
			lock.unlock()
			flight.done.wait()
			return flight.result ?? .failure(APIError(503, "herdr_unavailable", "machine unreachable"))
		}
		let flight = Flight()
		flight.done.enter()
		flights[machine.id] = flight
		lock.unlock()
		// Shared with every caller that arrives meanwhile, and cached: one phone's cancel must
		// not fail (or poison) the others' list.
		let result = CancelToken.withoutCancellation { load(machine) }
		lock.lock()
		listCache[machine.id] = (self.now(), result)
		flights[machine.id] = nil
		flight.result = result
		lock.unlock()
		flight.done.leave()
		return result
	}

	/// `agent list`, `workspace list` and `tab list` in one round trip (labels are optional:
	/// their failure never fails the list).
	private func load(_ machine: HerdrCLI.Machine) -> Result<[[String: Any]], APIError> {
		let answers = cli.batch(
			machine: machine.id, [["agent", "list"], ["workspace", "list"], ["tab", "list"]],
			timeouts: [HerdrCLI.listTimeout, 2, 2])
		do {
			let answer = try HerdrClient.expect(try answers[0].get(), "agent_list")
			let workspaces = (try? answers[1].get())?["workspaces"] as? [[String: Any]] ?? []
			let tabs = (try? answers[2].get())?["tabs"] as? [[String: Any]] ?? []
			return .success(HerdrTUIProvider.named(answer["agents"] as? [[String: Any]] ?? [], workspaces: workspaces, tabs: tabs))
		} catch {
			return .failure(HerdrCLI.apiError(error))
		}
	}

    private func mapNamedRemote(_ info: [String: Any], machine: HerdrCLI.Machine) -> [String: Any] {
        var info = info
        if case .success(let cached) = remoteAgents(machine), let matching = cached.first(where: { ($0["pane_id"] as? String) == (info["pane_id"] as? String) }) {
            for key in ["workspace_label", "tab_label"] { if let value = matching[key] { info[key] = value } }
        }
        return Self.mapRemote(info, machine: machine)
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
				results.set(index, self.remoteListing(machine))
				group.leave()
			}
		}
		// herdr-core answers for itself, beside this Mac's herdr: down or absent, it adds
		// nothing and fails nothing.
		let hcBox = HerdrCoreListing()
		if let hc {
			group.enter()
			DispatchQueue.global().async {
				hcBox.set(Result { try hc.list() })
				group.leave()
			}
		}
		let tmuxAgents = (try? tmux?.list()) ?? []
		var agents: [[String: Any]] = []
		var statuses: [[String: Any]] = []
		var version: Any = NSNull()
		var herdrUp = false
		do {
			let listed = try local.listAgents()
			herdrUp = true
			agents = (listed["agents"] as? [[String: Any]] ?? []).map {
				var agent = $0
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				return agent
			}
			version = listed["herdr_version"] ?? NSNull()
			statuses.append(["id": AgentMachine.localID, "label": Self.localLabel, "status": "ok"])
		} catch let error as APIError {
			// Without other machines the list is this Mac's herdr, and its error is the answer.
			if hc != nil { group.wait() }
			let hcListed = try? hcBox.get()?.get()
			guard !machines.isEmpty || !tmuxAgents.isEmpty || hcListed != nil else { throw error }
			// This Mac still answers through herdr-core when only the old herdr is down.
			statuses.append(
				hcListed != nil
					? ["id": AgentMachine.localID, "label": Self.localLabel, "status": "ok"]
					: ["id": AgentMachine.localID, "label": Self.localLabel, "status": "unreachable", "error": error.message])
		}
		agents += tmuxAgents
		group.wait()
		var hcListed: (agents: [[String: Any]], machines: [[String: Any]])?
		var hcError: APIError?
		switch hcBox.get() {
		case .success(let listed)?: hcListed = listed
		case .failure(let error)?: hcError = error as? APIError
		case nil: break
		}
		agents += hcListed?.agents ?? []
		for (index, machine) in machines.enumerated() {
			switch results.get(index) {
			case .some((.success(let raw), let stale)):
				agents += raw.map { Self.mapRemote($0, machine: machine) }
				var status: [String: Any] = ["id": machine.id, "label": machine.label, "status": "ok"]
				// A last-known list while a newer one is fetched.
				if stale { status["stale"] = true }
				statuses.append(status)
			case .some((.failure(let error), _)):
				statuses.append([
					"id": machine.id, "label": machine.label, "status": "unreachable", "error": error.message,
				])
			case nil:
				statuses.append([
					"id": machine.id, "label": machine.label, "status": "unreachable", "error": "no answer",
				])
			}
		}
		// hc's other machines, unless herdr already lists a machine of that name.
		let listedMachines = Set(statuses.compactMap { $0["id"] as? String })
		statuses += (hcListed?.machines ?? []).filter { !listedMachines.contains($0["id"] as? String ?? "") }
		var providers: [[String: Any]] = [["id": "herdr", "status": herdrUp ? "up" : "down"]]
		if let hc {
			var row: [String: Any] = ["id": "hc", "status": hcListed != nil ? "up" : (hcError?.code == "hc_unavailable" ? "absent" : "down")]
			if let version = hc.capabilities?.version, hcListed != nil { row["version"] = version }
			providers.append(row)
		}
		if tmux != nil { providers.append(["id": "tmux", "status": "up"]) }
		return ["agents": agents, "herdr_version": version, "machines": statuses, "providers": providers]
	}

	/// The herdr-core directory for an `hc:` id; nil for every other id.
	func hcDirectory(_ id: String) throws -> HerdrCoreDirectory? {
		guard HerdrCoreID.isHerdrCore(id) else { return nil }
		guard let hc else { throw APIError(503, "hc_unavailable", "herdr-core is not set up on this Mac") }
		return hc
	}

	private final class HerdrCoreListing: @unchecked Sendable {
		private let lock = NSLock()
		private var value: Result<(agents: [[String: Any]], machines: [[String: Any]]), Error>?
		func set(_ result: Result<(agents: [[String: Any]], machines: [[String: Any]]), Error>) {
			lock.lock()
			value = result
			lock.unlock()
		}
		func get() -> Result<(agents: [[String: Any]], machines: [[String: Any]]), Error>? {
			lock.lock()
			defer { lock.unlock() }
			return value
		}
	}

	private final class ResultsBox: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [(Result<[[String: Any]], APIError>, Bool)?]
		init(count: Int) { values = Array(repeating: nil, count: count) }
		func set(_ index: Int, _ value: (result: Result<[[String: Any]], APIError>, stale: Bool)) {
			lock.lock()
			values[index] = (value.result, value.stale)
			lock.unlock()
		}
		func get(_ index: Int) -> (Result<[[String: Any]], APIError>, Bool)? {
			lock.lock()
			defer { lock.unlock() }
			return values[index]
		}
	}

	func get(_ id: String) throws -> [String: Any] {
        if id.hasPrefix("tmux:") {
            guard let transport = tmux else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
            return ["agent": try transport.get(id)]
        }
		if let hc = try hcDirectory(id) { return ["agent": try hc.get(id)] }
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
			return ["agent": mapNamedRemote(result["agent"] as? [String: Any] ?? [:], machine: machine)]
		}
	}

	/// A remote pane's raw herdr info from the machine's (possibly last-known) list; nil when
	/// the pane isn't in it. Throws `not_found` for an unknown machine, else its list's error.
	func remoteAgentInfo(machine machineID: String, pane: String) throws -> [String: Any]? {
		let machine = try machine(machineID)
		return try remoteListing(machine).result.get().first { $0["pane_id"] as? String == pane }
	}

	/// `ansi` asks for SGR colors; tmux panes always answer plain text (`"format":"text"`).
	func read(_ id: String, source: String, lines: Int, ansi: Bool = false) throws -> [String: Any] {
        if id.hasPrefix("tmux:") {
            guard let transport = tmux else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
            var answer = try transport.read(id, source: source, lines: lines)
            answer["format"] = "text"
            return answer
        }
		if let hc = try hcDirectory(id) { return try hc.read(id, source: source, lines: lines) }
		switch AgentRef(id) {
		case .local(let pane):
			return try local.read(pane, source: source, lines: lines, ansi: ansi)
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			do {
				return try readRemote(id, machine: machine, pane: pane, source: source, lines: lines, ansi: ansi)
			} catch let error as APIError
				where source != HerdrClient.visibleSource && HerdrClient.isBusyRead(error)
			{
				// Same refusal as the local socket's while the agent works (HerdrClient.read).
				var answer = try readRemote(
					id, machine: machine, pane: pane, source: HerdrClient.visibleSource, lines: lines, ansi: ansi)
				answer["truncated"] = true
				answer["historyPartial"] = true
				return answer
			}
		}
	}

	private func readRemote(
		_ id: String, machine: HerdrCLI.Machine, pane: String, source: String, lines: Int, ansi: Bool
	) throws -> [String: Any] {
		// `agent read` prints the text itself, not JSON; errors still come as JSON.
		let format = ansi ? "ansi" : "text"
		let text = try cli.text(
			machine: machine.id,
			["agent", "read", pane, "--source", source, "--lines", String(lines), "--format", format])
		return [
			"id": id, "source": source, "text": text, "revision": NSNull(), "truncated": false, "format": format,
		]
	}

	/// Copy selected images to the saved SSH machine before submitting its prompt. The
	/// phone cannot choose a host or destination path: both come from trusted Mac state.
	func imagePaths(_ id: String, paths: [String], device: String) throws -> [String] {
		if !paths.isEmpty, HerdrCoreID.isRemote(id) {
			throw APIError(409, "image_transfer_failed", "Attachments can't be sent to agents on other machines through herdr-core yet. Nothing was sent.")
		}
		guard !paths.isEmpty, case .remote(let machineID, _) = AgentRef(id) else { return paths }
		let machine = try machine(machineID)
		guard let target = machine.target, !target.isEmpty, !target.hasPrefix("-"),
			target.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "@._-:[]".unicodeScalars.contains($0)) }),
			device.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)) }) else {
			throw APIError(503, "image_transfer_failed", "The agent's saved SSH machine needs a valid address before images can be sent.")
		}
		let relative = ".cache/whispera-link/images/" + device
		let command = "umask 077; mkdir -p \"$HOME/" + relative + "\" && chmod 700 \"$HOME/.cache/whispera-link\" \"$HOME/.cache/whispera-link/images\" \"$HOME/" + relative + "\" && printf '%s/" + relative + "' \"$HOME\""
		let prepared = try HerdrCLI.spawn("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", target, command], timeout: 8)
		let destination = String(decoding: prepared.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard prepared.status == 0, destination.hasPrefix("/"),
			destination.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0)) }) else {
			throw APIError(503, "image_transfer_failed", "Couldn't transfer images to the agent's Mac over SSH. Nothing was sent to the agent; check that machine's connection and retry.")
		}
		var remote: [String] = []
		for path in paths {
			let file = Self.remoteName(path)
			let copy = try HerdrCLI.spawn("/usr/bin/scp", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", path, target + ":" + destination + "/" + file], timeout: 60)
			guard copy.status == 0 else { throw APIError(503, "image_transfer_failed", "Couldn't transfer an attachment to the agent's Mac. Nothing was sent to the agent; retry when that Mac is reachable.") }
			remote.append(destination + "/" + file)
		}
		return remote
	}

	/// An image keeps its `<id>.jpg` name; a file (`files/<id>/<name>`) becomes `<id>-<name>`,
	/// so two files with the same name stay apart in the one remote folder.
	static func remoteName(_ path: String) -> String {
		let url = URL(fileURLWithPath: path)
		let holder = url.deletingLastPathComponent()
		guard holder.deletingLastPathComponent().lastPathComponent == "files", UUID(uuidString: holder.lastPathComponent) != nil else {
			return url.lastPathComponent
		}
		return holder.lastPathComponent + "-" + url.lastPathComponent
	}

	func prompt(_ id: String, text: String, wait: (until: [String], timeoutMS: Int)?) throws -> [String: Any] {
		// Every backend pastes the prompt and then presses Enter itself: a \r or Ctrl-C in the
		// text would be a key press (an early submit, an interrupt), so the text only types.
		// Esc would end a bracketed paste early (tmux refuses it too) and no keyboard types NUL.
		guard !text.contains("\u{1B}"), !text.contains("\u{0}") else {
			throw APIError(400, "bad_request", "text cannot contain escape or NUL characters")
		}
		let text = PastedText.sanitize(text)
		guard !text.isEmpty else { throw APIError(400, "bad_request", "text has nothing to type once control characters are removed") }
        if id.hasPrefix("tmux:") {
            guard let transport = tmux else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
            let agent = try transport.get(id)
            try transport.send(text, id: id)
            // A submitted command can immediately close its pane. Discovery after the
            // terminal write must not turn successful delivery into an apparent failure.
            return ["agent": agent, "waited": false]
        }
		// hc has no prompt wait: the phone follows the turn through agent.status events.
		if let hc = try hcDirectory(id) { return try hc.send(text, id: id) }
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
				"agent": mapNamedRemote(result["agent"] as? [String: Any] ?? [:], machine: machine), "waited": wait != nil,
			]
		}
	}

    /// The directory the selected terminal reports, never a phone path.
    func workingDirectory(_ id: String) throws -> String {
        guard let agent = try get(id)["agent"] as? [String: Any], let cwd = agent["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { throw APIError(409, "no_repository", "This terminal has no working directory") }
        return cwd
    }

    private func sshTarget(_ machineID: String) throws -> String {
        guard let target = try machine(machineID).target, !target.isEmpty, !target.hasPrefix("-"), target.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "@._-:[]".unicodeScalars.contains($0)) }) else { throw APIError(503, "machine_unavailable", "The saved SSH machine needs a valid address") }
        return target
    }

    /// The code reader for an agent's workspace: this Mac, or its saved SSH machine.
    func codeReader(_ id: String) throws -> (cwd: String, reader: CodeReader) {
        if HerdrCoreID.isRemote(id) {
            throw APIError(409, "remote_machine", "Code on another machine can't be read through herdr-core yet.")
        }
        let cwd = try workingDirectory(id)
        if case .remote(let machineID, _) = AgentRef(id) { return (cwd, CodeReader.remote(target: try sshTarget(machineID))) }
        return (cwd, CodeReader.local)
    }

    /// Git reads only the directory reported by the selected terminal, never a phone path.
    func diff(_ id: String, scope: RepositoryDiff.Scope, refresh: Bool = false) throws -> [String: Any] {
        let (cwd, reader) = try codeReader(id)
        return try RepositoryDiff(reader).changes(cwd: cwd, scope: scope, refresh: refresh)
    }

    /// One file's patch from the agent's changes, for a file the list left out.
    func diffFile(_ id: String, scope: RepositoryDiff.Scope, path: String) throws -> [String: Any] {
        let (cwd, reader) = try codeReader(id)
        return try RepositoryDiff(reader).file(cwd: cwd, scope: scope, path: path)
    }

    func diff(_ id: String, staged: Bool) throws -> [String: Any] { try diff(id, scope: staged ? .staged : .all) }

	func sendKeys(_ id: String, keys: [String]) throws -> [String: Any] {
        if id.hasPrefix("tmux:") {
            guard let transport = tmux else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
            try transport.keys(keys, id: id); return ["id": id, "keys": keys.count]
        }
		if let hc = try hcDirectory(id) { return try hc.sendKeys(keys, id: id) }
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

	/// The agent's status, whether an agent still runs in the pane, and the last non-empty lines
	/// of its screen, for the verified controls.
	func probe(_ id: String) throws -> AgentProbe {
		let agent = try get(id)["agent"] as? [String: Any] ?? [:]
		let kind = agent["agent"] as? String
		var screen: String?
		if let text = (try? read(id, source: HerdrClient.visibleSource, lines: 80))?["text"] as? String {
			screen = text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.suffix(12).joined(separator: "\n")
		}
		return AgentProbe(status: agent["status"] as? String ?? "unknown", present: kind?.isEmpty == false, screen: screen)
	}

	/// Interrupts a working agent and checks that it stopped working (`AgentControl.interrupt`).
	func interrupt(_ id: String, key: String) throws -> [String: Any] {
		let report = try control.interrupt(first: key, probe: { try probe(id) }, send: { _ = try sendKeys(id, keys: $0) })
		log("agent.interrupt_result", ["detail": "result=\(report.result.rawValue) keys=\(report.keys.joined(separator: ","))"])
		var body = report.body
		body["id"] = id
		guard report.result != .stillWorking else {
			throw APIError(
				409, "still_working",
				"The agent is still working after \(report.keys.joined(separator: ", ")). Try again or use Stop.",
				extra: body)
		}
		return body
	}

	/// Ctrl-C pairs until the agent has left its pane (`AgentControl.stop`).
	func stop(_ id: String) throws -> [String: Any] {
		let report = try control.stop(probe: { try probe(id) }, send: { _ = try sendKeys(id, keys: $0) })
		if case .remote(let machineID, _) = AgentRef(id) { invalidate(machineID) }
		log("agent.stop_result", ["detail": "stopped=\(report.stopped) rounds=\(report.rounds)"])
		var body = report.body
		body["id"] = id
		guard report.stopped else {
			throw APIError(
				409, "still_running", "The agent is still running after \(report.rounds * 2) Ctrl-C. Try again.",
				extra: body)
		}
		return body
	}

	/// Removes an agent: closes its herdr pane (and with it the tab or workspace it was the last
	/// pane of). Only a pane herdr still reports as an agent is closed, so a stale id never takes
	/// a plain shell with it; one that is already gone answers `already_gone` (idempotent).
	func remove(_ id: String) throws -> [String: Any] {
		guard !id.hasPrefix("tmux:") else {
			throw APIError(400, "bad_request", "tmux sessions are closed on the Mac")
		}
		if let hc = try hcDirectory(id) { return try hc.remove(id) }
		switch AgentRef(id) {
		case .local(let pane):
			guard try local.rawAgent(pane) != nil else { return Self.removed(id, alreadyGone: true) }
			do {
				try local.closePane(pane)
			} catch let error as APIError where error.code == "not_found" {
				return Self.removed(id, alreadyGone: true)
			}
		case .remote(let machineID, let pane):
			let machine = try machine(machineID)
			defer { invalidate(machine.id) }
			guard !pane.hasPrefix("-") else { throw APIError(400, "bad_request", "bad agent id") }
			do {
				_ = try HerdrClient.expect(cli.call(machine: machine.id, ["agent", "get", pane]), "agent_info")
				_ = try cli.call(machine: machine.id, ["pane", "close", pane])
			} catch let error as APIError where error.code == "not_found" && error.extra["herdr_code"] != nil {
				return Self.removed(id, alreadyGone: true)
			}
		}
		log("agent.remove_result", ["detail": "removed"])
		return Self.removed(id, alreadyGone: false)
	}

	/// Which harness a start goes to: the one the phone names (`provider`), else the old herdr
	/// for its own machines and a pane of its own, else herdr-core for a machine only hc knows,
	/// and on this Mac herdr-core only while the old herdr is down.
	func startsOnHerdrCore(_ request: AgentStart, hc: HerdrCoreDirectory) throws -> Bool {
		switch request.provider {
		case "hc"?: return true
		case "herdr"?: return false
		case nil: break
		default: throw APIError(400, "bad_request", "provider must be herdr or hc")
		}
		// A workspace from herdr-core's own listing (hc has none of its own: Herdr.app's).
		if request.workspaceID.map(HerdrCoreID.isHerdrCore) == true { return true }
		guard request.paneID == nil, request.workspaceID == nil, hc.capabilities?.canStart == true else { return false }
		if let machine = request.machine, machine != AgentMachine.localID {
			if cli.machines().contains(where: { $0.id == machine }) { return false }
			return (try? hc.rawListing().machines.contains { $0["name"] as? String == machine }) == true
		}
		return (try? local.ping(timeout: 1)) == nil
	}

	static func removed(_ id: String, alreadyGone: Bool) -> [String: Any] {
		["id": id, "removed": true, "already_gone": alreadyGone]
	}

	/// Starts an agent; without a pane, in the root pane of a new tab (`tab.create`), waiting for
	/// that tab's shell first and closing the tab again when the start fails.
	func start(_ request: AgentStart) throws -> [String: Any] {
        guard request.paneID?.hasPrefix("tmux:") != true else { throw APIError(400, "bad_request", "Open tmux sessions on your Mac before using them here") }
		if let pane = request.paneID, HerdrCoreID.isHerdrCore(pane) {
			throw APIError(400, "bad_request", "herdr-core starts each agent in a new terminal; leave pane_id out")
		}
		if let hc, try startsOnHerdrCore(request, hc: hc) {
			let machine = request.machine.flatMap { $0 == AgentMachine.localID ? nil : $0 }
			return try hc.start(request, machine: machine)
		}
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
			let launch = { [local] (target: String) -> [String: Any] in
				do {
					return try local.start(
						name: request.name, kind: request.kind, paneID: target, args: request.args, timeoutMS: request.timeoutMS)
				} catch let error as APIError where error.code == "agent_not_ready" {
					// Running but blocked on a startup dialog (folder trust): the phone answers it.
					return try local.getAgent(target)
				}
			}
			var answer: [String: Any]
			if let pane {
				answer = try launch(pane)
			} else {
				answer = try control.startInNewTab(
					create: { try local.createTab(workspaceID: request.workspaceID, cwd: request.cwd, label: request.name) },
					shellReady: { try local.shellReady($0) }, start: launch, close: { local.closeTab($0) })
			}
			if var agent = answer["agent"] as? [String: Any] {
				agent["machine"] = Self.machineObject(AgentMachine.localID, Self.localLabel)
				answer["agent"] = agent
			}
			return answer
		}
		let machine = try machine(machineID)
		defer { invalidate(machine.id) }
		let launch = { [cli] (target: String) -> [String: Any] in
			var arguments = [
				"agent", "start", request.name, "--kind", request.kind, "--pane", target, "--timeout", String(request.timeoutMS),
			]
			if !request.args.isEmpty { arguments += ["--"] + request.args }
			do {
				let result = try HerdrClient.expect(
					cli.call(machine: machine.id, arguments, timeout: Double(request.timeoutMS) / 1000 + HerdrCLI.callTimeout),
					"agent_started")
				return result["agent"] as? [String: Any] ?? [:]
			} catch let error as APIError where error.extra["herdr_code"] as? String == "agent_not_ready" {
				// The CLI waits for the agent to be ready for input; one blocked on a startup
				// dialog (folder trust, update) is running, and the phone can answer the dialog.
				return try HerdrClient.expect(cli.call(machine: machine.id, ["agent", "get", target]), "agent_info")["agent"]
					as? [String: Any] ?? [:]
			}
		}
		let started: [String: Any]
		if let pane {
			started = try launch(pane)
		} else {
			started = try control.startInNewTab(
				create: {
					var arguments = ["tab", "create", "--label", request.name, "--no-focus"]
					if let workspace = request.workspaceID { arguments += ["--workspace", workspace] }
					if let cwd = request.cwd { arguments += ["--cwd", cwd] }
					let created = try HerdrClient.expect(cli.call(machine: machine.id, arguments), "tab_created")
					let root = created["root_pane"] as? [String: Any]
					guard let pane = root?["pane_id"] as? String,
						let tab = (created["tab"] as? [String: Any])?["tab_id"] as? String ?? root?["tab_id"] as? String
					else {
						throw APIError(502, "herdr_error", "tab.create returned no root pane", extra: ["herdr_code": "unexpected_type"])
					}
					return (tab, pane)
				},
				// Over ssh a readiness poll costs a round trip each; herdr's busy answer is retried instead.
				shellReady: { _ in true },
				start: { try launch($0) },
				close: { [cli] tab in _ = try? cli.call(machine: machine.id, ["tab", "close", tab]) })
		}
		return ["agent": mapNamedRemote(started, machine: machine)]
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
    private var tmuxSignature: Data?

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

	static let seqSeparator = "\u{1F}"

	/// The status part of a polled `status + separator + state_change_seq`.
	static func status(_ polled: String) -> String {
		polled.components(separatedBy: seqSeparator).first ?? polled
	}

	private func reset() {
		lock.lock()
		baseline = nil
        tmuxSignature = nil
		lock.unlock()
	}

	/// One poll: the first only records what is there.
	func pollOnce() {
        // Discover panes/names only while a phone listens; output is captured on request.
        if let transport = directory.tmux {
            let rows = (try? transport.list()) ?? []
            let signature = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            lock.lock(); let old = tmuxSignature; tmuxSignature = signature; lock.unlock()
            if let old, old != signature { emit("agents.changed", [:]) }
        }
		var now: [String: [String: String]?] = [:]
		var agents: [String: [String: Any]] = [:]
		for machine in directory.cli.machines() {
			switch directory.remoteAgents(machine, fresh: true) {
			case .success(let raw):
				var statuses: [String: String] = [:]
				for info in raw {
					let agent = AgentDirectory.mapRemote(info, machine: machine)
					guard let id = agent["id"] as? String else { continue }
					// With herdr's change counter: a turn shorter than the poll (working, then
					// idle on a question form) still reads as a change.
					let seq = info["state_change_seq"].map { "\($0)" } ?? ""
					statuses[id] = (agent["status"] as? String ?? "unknown") + Self.seqSeparator + seq
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
						"id": id, "status": Self.status(status), "agent": agent["agent"] ?? NSNull(), "title": agent["title"] ?? NSNull(),
						"workspace_id": agent["workspace_id"] ?? NSNull(), "machine": agent["machine"] ?? NSNull(),
					])
			}
		}
		if changedSet { emit("agents.changed", [:]) }
	}
}
