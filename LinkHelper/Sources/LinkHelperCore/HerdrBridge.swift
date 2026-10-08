import Foundation
import WhisperaHerdr

/// herdr socket client (PROTOCOL §6). One short-lived connection per call. Beyond v1's read and
/// prompt calls it sends `agent.send_keys`, `agent.start` and `tab.create` (the phone's keys,
/// interrupt, stop and start-agent controls); `allowedMethods` is still a closed list, so no
/// `pane.*` write or any other method can leave the helper.
public final class HerdrClient: @unchecked Sendable {
	static let connectTimeout: TimeInterval = 1
	public static let callTimeout: TimeInterval = 5
	static let maxPromptWaitMS = 30_000
	static let maxLine = 8 * 1024 * 1024
	public static let allowedMethods: Set<String> = [
		"ping", "agent.list", "agent.get", "agent.read", "agent.prompt", "agent.send_keys", "agent.start",
		"tab.create", "events.subscribe", "workspace.list", "tab.list",
	]
	public static let readSources = ["visible", "recent", "recent_unwrapped"]

	let socketPath: String
	private let lock = NSLock()
	private var cachedVersion: String?
	private var names: (at: Date, workspaces: [[String: Any]], tabs: [[String: Any]])?

	public init(socketPath: String) {
		self.socketPath = socketPath
	}

	public var version: String? {
		lock.lock()
		defer { lock.unlock() }
		return cachedVersion
	}

	static func connect(_ path: String) throws -> UnixConnection {
		guard FileManager.default.fileExists(atPath: path) else {
			throw APIError(503, "herdr_unavailable", "herdr socket not found")
		}
		do {
			return try UnixConnection.connect(path: path, timeout: connectTimeout)
		} catch is UnixConnection.SocketTimeout {
			throw APIError(504, "herdr_timeout", "herdr connect timed out")
		} catch {
			throw APIError(503, "herdr_unavailable", "herdr socket refused the connection")
		}
	}

