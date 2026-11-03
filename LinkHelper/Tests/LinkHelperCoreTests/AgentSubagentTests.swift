import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// An agent's subagents: listed with its transcript and in the agent list, each one's own
/// log readable by id only through the subagents its session started, and followed live.
/// The logs are a real Claude Code session that ran two subagents in parallel.
final class AgentSubagentTests: XCTestCase {
	static let sessionID = "4b84e8b1-9651-4048-a06f-88fd16ce527b"
	static let count = "ab27a809cd2067164"
	static let read = "a9703999f21d1aad6"

	var root: URL!
	var locator: SessionLocator!
	var log: URL!
	var subagentFolder: URL!
	var panes: [String: [String: Any]] = [:]
	var screen: String?
	var published: [(String, [String: Any])] = []

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("subagents-\(UUID().uuidString.prefix(8))")
		let claude = root.appendingPathComponent("claude")
		locator = SessionLocator(claudeHome: claude, codexHome: root.appendingPathComponent("codex"))
		let project = claude.appendingPathComponent("projects/-private-tmp-r1transcript-sandbox")
		subagentFolder = project.appendingPathComponent(Self.sessionID + "/subagents")
		try FileManager.default.createDirectory(at: subagentFolder, withIntermediateDirectories: true)
		log = project.appendingPathComponent(Self.sessionID + ".jsonl")
		panes = ["w1:p1": AgentTranscriptTests.info(agent: "claude", name: "cc", session: Self.sessionID)]
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
	}

	private func fixture(_ path: String) throws -> URL {
		let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
		return folder.appendingPathComponent(path)
	}

	private func lines(_ path: String) throws -> [String] {
		try String(contentsOf: fixture(path), encoding: .utf8).split(separator: "\n").map(String.init)
	}

	private func write(_ lines: [String], to url: URL) throws {
		try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
	}

	private func append(_ line: String, to url: URL) throws {
		let handle = try FileHandle(forWritingTo: url)
		try handle.seekToEnd()
		try handle.write(contentsOf: Data((line + "\n").utf8))
		try handle.close()
	}

	/// The session as it finished: both subagents done.
	private func writeFinished() throws {
		try write(lines("claude-subagents.jsonl"), to: log)
		for id in [Self.count, Self.read] {
			for ext in ["jsonl", "meta.json"] {
				try? FileManager.default.removeItem(at: subagentFolder.appendingPathComponent("agent-\(id).\(ext)"))
				try FileManager.default.copyItem(
					at: fixture("claude-subagents/subagents/agent-\(id).\(ext)"),
					to: subagentFolder.appendingPathComponent("agent-\(id).\(ext)"))
			}
		}
	}

	/// The session mid-way: the parent up to its two calls, each subagent up to its first tool call.
	private func writeRunning() throws {
		let parent = try lines("claude-subagents.jsonl")
		let calls = try XCTUnwrap(parent.lastIndex { $0.contains(#""name":"Agent""#) })
		try write(Array(parent[...calls]), to: log)
		for id in [Self.count, Self.read] {
			let child = try lines("claude-subagents/subagents/agent-\(id).jsonl")
			let firstTool = try XCTUnwrap(child.firstIndex { $0.contains(#""type":"tool_use""#) })
			try write(Array(child[...firstTool]), to: subagentFolder.appendingPathComponent("agent-\(id).jsonl"))
			let meta = try String(contentsOf: fixture("claude-subagents/subagents/agent-\(id).meta.json"), encoding: .utf8)
			try meta.replacingOccurrences(of: #","finished":true"#, with: "")
				.write(to: subagentFolder.appendingPathComponent("agent-\(id).meta.json"), atomically: true, encoding: .utf8)
		}
	}

	private func makeTranscripts() -> AgentTranscripts {
		AgentTranscripts(
			readAgent: { [unowned self] pane in self.panes[pane] }, readScreen: { [unowned self] _ in self.screen },
			locator: locator, statePath: root.appendingPathComponent("transcripts.json").path,
			publish: { [unowned self] event, data in self.published.append((event, data)) })
	}

	private func subagents(_ answer: [String: Any]) throws -> [SessionSubagent] {
		try JSONDecoder().decode(
			[SessionSubagent].self, from: JSONSerialization.data(withJSONObject: answer["subagents"] ?? []))
	}

	private func entries(_ answer: [String: Any]) throws -> [SessionEntry] {
		try JSONDecoder().decode([SessionEntry].self, from: JSONSerialization.data(withJSONObject: answer["entries"] ?? []))
	}

	// MARK: Transcript payload

	func testTranscriptCarriesTheSessionsSubagents() throws {
		try writeFinished()
		let answer = try makeTranscripts().transcript("w1:p1", query: ["limit": "3"])
		let list = try subagents(answer)
		XCTAssertEqual(list.map(\.id), [Self.count, Self.read])
		XCTAssertEqual(list.map(\.description), ["Count words", "Read calc"])
		XCTAssertTrue(list.allSatisfy { $0.status == .done && $0.hasTranscript })
		XCTAssertEqual(answer["subagents_running"] as? Int, 0)
		XCTAssertEqual(answer["subagents_source"] as? String, "log")
		let raw = try XCTUnwrap((answer["subagents"] as? [[String: Any]])?.first)
		XCTAssertNotNil(raw["tool_id"], "snake_case on the wire")
	}

	func testRunningSubagentsAreCountedAndListed() throws {
		try writeRunning()
		let transcripts = makeTranscripts()
		let answer = try transcripts.transcript("w1:p1", query: [:])
		XCTAssertEqual(answer["subagents_running"] as? Int, 2)
		XCTAssertEqual(try subagents(answer).map(\.status), [.running, .running])

		let listed = transcripts.annotate(["id": "w1:p1", "agent": "claude", "status": "working"])
		XCTAssertEqual(listed["subagents_running"] as? Int, 2)
		// The agent exited with them unfinished: they read as interrupted, so none run.
		let exited = transcripts.annotate(["id": "w1:p1", "agent": NSNull(), "status": "unknown"])
		XCTAssertNil(exited["subagents_running"])
		// An agent with no session bound is never read for subagents.
		XCTAssertNil(transcripts.annotate(["id": "w1:p9", "agent": "claude"])["subagents_running"])
	}

	/// A listing answers from what was last read: the first listing of a session nobody read
	/// yet counts nothing rather than reading its logs on the request, and the next one has it.
	func testListingNeverWaitsOnASessionRead() throws {
		try writeRunning()
		let transcripts = makeTranscripts()
		transcripts.note { [panes["w1:p1"]!] }
		XCTAssertNotNil(transcripts.binding("w1:p1"))
		let listed: [String: Any] = ["id": "w1:p1", "agent": "claude", "status": "working"]

		XCTAssertNil(transcripts.annotate(listed)["subagents_running"])
		transcripts.settleListingRefreshes()
		XCTAssertEqual(transcripts.annotate(listed)["subagents_running"] as? Int, 2)
	}

	// MARK: A subagent's own transcript

	func testSubagentTranscriptPagesByCursor() throws {
		try writeFinished()
		let transcripts = makeTranscripts()
		let all = try entries(transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: [:]))
		XCTAssertEqual(all.first?.kind, .user, "the prompt it was given")
		XCTAssertEqual(all.compactMap(\.tool).map(\.name), ["Bash"])

		var answer = try transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: ["limit": "1"])
		XCTAssertEqual(answer["id"] as? String, "w1:p1")
		XCTAssertEqual(answer["subagent_id"] as? String, Self.count)
		XCTAssertEqual(answer["harness"] as? String, "claude")
		XCTAssertEqual(answer["session_id"] as? String, Self.sessionID)
		XCTAssertEqual(answer["ended"] as? Bool, true, "it finished")
		XCTAssertEqual((answer["subagent"] as? [String: Any])?["status"] as? String, "done")
		let cursor = try XCTUnwrap(answer["cursor"] as? String)
		XCTAssertTrue(cursor.hasSuffix("." + Self.count.prefix(8)))
		var ids = try entries(answer).map(\.id)
		while answer["has_earlier"] as? Bool == true {
			answer = try transcripts.subagentTranscript(
				"w1:p1", subagent: Self.count, query: ["before": answer["start"] as! String, "limit": "1"])
			ids = try entries(answer).map(\.id) + ids
		}
		XCTAssertEqual(ids, all.map(\.id))
		XCTAssertEqual(try entries(transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: ["since": cursor])), [])

		// The other subagent's cursor, or the session's, is stale here: start over.
		let other = try transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: ["since": "10." + Self.read.prefix(8)])
		XCTAssertEqual(other["reset"] as? Bool, true)
		let session = try transcripts.subagentTranscript(
			"w1:p1", subagent: Self.count, query: ["since": "10." + Self.sessionID.prefix(8)])
		XCTAssertEqual(session["reset"] as? Bool, true)
		for bad in ["../x", "1.2.3", "abc." + Self.count.prefix(8)] {
			XCTAssertThrowsError(try transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: ["since": bad])) {
				XCTAssertEqual(($0 as? APIError)?.code, "bad_request", bad)
			}
		}
		XCTAssertThrowsError(try transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: ["limit": "0"])) {
			XCTAssertEqual(($0 as? APIError)?.code, "bad_request")
		}
	}

	func testOnlyTheSessionsOwnSubagentsAreRead() throws {
		try writeFinished()
		// A log beside the real ones that no call in the session started.
		try FileManager.default.copyItem(
			at: subagentFolder.appendingPathComponent("agent-\(Self.count).jsonl"),
			to: subagentFolder.appendingPathComponent("agent-a0000000000000000.jsonl"))
		let transcripts = makeTranscripts()
		let cases: [(String, String)] = [
			("w1:p1", "a0000000000000000"), ("w1:p1", "../../../etc/passwd"), ("w1:p1", "..%2F..%2Fetc"),
			("w1:p1", "agent-\(Self.count).jsonl"), ("w1:p1", ""), ("w1:p1", String(repeating: "a", count: 65)),
			("tmux:p1", Self.count), ("m_mini.w1:p1", Self.count), ("w9:p9", Self.count),
		]
		for (agent, sid) in cases {
			XCTAssertThrowsError(try transcripts.subagentTranscript(agent, subagent: sid, query: [:])) {
				XCTAssertEqual(($0 as? APIError)?.code, "subagent_unavailable", "\(agent) \(sid)")
				XCTAssertEqual(($0 as? APIError)?.status, 404)
			}
		}
		// A pane running another session in the same folder doesn't reach this one's subagents.
		try Data("{}\n".utf8).write(to: log.deletingLastPathComponent().appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl"))
		panes["w1:p2"] = AgentTranscriptTests.info(agent: "claude", name: "x", session: "11111111-2222-3333-4444-555555555555")
		XCTAssertThrowsError(try transcripts.subagentTranscript("w1:p2", subagent: Self.count, query: [:]))
	}

	// MARK: Live updates

	func testEventsWhenSubagentsChangeAndTheirLogsGrow() throws {
		try writeRunning()
		let transcripts = makeTranscripts()
		_ = try transcripts.transcript("w1:p1", query: [:])
		_ = try transcripts.subagentTranscript("w1:p1", subagent: Self.count, query: [:])
		transcripts.tick()
		XCTAssertFalse(published.contains { $0.0 == "agent.subagents" }, "nothing changed since the read")
		XCTAssertFalse(published.contains { $0.0 == "agent.subagent.transcript" })

		// The subagent's tool call returns: its log grows.
		let child = try lines("claude-subagents/subagents/agent-\(Self.count).jsonl")
		let firstTool = try XCTUnwrap(child.firstIndex { $0.contains(#""type":"tool_use""#) })
		let childLog = subagentFolder.appendingPathComponent("agent-\(Self.count).jsonl")
		for line in child[(firstTool + 1)...] { try append(line, to: childLog) }
		transcripts.tick()
		let grew = try XCTUnwrap(published.last { $0.0 == "agent.subagent.transcript" })
		XCTAssertEqual(grew.1["id"] as? String, "w1:p1")
		XCTAssertEqual(grew.1["subagent_id"] as? String, Self.count)
		XCTAssertEqual(grew.1["size"] as? Int, try FileManager.default.attributesOfItem(atPath: childLog.path)[.size] as? Int)

		// Both finish in the parent's log.
		published.removeAll()
		try write(lines("claude-subagents.jsonl"), to: log)
		transcripts.tick()
		let changed = try XCTUnwrap(published.last { $0.0 == "agent.subagents" })
		XCTAssertEqual(changed.1["id"] as? String, "w1:p1")
		XCTAssertEqual(changed.1["running"] as? Int, 0)
		XCTAssertEqual((changed.1["subagents"] as? [[String: Any]])?.compactMap { $0["status"] as? String }, ["done", "done"])

		// Time passing alone publishes nothing.
		published.removeAll()
		transcripts.tick(now: Date().addingTimeInterval(5))
		XCTAssertFalse(published.contains { $0.0 == "agent.subagents" })
	}

	// MARK: Screen fallback

	func testLiveClaudeWithoutALogFallsBackToItsScreen() throws {
		var info = AgentTranscriptTests.info(agent: "claude", name: "fresh", session: nil)
		info["cwd"] = "/private/tmp/no-such-project"
		panes["w1:p3"] = info
		screen = """
			✻ Working…
			◯ general-purpose  Simplifying wrapped-tool regex…   18m 52s · ↓ 306.0k tokens
			◯ Explore  Mapping the helper   2m 58s · ↓ 101.4k tokens
			"""
		let transcripts = makeTranscripts()
		let answer = try transcripts.transcript("w1:p3", query: [:])
		XCTAssertEqual(answer["subagents_source"] as? String, "screen")
		XCTAssertEqual(answer["subagents_running"] as? Int, 2)
		let list = try subagents(answer)
		XCTAssertEqual(list.map(\.type), ["general-purpose", "Explore"])
		XCTAssertTrue(list.allSatisfy { !$0.hasTranscript })

		// A Codex screen isn't parsed for Claude Code's lines.
		var codex = info
		codex["agent"] = "codex"
		panes["w1:p4"] = codex
		XCTAssertEqual(try transcripts.transcript("w1:p4", query: [:])["subagents_running"] as? Int, 0)

		// A tmux agent's screen read through the output route counts in the list.
		transcripts.noteScreen("tmux:p1", text: screen!)
		XCTAssertEqual(transcripts.annotate(["id": "tmux:p1", "agent": "claude"])["subagents_running"] as? Int, 2)
		XCTAssertNil(transcripts.annotate(["id": "tmux:p1", "agent": "codex"])["subagents_running"])
	}

	// MARK: Route

	func testRouteIsSignedAndAdvertised() async throws {
		let route = try XCTUnwrap(LinkAPI.match("GET", "/v1/agents/w1:p1/subagents/\(Self.count)/transcript"))
		XCTAssertEqual(route.name, "agents.subagent.transcript")
		XCTAssertEqual(route.auth, .signed)
		XCTAssertEqual(route.agentID, "w1:p1")
		XCTAssertEqual(route.requestID, Self.count)
		XCTAssertNil(LinkAPI.match("POST", "/v1/agents/w1:p1/subagents/\(Self.count)/transcript"))
		XCTAssertNil(LinkAPI.match("GET", "/v1/agents/w1:p1/subagents//transcript"))
		XCTAssertNil(LinkAPI.match("GET", "/v1/agents/w1:p1/subagents/\(Self.count)/output"))

		let daemon = try TestDaemon()
		defer { daemon.stop() }
		let path = "/v1/agents/w1:p1/subagents/\(Self.count)/transcript"
		let unsigned = try await SoftPhone.send(URLRequest(url: URL(string: daemon.baseURL.absoluteString + path)!))
		XCTAssertEqual(unsigned.status, 401)
		let phone = try await daemon.pairedPhone()
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String])?.contains("agent_subagents") == true)
		let tmux = try await phone.call("GET", "/v1/agents/tmux:p1/subagents/\(Self.count)/transcript")
		XCTAssertEqual(tmux.status, 404)
		XCTAssertEqual(tmux.errorCode, "subagent_unavailable")
		let traversal = try await phone.call("GET", "/v1/agents/w1:p1/subagents/..%2F..%2Fetc/transcript")
		XCTAssertEqual(traversal.status, 404)
		let both = try await phone.call("GET", path + "?since=0.a&before=0.a")
		XCTAssertEqual(both.status, 400)
		let unknown = try await phone.call("GET", path + "?page=2")
		XCTAssertEqual(unknown.status, 400)
	}
}
