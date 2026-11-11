import Foundation
import WhisperaAgents

/// The transcripts of agents on the other herdr machines: their session logs read over the
/// direct ssh path, a few megabytes at a time, into a local mirror that the same readers as
/// a local agent's parse.
///
/// A mirror holds a window of the remote log's bytes, `[base, fetched)`, that starts at a line
/// start; reads translate its offsets back, so cursors and entry ids are the remote file's own
/// and survive a mirror that is started over. Each sync is one ssh connection: it finds the log
/// (from the session id herdr reports and the agent's folder, never a phone-supplied path),
/// sends what was appended since `fetched` (at most `window` bytes; more starts the window over
/// at the end), and, for Claude Code, what changed in the session's subagent folder. A log that
/// was replaced (its first bytes differ, or it shrank) starts over too, and a new session id in
/// the pane follows the new log.
final class RemoteTranscripts: @unchecked Sendable {
	/// Runs a read-only POSIX sh script on a machine; its stdout. Throws when unreachable.
	typealias Shell = (_ machine: String, _ script: String, _ timeout: TimeInterval) throws -> Data
	/// The pane's raw herdr agent info on that machine, nil when the pane is gone.
	typealias AgentReader = (_ machine: String, _ pane: String) throws -> [String: Any]?

	/// One mirrored file: the remote bytes `[base, fetched)` of `remote`, kept in `local`.
	struct File {
		var remote: String
		var local: URL
		var base = 0
		var fetched = 0
		var size = 0
		/// The remote file's first `headBytes`, base64: a different head is another file.
		var head: String?
	}

	struct Mirror {
		var machine: String
		var harness: SessionHarness
		var sessionID: String
		var name: String?
		var title: String?
		var log: File
		var subagents: [String: File] = [:]
		var tracker: SessionSubagentTracker?
		var list: [SessionSubagent] = []
		var signature: [String] = []
		var synced = Date.distantPast
		var watchedUntil = Date.distantPast
		var watchedSubagents: [String: Date] = [:]
	}

	/// Bytes a sync fetches for the log at most; the first read of a log takes its last
	/// `window` bytes, and a backlog longer than that starts over at the end.
	var window = 4 << 20
	/// What one sync fetches for subagent files at most, and for one new subagent log.
	var subagentBudget = 512 << 10
	var subagentWindow = 256 << 10
	/// How long after a phone's last read the background sync keeps fetching over ssh. Short:
	/// a phone still reading asks again within it, and one that left stops costing ssh.
	static let watchWindow: TimeInterval = 60
	/// A mirror never grows past this by paging back.
	var maxMirror = 32 << 20
	/// A read within this long of the last sync answers from the mirror alone.
	var fresh: TimeInterval = 1.5
	var timeout: TimeInterval = 10
	static let headBytes = 64
	static let maxMirrors = 64
	static let tickInterval: TimeInterval = 3

	private let shell: Shell
	private let readAgent: AgentReader
	private let root: URL
	private let publish: (String, [String: Any]) -> Void
	private let lock = NSLock()
	private var mirrors: [String: Mirror] = [:]
	private var gates: [String: NSLock] = [:]
	private var timer: DispatchSourceTimer?
	/// Tests count syncs.
	private(set) var syncs = 0

	init(
		shell: @escaping Shell, readAgent: @escaping AgentReader, cacheDir: String,
		publish: @escaping (String, [String: Any]) -> Void = { _, _ in }
	) {
		self.shell = shell
		self.readAgent = readAgent
		root = URL(fileURLWithPath: cacheDir, isDirectory: true)
		self.publish = publish
		// Mirrors are rebuilt on demand: what an earlier run left is not trusted.
		try? FileManager.default.removeItem(at: root)
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	}

	// MARK: Route