	public func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = callTimeout) throws
		-> [String: Any]
	{
		guard Self.allowedMethods.contains(method), method != "events.subscribe" else {
			throw APIError(500, "internal", "herdr method not allowed by the bridge")
		}
		let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
		let connection = try Self.connect(socketPath)
		defer { connection.close() }
		let deadline = Date().addingTimeInterval(timeout)
		var answer: [String: Any]?
		do {
			try connection.sendLine(["id": id, "method": method, "params": params], timeout: timeout)
			while answer == nil {
				switch try connection.readLine(timeout: deadline.timeIntervalSinceNow, limit: Self.maxLine) {
				case .timeout:
					throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s")
				case .eof:
					throw APIError(503, "herdr_unavailable", "herdr closed the connection")
				case .line(let line):
					guard let decoded = WireJSON.decodeObject(line) else {
						throw APIError(
							502, "herdr_error", "herdr sent malformed JSON",
							extra: ["herdr_code": "malformed"])
					}
					if decoded["id"] as? String == id { answer = decoded }
				}
			}
		} catch let error as APIError {
			throw error
		} catch is UnixConnection.SocketTimeout {
			throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s")
		} catch {
			throw APIError(503, "herdr_unavailable", "herdr socket error")
		}
		let message = answer ?? [:]
		if let error = message["error"] as? [String: Any] {
			throw Self.mapError(error["code"] as? String, error["message"] as? String)
		}
		return message["result"] as? [String: Any] ?? [:]
	}

	static func mapError(_ code: String?, _ message: String?) -> APIError {
		let code = code ?? "unknown"
		switch code {
		case "agent_blocked":
			return APIError(
				409, "agent_blocked", "agent is blocked on a prompt; nothing was sent",
				extra: ["herdr_code": code])
		case "agent_not_found", "pane_not_found", "not_found", "target_not_found":
			return APIError(404, "not_found", "agent not found", extra: ["herdr_code": code])
		default:
			return APIError(
				502, "herdr_error", "herdr error: " + String((message ?? code).prefix(200)),
				extra: ["herdr_code": code])
		}
	}

	static func expect(_ result: [String: Any], _ type: String) throws -> [String: Any] {
		guard result["type"] as? String == type else {
			throw APIError(
				502, "herdr_error", "unexpected herdr result type \(result["type"] ?? "nil")",
				extra: ["herdr_code": "unexpected_type"])
		}
		return result
	}

	/// herdr `AgentInfo` → the public agent object (§5.4); terminal ids, tokens and sessions are dropped.
	static func mapAgent(_ info: [String: Any]) -> [String: Any] {
		HerdrTUIProvider.agent(info)
	}

	@discardableResult
	public func ping(timeout: TimeInterval = callTimeout) throws -> [String: Any] {
		let result = try Self.expect(call("ping", [:], timeout: timeout), "pong")
		lock.lock()
		cachedVersion = result["version"] as? String
		lock.unlock()
		return result
	}

	func listAgentsRaw() throws -> [[String: Any]] {
		let agents = try Self.expect(call("agent.list"), "agent_list")["agents"] as? [[String: Any]] ?? []
		return named(agents)
	}

	private func named(_ agents: [[String: Any]]) -> [[String: Any]] {
        lock.lock(); let cache = names; lock.unlock()
        let metadata: (at: Date, workspaces: [[String: Any]], tabs: [[String: Any]])
        if let cache, Date().timeIntervalSince(cache.at) < 5 { metadata = cache }
        else {
            // Older HERDR versions may not expose labels. Metadata failure never fails delivery.
            let workspaces = (try? call("workspace.list", timeout: 1)["workspaces"] as? [[String: Any]]) ?? []
            let tabs = (try? call("tab.list", timeout: 1)["tabs"] as? [[String: Any]]) ?? []
            metadata = (Date(), workspaces, tabs)
            lock.lock(); names = metadata; lock.unlock()
        }
        return HerdrTUIProvider.named(agents, workspaces: metadata.workspaces, tabs: metadata.tabs)
    }
    private func projectAgent(_ info: [String: Any]) -> [String: Any] { Self.mapAgent(named([info])[0]) }

	public func listAgents() throws -> [String: Any] {
		if version == nil { _ = try? ping() }
		return ["agents": try listAgentsRaw().map(Self.mapAgent), "herdr_version": version ?? NSNull()]
	}

	public func getAgent(_ target: String) throws -> [String: Any] {
		let result = try Self.expect(call("agent.get", ["target": target]), "agent_info")
		return ["agent": projectAgent(result["agent"] as? [String: Any] ?? [:])]
	}

	/// The pane's text. herdr refuses a `recent` read longer than the screen while an
	/// alternate-screen agent (Claude Code, Codex) is working, `agent_not_idle`, because that
	/// history can only be captured by scrolling while idle; the answer is then the visible
	/// screen, `"source":"visible"` and `"truncated":true`, rather than an error.
	public func read(_ target: String, source: String, lines: Int) throws -> [String: Any] {
		do {
			return try readOnce(target, source: source, lines: lines)
		} catch let error as APIError where source != Self.visibleSource && Self.isBusyRead(error) {
			var answer = try readOnce(target, source: Self.visibleSource, lines: lines)
			answer["truncated"] = true
			return answer
		}
	}

	static let visibleSource = "visible"

	/// herdr's refusal of a long read while the agent works.
	static func isBusyRead(_ error: APIError) -> Bool {
		error.extra["herdr_code"] as? String == "agent_not_idle"
	}

	private func readOnce(_ target: String, source: String, lines: Int) throws -> [String: Any] {
		let result = try Self.expect(
			call(
				"agent.read",
				["target": target, "source": source, "lines": lines, "format": "text", "strip_ansi": true]),
			"pane_read")
		let read = result["read"] as? [String: Any] ?? [:]
		return [
			"id": read["pane_id"] as? String ?? target, "source": read["source"] as? String ?? source,
			"text": read["text"] as? String ?? "", "revision": read["revision"] ?? NSNull(),
			"truncated": (read["truncated"] as? Bool) ?? false,
		]
	}

	public func prompt(_ target: String, text: String, wait: (until: [String], timeoutMS: Int)?) throws -> [String:
		Any]
	{
		var params: [String: Any] = ["target": target, "text": text]
		var timeout = Self.callTimeout
		if let wait {
			let ms = max(0, min(wait.timeoutMS, Self.maxPromptWaitMS))
			params["wait"] = ["until": wait.until, "timeout_ms": ms]
			timeout = Double(ms) / 1000 + Self.callTimeout
		}
		let result = try Self.expect(call("agent.prompt", params, timeout: timeout), "agent_prompted")
		return ["agent": projectAgent(result["agent"] as? [String: Any] ?? [:]), "waited": wait != nil]
	}

	/// `agent.send_keys` (herdr validates every key before writing any byte).
	public func sendKeys(_ target: String, keys: [String]) throws -> [String: Any] {
		_ = try call("agent.send_keys", ["target": target, "keys": keys])
		return ["id": target, "keys": keys.count]
	}

	/// `agent.start`: launches a supported agent in an existing pane at its shell prompt and
	/// returns once herdr sees it ready.
	public func start(name: String, kind: String, paneID: String, args: [String], timeoutMS: Int) throws -> [String:
		Any]
	{
		let params: [String: Any] = [
			"name": name, "kind": kind, "pane_id": paneID, "args": args, "timeout_ms": timeoutMS,
		]
		let result = try Self.expect(
			call("agent.start", params, timeout: Double(timeoutMS) / 1000 + Self.callTimeout), "agent_started")
		return ["agent": projectAgent(result["agent"] as? [String: Any] ?? [:])]
	}
}

