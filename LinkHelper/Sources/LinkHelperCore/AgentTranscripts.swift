import Foundation
import WhisperaAgents

/// `GET /v1/agents/{id}/transcript`: the agent's conversation read from its own session
/// log (Claude Code's projects JSONL, Codex's rollout), not its screen. The log is found
/// only through the session id herdr reports for that agent's pane, so a phone can read
/// the session of an agent it can already see and drive, and no other file.
///
/// The pane's session is remembered once seen (in memory and in the state folder), so the
/// conversation stays readable after the agent exits and the pane is a bare shell again.
/// A newer session in the same pane replaces it.
final class AgentTranscripts: @unchecked Sendable {
	struct Binding: Codable, Equatable {
		var harness: SessionHarness
		var sessionID: String
		var path: String
		var name: String?
		var title: String?
		var seen: Date
	}

	/// What a pane reports about the agent in it: nil when there is none (a bare shell).
	typealias AgentReader = (_ pane: String) throws -> [String: Any]?
	/// The agent's visible screen, for the subagent lines Claude Code draws (nil: unreadable).
	typealias ScreenReader = (_ id: String) -> String?

	/// One bound session's subagents, followed incrementally.
	struct Follow {
		var path: String
		var tracker: SessionSubagentTracker
		var list: [SessionSubagent] = []
		var refreshed = Date.distantPast
		var ended = false
		/// What the last `agent.subagents` event (or read) said, elapsed time aside.
		var signature: [String] = []
	}

	static let maxBindings = 200
	static let defaultLimit = 300
	static let watchWindow: TimeInterval = 600
	/// A listing refreshes a session's subagents at most this often.
	static let subagentThrottle: TimeInterval = 2
	/// Screen-read subagents count in a listing for this long after the screen was read.
	static let screenFresh: TimeInterval = 30

	private let readAgent: AgentReader
	private let readScreen: ScreenReader?
	/// The agents on the other herdr machines, read over ssh (nil: theirs aren't readable).
	let remote: RemoteTranscripts?
	private let locator: SessionLocator
	private let statePath: String?
	private let publish: (String, [String: Any]) -> Void
	private let lock = NSLock()
	private var bindings: [String: Binding]
	private var watched: [String: (size: Int, until: Date)] = [:]
	/// Live agents read while no log was bound (Codex writes its rollout, Claude Code its
	/// JSONL, with the first prompt): re-resolved every tick until they bind.
	private var unbound: [String: Date] = [:]
	/// When an agent with no known session was first seen in a pane, by pane and name.
	private var firstSeen: [String: (name: String?, at: Date)] = [:]
	private var turns: [String: (path: String, size: Int, turn: SessionTurn?)] = [:]
	private var lastNote = Date.distantPast
	/// Tool calls the owner allowed (at the phone or the Mac): a "rejected" result for one of
	/// these is an interrupt of a running call, not a denial (the harness writes the same words).
	private var approvedTools: [String] = []
	private var timer: DispatchSourceTimer?
	private var follows: [String: Follow] = [:]
	/// Subagent logs a phone read, by `<agent id>/<subagent id>`.
	private var watchedSubagents: [String: (id: String, subagent: String, path: String, size: Int, until: Date)] = [:]
	/// Subagents parsed off an agent's screen, when its log can't say.
	private var screens: [String: (list: [SessionSubagent], at: Date)] = [:]
	/// Listings never wait on a session read: a first read of a long session and its
	/// subagent logs takes seconds, which a list request (and the phone's 10 s timeout) can't.
	private let listingRefresh = DispatchQueue(label: "link.transcripts.listing", qos: .utility)
	/// Agents whose subagents a listing asked to refresh, until that refresh lands.
	private var listingRefreshing: Set<String> = []

	init(
		readAgent: @escaping AgentReader, readScreen: ScreenReader? = nil, locator: SessionLocator = SessionLocator(),
		statePath: String?, publish: @escaping (String, [String: Any]) -> Void = { _, _ in }, remote: RemoteTranscripts? = nil
	) {
		self.readAgent = readAgent
		self.remote = remote
		self.readScreen = readScreen
		self.locator = locator
		self.statePath = statePath
		self.publish = publish
		if let statePath, let data = FileManager.default.contents(atPath: statePath),
			let saved = try? JSONDecoder().decode([String: Binding].self, from: data)
		{
			bindings = saved
		} else {
			bindings = [:]
		}
	}