	func transcript(_ id: String, machine: String, pane: String, query: [String: String]) throws -> [String: Any] {
		let limit = try AgentTranscripts.limit(query["limit"])
		let (gate, live) = try prepare(id, machine: machine, pane: pane)
		gate.lock()
		defer { gate.unlock() }
		var stale = false
		do { try syncIfNeeded(id) } catch {
			let missing = (error as? APIError)?.code == "transcript_unavailable"
			if missing, live, mirror(id)?.synced == .distantPast {
				// Claude Code writes its log with the first prompt: nothing to read yet.
				return ["id": id, "entries": [], "ended": false, "has_earlier": false, "has_more": false, "reset": false]
					.merging(AgentTranscripts.subagentFields([], source: "log")) { $1 }
			}
			guard let mirror = mirror(id), mirror.synced != .distantPast else {
				throw APIError(404, "transcript_unavailable", "This agent's session log can't be read from its machine")
			}
			stale = true
		}
		guard var mirror = mirror(id) else { throw APIError(404, "transcript_unavailable", "No session is known for this agent") }
		let prefix = String(mirror.sessionID.prefix(8))
		var reset = false
		var page: SessionPage
		do {
			if let since = query["since"] {
				page = try read(id, \.log, since: try AgentTranscripts.parseCursor(since, prefix: prefix), limit: limit)
			} else if let before = query["before"] {
				page = try read(id, \.log, before: try AgentTranscripts.parseCursor(before, prefix: prefix), limit: limit)
			} else {
				page = try read(id, \.log, limit: limit)
			}
		} catch SessionLogError.badOffset {
			reset = true
			page = try read(id, \.log, limit: limit)
		} catch let error as APIError where error.code == "stale_cursor" {
			reset = true
			page = try read(id, \.log, limit: limit)
		}
		mirror = self.mirror(id) ?? mirror
		if let title = page.title, title != mirror.title { update(id) { $0.title = title } }
		let list = refreshSubagents(id, ended: !live)
		update(id) {
			$0.watchedUntil = Date().addingTimeInterval(Self.watchWindow)
			$0.signature = AgentTranscripts.signature(list)
		}
		var answer: [String: Any] = [
			"id": id, "harness": mirror.harness.rawValue, "session_id": mirror.sessionID,
			"title": (page.title ?? mirror.title) ?? NSNull(), "name": mirror.name ?? NSNull(),
			"entries": Self.json(page.entries),
			"cursor": AgentTranscripts.cursor(page.end, prefix: prefix), "start": AgentTranscripts.cursor(page.start, prefix: prefix),
			"has_earlier": page.hasEarlier, "has_more": page.hasMore, "reset": reset, "ended": !live,
		]
		if stale { answer["stale"] = true }
		answer.merge(AgentTranscripts.subagentFields(list, source: "log")) { $1 }
		return answer
	}

	func subagentTranscript(_ id: String, machine: String, pane: String, subagent sid: String, query: [String: String]) throws
		-> [String: Any]
	{
		let unavailable = APIError(404, "subagent_unavailable", "This subagent's transcript isn't readable from this Mac")
		guard SessionSubagentTracker.isValidID(sid) else { throw unavailable }
		let limit = try AgentTranscripts.limit(query["limit"])
		let (gate, live) = try prepare(id, machine: machine, pane: pane)
		gate.lock()
		defer { gate.unlock() }
		try? syncIfNeeded(id)
		var list = refreshSubagents(id, ended: !live)
		if list.contains(where: { $0.id == sid }), mirror(id)?.tracker?.log(of: sid) == nil {
			// Listed from the parent's call, its own files not fetched yet: those first.
			try? sync(id, prefer: sid)
			list = refreshSubagents(id, ended: !live)
		}
		guard let mirror = mirror(id), let subagent = list.first(where: { $0.id == sid }),
			let path = mirror.tracker?.log(of: sid), let name = mirror.subagents.first(where: { Self.same($0.value.local, path) })?.key
		else { throw unavailable }
		let prefix = String(sid.prefix(8))
		let key = \Mirror.subagents[name]!
		var reset = false
		var page: SessionPage
		do {
			if let since = query["since"] {
				page = try read(id, key, since: try AgentTranscripts.parseCursor(since, prefix: prefix), limit: limit, sidechain: true)
			} else if let before = query["before"] {
				page = try read(id, key, before: try AgentTranscripts.parseCursor(before, prefix: prefix), limit: limit, sidechain: true)
			} else {
				page = try read(id, key, limit: limit, sidechain: true)
			}
		} catch SessionLogError.badOffset {
			reset = true
			page = try read(id, key, limit: limit, sidechain: true)
		} catch let error as APIError where error.code == "stale_cursor" {
			reset = true
			page = try read(id, key, limit: limit, sidechain: true)
		}
		update(id) {
			$0.watchedUntil = Date().addingTimeInterval(Self.watchWindow)
			$0.watchedSubagents[name] = Date().addingTimeInterval(Self.watchWindow)
		}
		return [
			"id": id, "subagent_id": sid, "harness": mirror.harness.rawValue, "session_id": mirror.sessionID,
			"entries": Self.json(page.entries), "cursor": AgentTranscripts.cursor(page.end, prefix: prefix),
			"start": AgentTranscripts.cursor(page.start, prefix: prefix),
			"has_earlier": page.hasEarlier, "has_more": page.hasMore, "reset": reset,
			"ended": subagent.status != .running, "subagent": AgentTranscripts.json(subagent),
		]
	}