extension HerdrClient {
	/// `tab.create` without focus; returns the new tab's root pane id.
	func createTab(workspaceID: String?, cwd: String?, label: String) throws -> String {
		var params: [String: Any] = ["label": label, "focus": false]
		if let workspaceID { params["workspace_id"] = workspaceID }
		if let cwd { params["cwd"] = cwd }
		let result = try Self.expect(call("tab.create", params), "tab_created")
		guard let pane = (result["root_pane"] as? [String: Any])?["pane_id"] as? String else {
			throw APIError(
				502, "herdr_error", "tab.create returned no root pane", extra: ["herdr_code": "unexpected_type"])
		}
		return pane
	}
}

/// The long-lived `events.subscribe` connection feeding SSE (§6): `agent.status`,
/// `agents.changed`, `herdr.down`, `herdr.up`.
public final class HerdrSubscriber: @unchecked Sendable {
	static let paneSetEvents: Set<String> = ["pane.created", "pane.closed", "pane.exited", "pane.agent_detected"]
	static let statusEvent = "pane.agent_status_changed"

	public enum State: String { case unknown, up, down }

	private let client: HerdrClient
	private let socketPath: String
	private let emit: (String, [String: Any]) -> Void
	private let log: OpsLog
	private let backoffBase: TimeInterval
	private let backoffMax: TimeInterval
	private let lock = NSLock()
	private var currentState = State.unknown
	private var stopped = false
	private var connection: UnixConnection?
	private let stopSignal = DispatchSemaphore(value: 0)
	public private(set) var generation = 0

	public init(
		socketPath: String, emit: @escaping (String, [String: Any]) -> Void, log: OpsLog = .null,
		backoffBase: TimeInterval = 1, backoffMax: TimeInterval = 30
	) {
		client = HerdrClient(socketPath: socketPath)
		self.socketPath = socketPath
		self.emit = emit
		self.log = log
		self.backoffBase = backoffBase
		self.backoffMax = backoffMax
	}

	public var state: State {
		lock.lock()
		defer { lock.unlock() }
		return currentState
	}

	public func start() {
		let thread = Thread { [self] in run() }
		thread.name = "herdr-subscriber"
		thread.start()
	}