	// MARK: Route

	func transcript(_ id: String, query: [String: String]) throws -> [String: Any] {
		if !id.hasPrefix("tmux:"), case .remote(let machine, let pane) = AgentRef(id), let remote {
			var answer = try remote.transcript(id, machine: machine, pane: pane, query: query)
			if let entries = answer["entries"] { answer["entries"] = markInterrupted(entries) }
			return answer
		}
		guard !id.hasPrefix("tmux:"), case .local(let pane) = AgentRef(id) else {
			throw APIError(404, "transcript_unavailable", "This agent's transcript isn't readable from this Mac")
		}
		let limit = try Self.limit(query["limit"])
		let (binding, live, info) = try resolve(id, pane: pane)
		guard let binding else {
			if live {
				lock.lock()
				unbound[id] = Date().addingTimeInterval(Self.watchWindow)
				lock.unlock()
				// Claude Code writes its log with the first prompt: nothing to read yet.
				var answer: [String: Any] = [
					"id": id, "entries": [], "ended": false, "has_earlier": false, "has_more": false, "reset": false,
				]
				let screen = info.flatMap(Self.harness) == .claude ? screenSubagents(id) : []
				answer.merge(Self.subagentFields(screen, source: "screen")) { $1 }
				return answer
			}
			throw APIError(404, "transcript_unavailable", "No Claude Code or Codex session is known for this agent")
		}
		let url = URL(fileURLWithPath: binding.path)
		var reset = false
		var page: SessionPage
		do {
			if let since = query["since"] {
				page = try SessionLog.read(url, harness: binding.harness, since: try cursor(since, binding), limit: limit)
			} else if let before = query["before"] {
				page = try SessionLog.read(url, harness: binding.harness, before: try cursor(before, binding), limit: limit)
			} else {
				page = try SessionLog.read(url, harness: binding.harness, limit: limit)
			}
		} catch SessionLogError.badOffset {
			// Another session's cursor, or a log that was replaced: start over from the end.
			reset = true
			page = try readTail(url, binding, limit: limit)
		} catch let error as APIError where error.code == "stale_cursor" {
			reset = true
			page = try readTail(url, binding, limit: limit)
		} catch SessionLogError.unreadable {
			throw APIError(404, "transcript_unavailable", "The agent's session log is gone")
		}
		var title = binding.title
		if let found = page.title { title = found }
		if binding.harness == .codex, let found = locator.codexTitle(sessionID: binding.sessionID) { title = found }
		if title != binding.title { update(id) { $0.title = title } }
		watch(id, size: page.size)
		let entries = markInterrupted((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(page.entries))) ?? [])
		var answer: [String: Any] = [
			"id": id, "harness": binding.harness.rawValue, "session_id": binding.sessionID,
			"title": title ?? NSNull(), "name": binding.name ?? NSNull(), "entries": entries,
			"cursor": Self.cursor(page.end, binding), "start": Self.cursor(page.start, binding),
			"has_earlier": page.hasEarlier, "has_more": page.hasMore, "reset": reset, "ended": !live,
		]
		answer.merge(Self.subagentFields(subagents(id, binding, ended: !live, force: true, mark: true), source: "log")) { $1 }
		return answer
	}

	// MARK: Subagents

	/// `GET /v1/agents/{id}/subagents/{sid}/transcript`: a subagent's own log, found only
	/// through the subagents the agent's bound session started.
	func subagentTranscript(_ id: String, subagent sid: String, query: [String: String]) throws -> [String: Any] {
		let unavailable = APIError(404, "subagent_unavailable", "This subagent's transcript isn't readable from this Mac")
		if !id.hasPrefix("tmux:"), case .remote(let machine, let pane) = AgentRef(id), let remote {
			var answer = try remote.subagentTranscript(id, machine: machine, pane: pane, subagent: sid, query: query)
			if let entries = answer["entries"] { answer["entries"] = markInterrupted(entries) }
			return answer
		}
		guard !id.hasPrefix("tmux:"), case .local(let pane) = AgentRef(id), SessionSubagentTracker.isValidID(sid) else {
			throw unavailable
		}
		let limit = try Self.limit(query["limit"])
		let (found, live, _) = try resolve(id, pane: pane)
		guard let binding = found else { throw unavailable }
		let list = subagents(id, binding, ended: !live, force: true, mark: true)
		lock.lock()
		let path = follows[id]?.tracker.log(of: sid)
		lock.unlock()
		guard let subagent = list.first(where: { $0.id == sid }), let url = path else { throw unavailable }
		let prefix = String(sid.prefix(8))
		var reset = false
		var page: SessionPage
		do {
			if let since = query["since"] {
				page = try SessionLog.readSubagent(url, harness: binding.harness, since: try cursor(since, prefix: prefix), limit: limit)
			} else if let before = query["before"] {
				page = try SessionLog.readSubagent(url, harness: binding.harness, before: try cursor(before, prefix: prefix), limit: limit)
			} else {
				page = try SessionLog.readSubagent(url, harness: binding.harness, limit: limit)
			}
		} catch SessionLogError.badOffset {
			reset = true
			page = try readSubagentTail(url, binding, limit: limit)
		} catch let error as APIError where error.code == "stale_cursor" {
			reset = true
			page = try readSubagentTail(url, binding, limit: limit)
		} catch SessionLogError.unreadable {
			throw unavailable
		}
		lock.lock()
		watchedSubagents[id + "/" + sid] = (id, sid, url.path, page.size, Date().addingTimeInterval(Self.watchWindow))
		lock.unlock()
		let entries = markInterrupted((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(page.entries))) ?? [])
		return [
			"id": id, "subagent_id": sid, "harness": binding.harness.rawValue, "session_id": binding.sessionID,
			"entries": entries, "cursor": Self.cursor(page.end, prefix: prefix), "start": Self.cursor(page.start, prefix: prefix),
			"has_earlier": page.hasEarlier, "has_more": page.hasMore, "reset": reset,
			"ended": subagent.status != .running, "subagent": Self.json(subagent),
		]
	}

	private func readSubagentTail(_ url: URL, _ binding: Binding, limit: Int) throws -> SessionPage {
		do { return try SessionLog.readSubagent(url, harness: binding.harness, limit: limit) } catch {
			throw APIError(404, "subagent_unavailable", "The subagent's log is gone")
		}
	}

	/// The bound session's subagents, read on from where its tracker stopped. A new path
	/// starts a new tracker. Without `force`, at most every `subagentThrottle` seconds.
	/// `mark`: what a phone now has, so the next change publishes `agent.subagents`.
	private func subagents(_ id: String, _ binding: Binding, ended: Bool, force: Bool = false, mark: Bool = false,
		now: Date = Date()) -> [SessionSubagent]
	{
		lock.lock()
		var follow = follows[id]
		if follow?.path != binding.path {
			follow = Follow(
				path: binding.path, tracker: SessionSubagentTracker(log: URL(fileURLWithPath: binding.path), harness: binding.harness, locator: locator))
		}
		guard var follow else {
			lock.unlock()
			return []
		}
		if !force, follow.ended == ended, now.timeIntervalSince(follow.refreshed) < Self.subagentThrottle {
			lock.unlock()
			return follow.list
		}
		lock.unlock()
		follow.list = follow.tracker.refresh(now: now, ended: ended)
		follow.refreshed = now
		follow.ended = ended
		if mark { follow.signature = Self.signature(follow.list) }
		lock.lock()
		follows[id] = follow
		lock.unlock()
		return follow.list
	}

	/// What a change worth an event is made of: not elapsed time, which grows every second.
	static func signature(_ list: [SessionSubagent]) -> [String] {
		list.map {
			[$0.id, $0.status.rawValue, $0.lastAction ?? "", $0.lastActionKind?.rawValue ?? "", $0.tokens.map(String.init) ?? "",
				$0.toolUses.map(String.init) ?? "", $0.hasTranscript ? "t" : "", $0.result ?? ""].joined(separator: "\u{1F}")
		}
	}

	static func json(_ subagent: SessionSubagent) -> Any {
		(try? JSONSerialization.jsonObject(with: JSONEncoder().encode(subagent))) ?? [:]
	}

	static func subagentFields(_ list: [SessionSubagent], source: String) -> [String: Any] {
		["subagents": list.map(json), "subagents_running": list.filter { $0.status == .running }.count, "subagents_source": source]
	}

	/// Subagents off a live Claude Code agent's screen: the one read in the last couple of
	/// seconds (an `agents.output` read counts), else read now.
	private func screenSubagents(_ id: String, now: Date = Date()) -> [SessionSubagent] {
		lock.lock()
		let cached = screens[id]
		lock.unlock()
		if let cached, now.timeIntervalSince(cached.at) < Self.subagentThrottle { return cached.list }
		guard let readScreen, let text = readScreen(id) else { return cached?.list ?? [] }
		return noteScreen(id, text: text, now: now)
	}

	/// Remembers the subagent lines on an agent's screen (any read of it, e.g. `agents.output`).
	@discardableResult
	func noteScreen(_ id: String, text: String, now: Date = Date()) -> [SessionSubagent] {
		let list = SubagentScreenLines.parse(text)
		lock.lock()
		screens[id] = (list, now)
		if screens.count > Self.maxBindings {
			screens = screens.filter { now.timeIntervalSince($0.value.at) < Self.screenFresh }
		}
		lock.unlock()
		return list
	}

	/// The bound session's subagents as last read, for a listing. A list older than
	/// `subagentThrottle` (or none yet) is refreshed in the background, one agent at a time,
	/// so the next listing has it.
	private func listedSubagents(_ id: String, _ binding: Binding, now: Date = Date()) -> [SessionSubagent] {
		lock.lock()
		let known = follows[id].flatMap { $0.path == binding.path ? $0 : nil }
		let due = known.map { $0.ended || now.timeIntervalSince($0.refreshed) >= Self.subagentThrottle } ?? true
		let start = due && listingRefreshing.insert(id).inserted
		lock.unlock()
		if start {
			listingRefresh.async { [weak self] in
				guard let self else { return }
				_ = self.subagents(id, binding, ended: false)
				self.lock.lock()
				self.listingRefreshing.remove(id)
				self.lock.unlock()
			}
		}
		return known?.list ?? []
	}

	/// Waits for the listing refreshes queued so far (tests).
	func settleListingRefreshes() {
		listingRefresh.sync {}
	}

	/// Adds `subagents_running` to a listed agent while any of its subagents run: from its
	/// bound session's tracker as last read (a stale one is refreshed in the background),
	/// else from a recent read of a Claude Code agent's screen. Nothing is read for an agent
	/// without either.
	func annotate(_ agent: [String: Any]) -> [String: Any] {
		guard let id = agent["id"] as? String else { return agent }
		let kind = (agent["agent"] as? String ?? "").lowercased()
		let live = kind.hasPrefix("claude") || kind.hasPrefix("codex")
		var running = 0
		// An exited agent's subagents were cut off with it: none run, nothing to read.
		if live, !id.hasPrefix("tmux:"), case .local = AgentRef(id), let binding = binding(id) {
			running = listedSubagents(id, binding).filter { $0.status == .running }.count
		}
		if running == 0, kind.hasPrefix("claude") {
			lock.lock()
			if let screen = screens[id], Date().timeIntervalSince(screen.at) < Self.screenFresh {
				running = screen.list.filter { $0.status == .running }.count
			}
			lock.unlock()
		}
		guard running > 0 else { return agent }
		var agent = agent
		agent["subagents_running"] = running
		return agent
	}

	private func readTail(_ url: URL, _ binding: Binding, limit: Int) throws -> SessionPage {
		do { return try SessionLog.read(url, harness: binding.harness, limit: limit) } catch {
			throw APIError(404, "transcript_unavailable", "The agent's session log is gone")
		}
	}

	/// The pane's current session (live), else the one it last had (ended).
	private func resolve(_ id: String, pane: String) throws -> (Binding?, live: Bool, info: [String: Any]?) {
		let info: [String: Any]?
		do {
			info = try readAgent(pane)
		} catch let error as APIError where error.code == "herdr_unavailable" || error.status == 503 {
			// herdr is down: what the pane last had is still readable.
			return (binding(id), false, nil)
		}
		guard let info else { return (binding(id), false, nil) }
		if let found = bind(id, info) { return (found, true, info) }
		// A herdr that names no session: the same agent's remembered one. A new session
		// whose log isn't written yet shows nothing rather than the previous one.
		if info["agent_session"] == nil, let existing = binding(id), existing.name == info["name"] as? String {
			return (existing, true, info)
		}
		// herdr names another session than the one bound (the pane's agent was cleared,
		// continued or replaced) and its log isn't there yet: the old one must not keep
		// answering for the pane (its turn, its subagents) meanwhile.
		var dropped: String?
		if let named = Self.sessionID(info), let existing = binding(id), existing.sessionID != named {
			dropped = existing.path
			forget(id)
		}
		if let found = bindByFolder(id, info, excluding: dropped) { return (found, true, info) }
		return (nil, true, info)
	}

	static let startSlack: TimeInterval = 10

	/// When this pane's current agent was first seen without a session.
	private func started(_ id: String, _ info: [String: Any]) -> Date {
		let name = info["name"] as? String
		lock.lock()
		defer { lock.unlock() }
		if let seen = firstSeen[id], seen.name == name { return seen.at }
		let now = Date()
		firstSeen[id] = (name, now)
		return now
	}

	/// A terminal that has not reported the agent's session id (or reported one whose log
	/// isn't there yet): the newest log of the same harness written in the agent's folder
	/// since it started, unless another pane already reads it.
	private func bindByFolder(_ id: String, _ info: [String: Any], excluding dropped: String? = nil) -> Binding? {
		guard let harness = Self.harness(info), let cwd = info["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
		let after = started(id, info).addingTimeInterval(-Self.startSlack)
		let url: URL?
		switch harness {
		case .claude: url = locator.newestClaudeLog(cwd: cwd, after: after)
		case .codex: url = locator.newestCodexLog(cwd: cwd, after: after)
		}
		guard let url, !Self.samePath(url.path, dropped), let sessionID = SessionLocator.sessionID(of: url, harness: harness)
		else { return nil }
		lock.lock()
		let taken = bindings.contains { $0.key != id && $0.value.path == url.path }
		lock.unlock()
		guard !taken else { return nil }
		if let existing = binding(id), existing.path == url.path { return existing }
		let fresh = Binding(
			harness: harness, sessionID: sessionID, path: url.path, name: info["name"] as? String, title: nil, seen: Date())
		lock.lock()
		bindings[id] = fresh
		lock.unlock()
		save()
		return fresh
	}

	// MARK: Waiting

	/// The agent's log has a turn open and nothing written for `quiet` seconds: it waits on
	/// the owner (a permission dialog or a question), whatever its screen shows.
	func waiting(_ id: String, quiet: TimeInterval = 2, now: Date = Date()) -> Bool {
		guard let binding = binding(id),
			let attributes = try? FileManager.default.attributesOfItem(atPath: binding.path),
			let size = (attributes[.size] as? NSNumber)?.intValue,
			let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) >= quiet
		else { return false }
		lock.lock()
		let cached = turns[id]
		lock.unlock()
		let turn: SessionTurn?
		if let cached, cached.path == binding.path, cached.size == size {
			turn = cached.turn
		} else {
			turn = SessionLog.turn(URL(fileURLWithPath: binding.path), harness: binding.harness)
			lock.lock()
			turns[id] = (binding.path, size, turn)
			lock.unlock()
		}
		return turn?.open == true
	}

	/// The agent's newest unanswered tool call was allowed.
	func noteApproved(_ id: String) {
		ensureBound(id)
		guard let binding = binding(id),
			let tool = SessionLog.turn(URL(fileURLWithPath: binding.path), harness: binding.harness)?.pendingTool
		else { return }
		lock.lock()
		if !approvedTools.contains(tool.id) { approvedTools.append(tool.id) }
		if approvedTools.count > 500 { approvedTools.removeFirst(approvedTools.count - 500) }
		lock.unlock()
	}

	/// Marks results of allowed calls that read as denials as interrupted instead.
	func markInterrupted(_ entries: Any) -> Any {
		lock.lock()
		let approved = Set(approvedTools)
		lock.unlock()
		guard !approved.isEmpty, let list = entries as? [[String: Any]] else { return entries }
		return list.map { entry -> [String: Any] in
			guard var result = entry["result"] as? [String: Any], result["denied"] as? Bool == true,
				let tool = result["tool_id"] as? String, approved.contains(tool)
			else { return entry }
			var entry = entry
			result["denied"] = false
			result["interrupted"] = true
			entry["result"] = result
			return entry
		}
	}

	/// Whether the agent's log has a turn open now; nil when no log is known for it.
	func turnOpen(_ id: String) -> Bool? {
		guard let binding = binding(id) else { return nil }
		return SessionLog.turn(URL(fileURLWithPath: binding.path), harness: binding.harness)?.open
	}

	/// Binds a live agent's session without a phone asking (the waiting check needs it).
	func ensureBound(_ id: String) {
		guard case .local(let pane) = AgentRef(id), !id.hasPrefix("tmux:") else { return }
		_ = try? resolve(id, pane: pane)
	}

	/// Records the session an agent's info names, if its log exists.
	@discardableResult
	private func bind(_ id: String, _ info: [String: Any]) -> Binding? {
		guard let harness = Self.harness(info), let session = info["agent_session"] as? [String: Any],
			session["kind"] as? String == "id", let sessionID = session["value"] as? String,
			SessionLocator.isValidSessionID(sessionID)
		else { return nil }
		let name = info["name"] as? String
		if let existing = binding(id), existing.sessionID == sessionID, existing.harness == harness,
			FileManager.default.fileExists(atPath: existing.path)
		{
			if existing.name != name, let name { update(id) { $0.name = name } }
			return binding(id)
		}
		guard let url = locator.log(harness, sessionID: sessionID, cwd: info["cwd"] as? String) else { return nil }
		let fresh = Binding(harness: harness, sessionID: sessionID, path: url.path, name: name, title: nil, seen: Date())
		lock.lock()
		bindings[id] = fresh
		lock.unlock()
		save()
		return fresh
	}

	static func samePath(_ path: String, _ other: String?) -> Bool {
		guard let other else { return false }
		return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == URL(fileURLWithPath: other).resolvingSymlinksInPath().path
	}

	/// The session id herdr reports for the pane's agent, when it is a valid one.
	static func sessionID(_ info: [String: Any]) -> String? {
		guard let session = info["agent_session"] as? [String: Any], session["kind"] as? String == "id",
			let value = session["value"] as? String, SessionLocator.isValidSessionID(value)
		else { return nil }
		return value
	}

	static func harness(_ info: [String: Any]) -> SessionHarness? {
		let agent = (info["agent"] as? String ?? (info["agent_session"] as? [String: Any])?["agent"] as? String ?? "").lowercased()
		if agent.hasPrefix("claude") { return .claude }
		if agent.hasPrefix("codex") { return .codex }
		return nil
	}

	/// Remembers the sessions of the agents a listing shows, so an agent that exits before
	/// anyone opened its chat still has one. At most every five seconds.
	func note(_ list: () throws -> [[String: Any]]) {
		lock.lock()
		guard Date().timeIntervalSince(lastNote) >= 5 else {
			lock.unlock()
			return
		}
		lastNote = Date()
		lock.unlock()
		guard let agents = try? list() else { return }
		for info in agents {
			guard let pane = info["pane_id"] as? String else { continue }
			bind(pane, info)
		}
	}

	// MARK: Cursors

	/// `<offset>.<first 8 of the session id>`: a cursor from another session is stale.
	static func cursor(_ offset: Int, _ binding: Binding) -> String {
		cursor(offset, prefix: String(binding.sessionID.prefix(8)))
	}

	/// A subagent's pages use the first 8 of its own id.
	static func cursor(_ offset: Int, prefix: String) -> String {
		"\(offset).\(prefix)"
	}

	private func cursor(_ text: String, _ binding: Binding) throws -> Int {
		try cursor(text, prefix: String(binding.sessionID.prefix(8)))
	}

	private func cursor(_ text: String, prefix: String) throws -> Int {
		try Self.parseCursor(text, prefix: prefix)
	}

	static func parseCursor(_ text: String, prefix: String) throws -> Int {
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 2, parts[0].count <= 15, parts[0].allSatisfy(\.isNumber), let offset = Int(parts[0]),
			parts[1].count <= 16, parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
		else { throw APIError(400, "bad_request", "cursor must come from a transcript response") }
		guard parts[1] == prefix else { throw APIError(409, "stale_cursor", "cursor is for another session") }
		return offset
	}

	static func limit(_ text: String?) throws -> Int {
		guard let text else { return defaultLimit }
		guard text.count <= 4, text.allSatisfy(\.isNumber), let value = Int(text), (1...1000).contains(value) else {
			throw APIError(400, "bad_request", "limit must be 1-1000")
		}
		return value
	}

	// MARK: Watching

	/// Every second, the logs read in the last ten minutes: a grown one publishes
	/// `agent.transcript`, so a phone on the event stream reads on without polling.
	func start() {
		lock.lock()
		defer { lock.unlock() }
		guard timer == nil else { return }
		let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.transcripts"))
		source.schedule(deadline: .now() + 1, repeating: 1)
		source.setEventHandler { [weak self] in self?.tick() }
		source.resume()
		timer = source
		remote?.start()
	}

	func stop() {
		lock.lock()
		timer?.cancel()
		timer = nil
		lock.unlock()
		remote?.stop()
	}

	private func watch(_ id: String, size: Int) {
		lock.lock()
		watched[id] = (size, Date().addingTimeInterval(Self.watchWindow))
		lock.unlock()
	}

	func tick(now: Date = Date()) {
		lock.lock()
		unbound = unbound.filter { $0.value > now }
		let pending = Array(unbound.keys)
		lock.unlock()
		for id in pending {
			guard case .local(let pane) = AgentRef(id), let (found, live, _) = try? resolve(id, pane: pane) else { continue }
			guard found != nil || !live else { continue }
			lock.lock()
			unbound[id] = nil
			lock.unlock()
			if found != nil { publish("agent.transcript", ["id": id, "size": 0]) }
		}
		lock.lock()
		watched = watched.filter { $0.value.until > now }
		let targets = watched.compactMap { id, entry in bindings[id].map { (id, $0.path, entry.size) } }
		lock.unlock()
		for (id, path, size) in targets {
			guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
				let current = (attributes[.size] as? NSNumber)?.intValue, current != size
			else { continue }
			lock.lock()
			if let entry = watched[id] { watched[id] = (current, entry.until) }
			lock.unlock()
			publish("agent.transcript", ["id": id, "size": current])
		}
		tickSubagents(now: now)
	}

	/// The watched agents' subagents: a change in what they do publishes `agent.subagents`,
	/// and a subagent log a phone read that grew publishes `agent.subagent.transcript`.
	private func tickSubagents(now: Date) {
		lock.lock()
		let targets = watched.keys.compactMap { id in bindings[id].map { (id, $0, follows[id]?.ended ?? false) } }
		watchedSubagents = watchedSubagents.filter { $0.value.until > now }
		let logs = watchedSubagents
		lock.unlock()
		for (id, binding, ended) in targets {
			lock.lock()
			let before = follows[id].flatMap { $0.path == binding.path ? $0.signature : nil }
			lock.unlock()
			let list = subagents(id, binding, ended: ended, force: true, now: now)
			let signature = Self.signature(list)
			guard signature != (before ?? []) else { continue }
			lock.lock()
			follows[id]?.signature = signature
			lock.unlock()
			publish(
				"agent.subagents",
				["id": id, "running": list.filter { $0.status == .running }.count, "subagents": list.map(Self.json)])
		}
		for (key, entry) in logs {
			guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
				let current = (attributes[.size] as? NSNumber)?.intValue, current != entry.size
			else { continue }
			lock.lock()
			watchedSubagents[key]?.size = current
			lock.unlock()
			publish("agent.subagent.transcript", ["id": entry.id, "subagent_id": entry.subagent, "size": current])
		}
	}

	// MARK: Store

	func binding(_ id: String) -> Binding? {
		lock.lock()
		defer { lock.unlock() }
		return bindings[id]
	}

	private func forget(_ id: String) {
		lock.lock()
		bindings[id] = nil
		follows[id] = nil
		turns[id] = nil
		lock.unlock()
		save()
	}

	private func update(_ id: String, _ change: (inout Binding) -> Void) {
		lock.lock()
		guard var binding = bindings[id] else {
			lock.unlock()
			return
		}
		change(&binding)
		bindings[id] = binding
		lock.unlock()
		save()
	}

	private func save() {
		guard let statePath else { return }
		lock.lock()
		if bindings.count > Self.maxBindings {
			let keep = bindings.sorted { $0.value.seen > $1.value.seen }.prefix(Self.maxBindings)
			bindings = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
		}
		let snapshot = bindings
		lock.unlock()
		if let data = try? JSONEncoder().encode(snapshot) { try? FileStore.writeAtomic(data, to: statePath) }
	}
}