	static func json(_ entries: [SessionEntry]) -> Any {
		(try? JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))) ?? []
	}

	// MARK: Binding

	/// The agent's mirror for the session herdr names now (a new one for a new session), and
	/// whether the agent is live. Unreachable machines keep answering from what was mirrored.
	private func prepare(_ id: String, machine: String, pane: String) throws -> (NSLock, live: Bool) {
		let info: [String: Any]?
		do {
			info = try readAgent(machine, pane)
		} catch let error as APIError where error.code == "not_found" {
			throw APIError(404, "transcript_unavailable", "This agent's machine isn't known to herdr")
		} catch {
			guard mirror(id) != nil else {
				throw APIError(404, "transcript_unavailable", "This agent's machine can't be reached")
			}
			return (gate(id), true)
		}
		guard let info, let harness = AgentTranscripts.harness(info) else {
			// The pane is gone or a bare shell again: what it had is still readable.
			guard mirror(id) != nil else { throw APIError(404, "transcript_unavailable", "No Claude Code or Codex session is known for this agent") }
			return (gate(id), false)
		}
		let name = info["name"] as? String
		guard let sessionID = AgentTranscripts.sessionID(info) else {
			if let existing = mirror(id), existing.name == name { return (gate(id), true) }
			throw APIError(404, "transcript_unavailable", "herdr names no session for this agent")
		}
		let gate = gate(id)
		gate.lock()
		defer { gate.unlock() }
		if let existing = mirror(id), existing.sessionID == sessionID, existing.harness == harness, existing.machine == machine {
			if existing.name != name, let name { update(id) { $0.name = name } }
			return (gate, true)
		}
		// A new session in the pane: its log, from where herdr says the agent works.
		let folder = root.appendingPathComponent(Self.folderName(id), isDirectory: true)
		try? FileManager.default.removeItem(at: folder)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let local = folder.appendingPathComponent(
			harness == .codex ? "rollout-\(sessionID).jsonl" : harness == .omp ? "omp_\(sessionID).jsonl" : "\(sessionID).jsonl")
		FileManager.default.createFile(atPath: local.path, contents: nil)
		let cwd = (info["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
		var mirror = Mirror(
			machine: machine, harness: harness, sessionID: sessionID, name: name,
			log: File(remote: "", local: local))
		mirror.log.remote = Self.unresolved(cwd)
		lock.lock()
		mirrors[id] = mirror
		if mirrors.count > Self.maxMirrors,
			let oldest = mirrors.filter({ $0.key != id }).min(by: { $0.value.synced < $1.value.synced })?.key
		{
			mirrors[oldest] = nil
			try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.folderName(oldest)))
		}
		lock.unlock()
		return (gate, true)
	}

	/// A not yet found log remembers the agent's folder: `?<cwd>`.
	private static func unresolved(_ cwd: String?) -> String { "?" + (cwd ?? "") }

	/// The id as a folder name: anything but letters, digits and dashes becomes `_`.
	static func folderName(_ id: String) -> String {
		String(id.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") ? Character($0) : "_" })
	}

	private func gate(_ id: String) -> NSLock {
		lock.lock()
		defer { lock.unlock() }
		if let gate = gates[id] { return gate }
		let gate = NSLock()
		gates[id] = gate
		return gate
	}

	func mirror(_ id: String) -> Mirror? {
		lock.lock()
		defer { lock.unlock() }
		return mirrors[id]
	}

	private func update(_ id: String, _ change: (inout Mirror) -> Void) {
		lock.lock()
		if var mirror = mirrors[id] {
			change(&mirror)
			mirrors[id] = mirror
		}
		lock.unlock()
	}

	// MARK: Sync

	private func syncIfNeeded(_ id: String, now: Date = Date()) throws {
		guard let mirror = mirror(id), now.timeIntervalSince(mirror.synced) >= fresh else { return }
		try sync(id)
	}

	/// One round trip: the log's new bytes and the changed subagent files.
	@discardableResult
	func sync(_ id: String, prefer: String? = nil) throws -> Bool {
		guard let mirror = mirror(id) else { return false }
		let script = try Self.syncScript(
			mirror, window: window, subagentBudget: subagentBudget, subagentWindow: subagentWindow, prefer: prefer)
		let output = try shell(mirror.machine, script, timeout)
		lock.lock()
		syncs += 1
		lock.unlock()
		let answer = try Self.parse(output)
		guard answer.found, let path = answer.path, Self.isValidRemotePath(path, mirror) else {
			throw APIError(404, "transcript_unavailable", "The agent's session log isn't on its machine")
		}
		var next = mirror
		var changed = false
		var restarted = false
		if next.log.remote != path {
			next.log.remote = path
			restarted = true
		}
		if let data = answer.log {
			let before = next.log.size
			restarted = try Self.apply(&next.log, data: data, size: answer.size, head: answer.head) || restarted
			changed = next.log.size != before || restarted
		}
		if let title = answer.title { next.title = title }
		for (name, data) in answer.subagents {
			guard Self.isValidSubagentFile(name) else { continue }
			let folder = next.log.local.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			var file = next.subagents[name] ?? File(remote: name, local: folder.appendingPathComponent(name))
			if !FileManager.default.fileExists(atPath: file.local.path) { FileManager.default.createFile(atPath: file.local.path, contents: nil) }
			if name.hasSuffix(".meta.json") {
				try data.bytes.write(to: file.local)
				file.base = 0
				file.fetched = data.bytes.count
				file.size = data.size
			} else {
				_ = try Self.apply(&file, data: data, size: data.size, head: data.head)
			}
			next.subagents[name] = file
		}
		if restarted { next.tracker = nil }
		next.synced = Date()
		lock.lock()
		if mirrors[id]?.sessionID == mirror.sessionID { mirrors[id] = next }
		lock.unlock()
		return changed
	}

	/// Appends a fetched range to a mirrored file, or starts it over at that range. True: started over.
	static func apply(_ file: inout File, data: Fetched, size: Int, head: String?) throws -> Bool {
		let continues = file.fetched > 0 && data.from == file.fetched && head != nil && head == file.head
			&& (file.head.map { Data(base64Encoded: $0)?.count == headBytes } ?? false)
		if continues {
			let handle = try FileHandle(forWritingTo: file.local)
			defer { try? handle.close() }
			try handle.seekToEnd()
			try handle.write(contentsOf: data.bytes)
			file.fetched += data.bytes.count
			file.size = size
			return false
		}
		// Started over: the mirror begins at the first line start of what came.
		var bytes = data.bytes
		var base = data.from
		if base > 0 {
			if let newline = bytes.firstIndex(of: 0x0A) {
				let skip = bytes.distance(from: bytes.startIndex, to: newline) + 1
				bytes = bytes.subdata(in: (bytes.startIndex + skip)..<bytes.endIndex)
				base += skip
			} else {
				base += bytes.count
				bytes = Data()
			}
		}
		try bytes.write(to: file.local)
		file.base = base
		file.fetched = base + bytes.count
		file.size = size
		file.head = head
		return true
	}

	/// Pages back: the remote bytes before the mirror's start, prepended. False when there is
	/// nothing before it, the mirror is full, or the remote file is another one now.
	private func extend(_ id: String, _ key: WritableKeyPath<Mirror, File>) throws -> Bool {
		guard let mirror = mirror(id) else { return false }
		let file = mirror[keyPath: key]
		let held = file.fetched - file.base
		guard file.base > 0, held < maxMirror, let head = file.head, let remote = remotePath(mirror, file) else { return false }
		let from = max(0, file.base - window)
		let script = Self.rangeScript(path: remote, from: from, to: file.base, head: head)
		let answer = try Self.parse(try shell(mirror.machine, script, timeout))
		lock.lock()
		syncs += 1
		lock.unlock()
		guard answer.found, answer.head == head, let data = answer.log, data.from == from, data.bytes.count == file.base - from else {
			return false
		}
		var bytes = data.bytes
		var base = from
		if from > 0 {
			guard let newline = bytes.firstIndex(of: 0x0A) else { return false }
			let skip = bytes.distance(from: bytes.startIndex, to: newline) + 1
			bytes = bytes.subdata(in: (bytes.startIndex + skip)..<bytes.endIndex)
			base += skip
		}
		guard !bytes.isEmpty else { return false }
		let existing = try Data(contentsOf: file.local)
		try (bytes + existing).write(to: file.local, options: .atomic)
		update(id) {
			$0[keyPath: key].base = base
			// The subagent tracker read the mirror at its old offsets.
			$0.tracker = nil
		}
		return true
	}

	private func remotePath(_ mirror: Mirror, _ file: File) -> String? {
		guard !mirror.log.remote.hasPrefix("?") else { return nil }
		if file.local == mirror.log.local { return mirror.log.remote }
		guard Self.isValidSubagentFile(file.remote) else { return nil }
		return String(mirror.log.remote.dropLast(".jsonl".count)) + "/subagents/" + file.remote
	}

	// MARK: Read

	/// A page of a mirrored file in the remote file's offsets. A read that reaches the start of
	/// the mirror before `limit` entries pages the remote file back first (once at most: a page of a heavy log may come short, with `has_earlier`).
	private func read(
		_ id: String, _ key: WritableKeyPath<Mirror, File>, since: Int? = nil, before: Int? = nil, limit: Int, sidechain: Bool = false
	) throws -> SessionPage {
		guard let mirror = mirror(id) else { throw SessionLogError.unreadable }
		var file = mirror[keyPath: key]
		let harness = mirror.harness
		if let since {
			// Before the window: the phone missed more than it holds, so it starts over.
			guard since >= file.base, since <= file.fetched else { throw SessionLogError.badOffset }
			return try Self.translate(
				SessionLog.read(file.local, harness: harness, since: since - file.base, limit: limit, sidechain: sidechain), file)
		}
		if let before { guard before <= file.fetched, before >= 0 else { throw SessionLogError.badOffset } }
		var extended = 0
		while true {
			if let before, before <= file.base, file.base > 0 {
				guard extended < 2, (try? extend(id, key)) == true, let again = self.mirror(id)?[keyPath: key] else {
					// Nothing more to page back to: an empty page that says so.
					var empty = try SessionLog.read(file.local, harness: harness, before: 0, limit: 1)
					(empty.start, empty.end, empty.hasEarlier, empty.size) = (before, before, false, file.size)
					return empty
				}
				file = again
				extended += 1
				continue
			}
			let local = before.map { $0 - file.base }
			let page = try Self.translate(
				SessionLog.read(file.local, harness: harness, before: local, limit: limit, sidechain: sidechain), file)
			guard page.entries.count < limit, page.start == file.base, file.base > 0, extended < 1,
				(try? extend(id, key)) == true, let again = self.mirror(id)?[keyPath: key]
			else { return page }
			file = again
			extended += 1
		}
	}

	/// Mirror offsets to the remote file's.
	static func translate(_ page: SessionPage, _ file: File) -> SessionPage {
		guard file.base > 0 else {
			var page = page
			page.size = max(page.size, file.size)
			return page
		}
		var page = page
		page.entries = page.entries.map { entry in
			var entry = entry
			let local = "o\(entry.offset)"
			if entry.id == local || entry.id.hasPrefix(local + ":") {
				entry.id = "o\(entry.offset + file.base)" + entry.id.dropFirst(local.count)
			}
			entry.offset += file.base
			return entry
		}
		page.start += file.base
		page.end += file.base
		page.size = max(page.size + file.base, file.size)
		page.hasEarlier = page.start > 0
		return page
	}

	// MARK: Subagents

	private func refreshSubagents(_ id: String, ended: Bool) -> [SessionSubagent] {
		guard var mirror = mirror(id) else { return [] }
		if mirror.tracker == nil {
			let locator = SessionLocator(
				claudeHome: root.appendingPathComponent("none/claude"), codexHome: root.appendingPathComponent("none/codex"))
			mirror.tracker = SessionSubagentTracker(log: mirror.log.local, harness: mirror.harness, locator: locator)
		}
		mirror.list = mirror.tracker!.refresh(ended: ended)
		let list = mirror.list
		let tracker = mirror.tracker
		update(id) {
			$0.tracker = tracker
			$0.list = list
		}
		return list
	}

	// MARK: Watching

	/// Every few seconds, the remote agents a phone read in the last ten minutes are synced:
	/// a grown log publishes `agent.transcript`, a change in its subagents `agent.subagents`,
	/// and a subagent log a phone read that grew `agent.subagent.transcript`.
	func start() {
		lock.lock()
		defer { lock.unlock() }
		guard timer == nil else { return }
		let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.remote-transcripts"))
		source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
		source.setEventHandler { [weak self] in self?.tick() }
		source.resume()
		timer = source
	}

	func stop() {
		lock.lock()
		timer?.cancel()
		timer = nil
		lock.unlock()
	}

	func tick(now: Date = Date()) {
		lock.lock()
		let watched = mirrors.filter { $0.value.watchedUntil > now }.map(\.key)
		lock.unlock()
		for id in watched {
			let gate = gate(id)
			guard gate.try() else { continue }
			defer { gate.unlock() }
			guard let before = mirror(id), (try? sync(id)) != nil, let after = mirror(id), after.sessionID == before.sessionID
			else { continue }
			if after.log.size != before.log.size || after.log.base != before.log.base {
				publish("agent.transcript", ["id": id, "size": after.log.size])
			}
			let list = refreshSubagents(id, ended: false)
			let signature = AgentTranscripts.signature(list)
			if signature != after.signature {
				update(id) { $0.signature = signature }
				if !(after.signature.isEmpty && list.isEmpty) {
					publish(
						"agent.subagents",
						["id": id, "running": list.filter { $0.status == .running }.count, "subagents": list.map(AgentTranscripts.json)])
				}
			}
			for (name, until) in after.watchedSubagents where until > now {
				guard let was = before.subagents[name], let file = after.subagents[name], file.size != was.size,
					let sid = Self.subagentID(name)
				else { continue }
				publish("agent.subagent.transcript", ["id": id, "subagent_id": sid, "size": file.size])
			}
		}
	}

	static func subagentID(_ name: String) -> String? {
		guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { return nil }
		return String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
	}

	// MARK: Remote scripts

	static let ready = "whispera-link-transcript-ready"

	/// `agent-<id>.jsonl` and `agent-<id>.meta.json` only.
	static func isValidSubagentFile(_ name: String) -> Bool {
		for suffix in [".jsonl", ".meta.json"] where name.hasPrefix("agent-") && name.hasSuffix(suffix) {
			let id = String(name.dropFirst("agent-".count).dropLast(suffix.count))
			return SessionSubagentTracker.isValidID(id)
		}
		return false
	}

	/// A path the remote found: absolute, plain characters, and named after the session in the
	/// harness's own folder (`…/projects/<slug>/<id>.jsonl`, `…/sessions/…/rollout-…-<id>.jsonl`).
	static func isValidRemotePath(_ path: String, _ mirror: Mirror) -> Bool {
		guard path.hasPrefix("/"), path.utf8.count <= 1024, !path.contains("/../"), !path.contains("/./"),
			path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
		else { return false }
		let name = (path as NSString).lastPathComponent
		switch mirror.harness {
		case .claude:
			return name == mirror.sessionID + ".jsonl" && path.contains("/projects/")
		case .codex:
			return name.hasPrefix("rollout-") && name.hasSuffix("-" + mirror.sessionID + ".jsonl") && path.contains("/sessions/")
		case .omp:
			return name.hasSuffix("_" + mirror.sessionID + ".jsonl") && path.contains("/sessions/")
		}
	}

	static let shellHelpers =
		#"b64() { base64 | tr -d '\n'; }; sz() { wc -c < "$1" | tr -d ' '; }; "#

	/// The script of one sync. Every value in it is validated and single-quoted; the log is
	/// found from the session id (and the agent's folder for Claude Code) unless already known.
	static func syncScript(_ mirror: Mirror, window: Int, subagentBudget: Int, subagentWindow: Int, prefer: String? = nil) throws
		-> String
	{
		guard SessionLocator.isValidSessionID(mirror.sessionID) else { throw APIError(400, "bad_request", "bad session id") }
		let q = HerdrCLI.shellQuote
		var script = shellHelpers + "printf '\\n%s\\n' " + q(ready) + "; F=; "
		if mirror.harness == .codex { script += #"X="${CODEX_HOME:-$HOME/.codex}"; "# }
		if !mirror.log.remote.hasPrefix("?") {
			guard isValidRemotePath(mirror.log.remote, mirror) else { throw APIError(400, "bad_request", "bad path") }
			script += "F=" + q(mirror.log.remote) + "; "
		} else {
			let id = mirror.sessionID
			switch mirror.harness {
			case .claude:
				let cwd = String(mirror.log.remote.dropFirst())
				var slugs: [String] = []
				if cwd.hasPrefix("/") {
					var variants = [cwd]
					if cwd.hasPrefix("/private/") { variants.append(String(cwd.dropFirst("/private".count))) }
					else if ["/tmp", "/var", "/etc"].contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) { variants.append("/private" + cwd) }
					for variant in variants {
						let slug = SessionLocator.claudeSlug(variant)
						if !slugs.contains(slug) { slugs.append(slug) }
					}
				}
				script += #"C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; "#
				for slug in slugs.prefix(4) {
					script += #"[ -z "$F" ] && [ -f "$C/"# + q(slug) + "/" + q(id + ".jsonl") + #" ] && F="$C/"# + q(slug) + "/"
						+ q(id + ".jsonl") + "; "
				}
				script += #"if [ -z "$F" ]; then for G in "$C"/*/"# + q(id + ".jsonl") + #"; do [ -f "$G" ] && { F="$G"; break; }; done; fi; "#
			case .codex:
				script += #"for G in "$X"/sessions/*/*/*/rollout-*-"# + q(id + ".jsonl")
					+ #"; do [ -f "$G" ] && F="$G"; done; "#
			case .omp:
				script += #"for G in "${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"/sessions/*/*_"# + q(id + ".jsonl")
					+ #"; do [ -f "$G" ] && F="$G"; done; "#
			}
		}
		script += #"if [ -z "$F" ] || [ ! -f "$F" ] || [ -L "$F" ]; then echo MISSING; exit 0; fi; "#
		script += #"S=$(sz "$F"); printf 'PATH %s\n' "$F"; printf 'SIZE %s\n' "$S"; H=$(head -c "# + String(headBytes)
			+ #" "$F" | b64); printf 'HEAD %s\n' "$H"; "#
		// Appended bytes when the file is the one mirrored and the backlog fits, else the window at its end.
		let head = mirror.log.head.flatMap { Data(base64Encoded: $0)?.count == headBytes ? $0 : nil } ?? ""
		script += "N=\(mirror.log.fetched); W=\(window); E=" + q(head) + "; "
		script += #"if [ -z "$E" ] || [ "$H" != "$E" ] || [ "$S" -lt "$N" ] || [ $((S - N)) -gt "$W" ]; then O=$(( S > W ? S - W : 0 )); else O=$N; fi; "#
		script += #"printf 'DATA %s ' "$O"; tail -c +$((O + 1)) "$F" | head -c "$W" | b64; echo; "#
		if mirror.harness == .codex {
			script += #"T=$(grep -F "# + q("\"" + mirror.sessionID + "\"") + #" "$X/session_index.jsonl" 2>/dev/null | tail -n 1 | b64); [ -n "$T" ] && printf 'TITLE %s\n' "$T"; "#
		}
		if mirror.harness == .claude {
			// Known subagent files and how far each was fetched: a changed one sends what is new.
			var cases = ""
			for (name, file) in mirror.subagents.sorted(by: { $0.key < $1.key }) where isValidSubagentFile(name) {
				let known = name.hasSuffix(".meta.json") ? file.size : file.fetched
				let fileHead = name.hasSuffix(".jsonl") ? (file.head.flatMap { Data(base64Encoded: $0)?.count == headBytes ? $0 : nil } ?? "") : ""
				cases += q(name) + ") K=\(known); KH=" + q(fileHead) + ";; "
			}
			script += #"D="${F%.jsonl}/subagents"; B="# + String(subagentBudget) + "; SW=\(subagentWindow); "
			// A subagent asked for first, then the newest files (the running ones), each once.
			var first = ""
			if let prefer, SessionSubagentTracker.isValidID(prefer) {
				first = q("agent-" + prefer + ".meta.json") + " " + q("agent-" + prefer + ".jsonl") + " "
			}
			script += #"if [ -d "$D" ] && [ ! -L "$D" ]; then SEEN=' '; for M in "# + first + #"$(cd "$D" && ls -t 2>/dev/null); do "#
			script += #"case "$M" in agent-*.jsonl|agent-*.meta.json) ;; *) continue;; esac; case "$SEEN" in *" $M "*) continue;; esac; SEEN="$SEEN$M "; "#
			script += #"G="$D/$M"; [ -f "$G" ] && [ ! -L "$G" ] || continue; K=-1; KH=; case "$M" in "# + cases + "*) ;; esac; "
			script += #"Z=$(sz "$G"); [ "$Z" = "$K" ] && continue; [ "$B" -gt 0 ] || continue; "#
			script += #"case "$M" in *.meta.json) [ "$Z" -le 65536 ] || continue; O=0; L=$Z; GH=;; "#
			script += #"*) GH=$(head -c "# + String(headBytes) + #" "$G" | b64); "#
			script += #"if [ "$K" -lt 0 ] || [ -z "$KH" ] || [ "$GH" != "$KH" ] || [ "$Z" -lt "$K" ] || [ $((Z - K)) -gt "$SW" ]; then O=$(( Z > SW ? Z - SW : 0 )); else O=$K; fi; L=$((Z - O));; esac; "#
			// Whole ranges only (a window is smaller than the budget): what doesn't fit comes next time.
			script += #"[ "$L" -gt "$B" ] && continue; B=$((B - L)); "#
			script += #"printf 'SUB %s %s %s %s ' "$M" "$Z" "$O" "${GH:--}"; tail -c +$((O + 1)) "$G" | head -c "$L" | b64; echo; done; fi; "#
		}
		script += "echo END"
		return script
	}

	/// The bytes `[from, to)` of a mirrored file, if its head is still `head`.
	static func rangeScript(path: String, from: Int, to: Int, head: String) -> String {
		let q = HerdrCLI.shellQuote
		return shellHelpers + "printf '\\n%s\\n' " + q(ready) + "; F=" + q(path) + "; "
			+ #"if [ ! -f "$F" ] || [ -L "$F" ]; then echo MISSING; exit 0; fi; "#
			+ #"S=$(sz "$F"); printf 'PATH %s\n' "$F"; printf 'SIZE %s\n' "$S"; H=$(head -c "# + String(headBytes) + #" "$F" | b64); printf 'HEAD %s\n' "$H"; "#
			+ "[ \"$H\" = " + q(head) + " ] || { echo END; exit 0; }; "
			+ "printf 'DATA %s ' \(from); tail -c +\(from + 1) \"$F\" | head -c \(max(0, to - from)) | b64; echo; echo END"
	}

	struct Fetched {
		var from: Int
		var bytes: Data
		var size = 0
		var head: String?
	}

	struct Answer {
		var found = false
		var path: String?
		var size = 0
		var head: String?
		var log: Fetched?
		var title: String?
		var subagents: [(String, Fetched)] = []
	}

	/// A script's output, after its ready marker (login-shell noise before it is skipped).
	static func parse(_ output: Data) throws -> Answer {
		let marker = Data(("\n" + ready + "\n").utf8)
		guard let range = output.range(of: marker) else {
			throw APIError(503, "herdr_unavailable", "machine unreachable")
		}
		var answer = Answer()
		var ended = false
		for raw in output[range.upperBound...].split(separator: 0x0A, omittingEmptySubsequences: true) {
			let line = String(decoding: raw, as: UTF8.self)
			let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
			let rest = parts.count > 1 ? parts[1] : ""
			switch parts[0] {
			case "MISSING": return Answer()
			case "END": ended = true
			case "PATH": answer.path = rest; answer.found = true
			case "SIZE": answer.size = Int(rest) ?? 0
			case "HEAD": answer.head = rest
			case "DATA":
				let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
				guard let from = Int(fields.first ?? ""), from >= 0,
					let bytes = Data(base64Encoded: fields.count > 1 ? String(fields[1]) : "")
				else { throw APIError(502, "bad_remote_answer", "unreadable log bytes") }
				answer.log = Fetched(from: from, bytes: bytes, size: answer.size, head: answer.head)
			case "TITLE":
				if let data = Data(base64Encoded: rest), let row = WireJSON.decodeObject(data),
					let name = row["thread_name"] as? String, !name.isEmpty
				{
					answer.title = name
				}
			case "SUB":
				let fields = rest.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
				guard fields.count == 5, isValidSubagentFile(fields[0]), let size = Int(fields[1]), let from = Int(fields[2]),
					let bytes = Data(base64Encoded: fields[4])
				else { continue }
				answer.subagents.append((fields[0], Fetched(from: from, bytes: bytes, size: size, head: fields[3] == "-" ? nil : fields[3])))
			default: continue
			}
		}
		// A cut-off answer (a dropped connection) is not half applied.
		guard ended || !answer.found else { throw APIError(503, "herdr_unavailable", "the answer was cut off") }
		return answer
	}

	static func same(_ url: URL, _ other: URL) -> Bool {
		url.resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path
	}
}