	public func stop() {
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

	/// Sleeps `delay` seconds unless stopped first; true when stopped.
	private func waitStopped(_ delay: TimeInterval) -> Bool {
		if isStopped { return true }
		_ = stopSignal.wait(timeout: .now() + delay)
		if isStopped {
			stopSignal.signal()
			return true
		}
		return false
	}

	static func normalizeEventName(_ name: String) -> String {
		if name.contains(".") { return name }
		for prefix in ["workspace_", "worktree_", "tab_", "pane_", "layout_"] where name.hasPrefix(prefix) {
			return String(prefix.dropLast()) + "." + name.dropFirst(prefix.count)
		}
		return name
	}

	/// Both line shapes herdr 0.9.1 emits: the `{"event","data"}` envelope and the flat `{"type",…}`.
	static func parseEventLine(_ message: [String: Any]) -> (String, [String: Any])? {
		if let event = message["event"] as? String, let data = message["data"] as? [String: Any] {
			return (normalizeEventName(event), data)
		}
		if let type = message["type"] as? String, message["id"] == nil, message["result"] == nil {
			return (normalizeEventName(type), message)
		}
		return nil
	}

	private func subscriptions(_ panes: Set<String>) -> [[String: Any]] {
		Self.paneSetEvents.sorted().map { ["type": $0] }
			+ panes.sorted().map { ["type": Self.statusEvent, "pane_id": $0] }
	}

	private func open() throws -> UnixConnection {
		let panes = Set(try client.listAgentsRaw().compactMap { $0["pane_id"] as? String })
		let connection = try HerdrClient.connect(socketPath)
		do {
			let id = "sub-" + UUID().uuidString.prefix(8).lowercased()
			try connection.sendLine([
				"id": id, "method": "events.subscribe", "params": ["subscriptions": subscriptions(panes)],
			])
			let deadline = Date().addingTimeInterval(HerdrClient.callTimeout)
			while true {
				switch try connection.readLine(
					timeout: deadline.timeIntervalSinceNow, limit: HerdrClient.maxLine)
				{
				case .timeout: throw APIError(504, "herdr_timeout", "subscribe timed out")
				case .eof: throw APIError(503, "herdr_unavailable", "EOF during subscribe")
				case .line(let line):
					guard let message = WireJSON.decodeObject(line), message["id"] as? String == id else {
						continue
					}
					if message["error"] != nil { throw APIError(502, "herdr_error", "subscribe failed") }
					lock.lock()
					generation += 1
					lock.unlock()
					return connection
				}
			}
		} catch {
			connection.close()
			throw error
		}
	}

	private func setState(_ new: State) {
		lock.lock()
		let old = currentState
		currentState = new
		lock.unlock()
		if new == .down && old != .down {
			log("herdr.down")
			emit("herdr.down", [:])
		} else if new == .up && old == .down {
			log("herdr.up")
			emit("herdr.up", [:])
			emit("agents.changed", [:])
		}
	}

	private func run() {
		var delay = backoffBase
		while !isStopped {
			let opened: UnixConnection
			do {
				opened = try open()
			} catch {
				log("herdr.subscribe_failed", ["detail": (error as? APIError)?.code ?? "\(type(of: error))"])
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
			pump()
			lock.lock()
			let current = connection
			lock.unlock()
			current?.close()
			if isStopped { return }
			setState(.down)
			if waitStopped(delay) { return }
			delay = min(delay * 2, backoffMax)
		}
	}

	private func pump() {
		while !isStopped {
			lock.lock()
			guard let current = connection else {
				lock.unlock()
				return
			}
			lock.unlock()
			let result: UnixConnection.LineResult
			do {
				result = try current.readLine(timeout: 0.5, limit: HerdrClient.maxLine)
			} catch {
				log("herdr.subscription_lost", ["detail": "line_too_long"])
				return
			}
			switch result {
			case .timeout: continue
			case .eof: return
			case .line(let line):
				guard let message = WireJSON.decodeObject(line) else { continue }
				if let error = message["error"] as? [String: Any] {
					log("herdr.subscription_error", ["detail": error["code"] as? String ?? "unknown"])
					return
				}
				guard let (name, data) = Self.parseEventLine(message) else { continue }
				if name == Self.statusEvent {
					emit(
						"agent.status",
						[
							"id": data["pane_id"] ?? NSNull(),
							"status": (data["agent_status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
								?? "unknown",
							"agent": data["agent"] ?? NSNull(), "title": data["title"] ?? NSNull(),
							"workspace_id": data["workspace_id"] ?? NSNull(),
						])
				} else if Self.paneSetEvents.contains(name) {
					emit("agents.changed", [:])
					guard resubscribe() else { return }
				}
			}
		}
	}

	/// herdr cannot re-subscribe a live connection: open a new one with the full pane set, then
	/// close the old one.
	private func resubscribe() -> Bool {
		guard let fresh = try? open() else { return false }
		lock.lock()
		let old = connection
		connection = fresh
		lock.unlock()
		old?.close()
		return true
	}
}
