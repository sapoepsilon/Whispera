import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// `GET /v1/agents/{id}/transcript`: the agent's session log found through the session id
/// herdr reports for its pane, paged by cursor, and still readable after the agent exits.
final class AgentTranscriptTests: XCTestCase {
	static let claudeID = "92338855-caa7-4374-a612-a1cbe4bc7b71"
	static let codexID = "01a1817c-74ae-7eb2-867b-a845d6276530"

	var root: URL!
	var locator: SessionLocator!
	var claudeLog: URL!
	/// What herdr answers for each pane (nil: a bare shell).
	var panes: [String: [String: Any]] = [:]
	var published: [(String, [String: Any])] = []

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString.prefix(8))")
		let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
		locator = SessionLocator(claudeHome: claude, codexHome: codex)
		let project = claude.appendingPathComponent("projects/-private-tmp-r1transcript-sandbox")
		try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
		claudeLog = project.appendingPathComponent(Self.claudeID + ".jsonl")
		try FileManager.default.copyItem(at: try fixture("claude-haiku"), to: claudeLog)
		let day = codex.appendingPathComponent("sessions/2026/10/28")
		try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
		try FileManager.default.copyItem(
			at: try fixture("codex-low"), to: day.appendingPathComponent("rollout-2026-10-28T01-49-39-\(Self.codexID).jsonl"))
		try Data(#"{"id":"\#(Self.codexID)","thread_name":"Draft __eq__ function plan"}"#.utf8 + [0x0A])
			.write(to: codex.appendingPathComponent("session_index.jsonl"))
		// Another session in the same folder that no pane names.
		try Data("{}\n".utf8).write(to: project.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl"))
		panes = [
			"w1:p1": Self.info(agent: "claude", name: "cc", session: Self.claudeID),
			"w1:p2": Self.info(agent: "codex", name: "cx", session: Self.codexID),
		]
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
	}

	private func fixture(_ name: String) throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
	}

	static func info(agent: String, name: String, session: String?) -> [String: Any] {
		var info: [String: Any] = [
			"agent": agent, "name": name, "pane_id": "w1:p1", "cwd": "/private/tmp/r1transcript/sandbox", "agent_status": "idle",
		]
		if let session { info["agent_session"] = ["agent": agent, "kind": "id", "source": "herdr:\(agent)", "value": session] }
		return info
	}

	private func makeTranscripts(state: String? = nil) -> AgentTranscripts {
		AgentTranscripts(
			readAgent: { [unowned self] pane in self.panes[pane] }, locator: locator,
			statePath: state ?? root.appendingPathComponent("transcripts.json").path,
			publish: { [unowned self] event, data in self.published.append((event, data)) })
	}

	private func entries(_ answer: [String: Any]) throws -> [SessionEntry] {
		try JSONDecoder().decode([SessionEntry].self, from: JSONSerialization.data(withJSONObject: answer["entries"] ?? []))
	}

	func testReadsTheSessionHerdrNamesForThePane() throws {
		let transcripts = makeTranscripts()
		let answer = try transcripts.transcript("w1:p1", query: [:])
		XCTAssertEqual(answer["harness"] as? String, "claude")
		XCTAssertEqual(answer["session_id"] as? String, Self.claudeID)
		XCTAssertEqual(answer["title"] as? String, "Python Point class formatting")
		XCTAssertEqual(answer["ended"] as? Bool, false)
		let read = try entries(answer)
		XCTAssertEqual(read.filter { $0.kind == .user }.count, 6)
		XCTAssertTrue(read.contains { $0.tool?.name == "Edit" })

		let codex = try transcripts.transcript("w1:p2", query: [:])
		XCTAssertEqual(codex["harness"] as? String, "codex")
		XCTAssertEqual(codex["title"] as? String, "Draft __eq__ function plan")
		XCTAssertEqual(try entries(codex).filter { $0.kind == .user }.count, 4)
	}

	func testPagesBackwardAndReadsOnFromTheCursor() throws {
		let transcripts = makeTranscripts()
		let all = try entries(transcripts.transcript("w1:p1", query: [:])).map(\.id)
		var answer = try transcripts.transcript("w1:p1", query: ["limit": "5"])
		var ids = try entries(answer).map(\.id)
		let cursor = try XCTUnwrap(answer["cursor"] as? String)
		XCTAssertTrue(cursor.hasSuffix("." + Self.claudeID.prefix(8)))
		while answer["has_earlier"] as? Bool == true {
			answer = try transcripts.transcript("w1:p1", query: ["before": answer["start"] as! String, "limit": "5"])
			ids = try entries(answer).map(\.id) + ids
		}
		XCTAssertEqual(ids, all)

		// Nothing new, then a line appended by the agent.
		XCTAssertEqual(try entries(transcripts.transcript("w1:p1", query: ["since": cursor])), [])
		let line = #"{"type":"assistant","uuid":"new-line","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"More"}]}}"#
		let handle = try FileHandle(forWritingTo: claudeLog)
		try handle.seekToEnd()
		handle.write(Data((line + "\n").utf8))
		try handle.close()
		transcripts.tick()
		XCTAssertEqual(published.last?.0, "agent.transcript")
		XCTAssertEqual(published.last?.1["id"] as? String, "w1:p1")
		let more = try transcripts.transcript("w1:p1", query: ["since": cursor])
		XCTAssertEqual(try entries(more).map(\.text), ["More"])
		XCTAssertEqual(more["reset"] as? Bool, false)
	}

	func testStaleOrForgedCursorsStartOverOrAreRefused() throws {
		let transcripts = makeTranscripts()
		let stale = try transcripts.transcript("w1:p1", query: ["since": "120.01a1817c"])
		XCTAssertEqual(stale["reset"] as? Bool, true, "another session's cursor")
		let midLine = try transcripts.transcript("w1:p1", query: ["since": "7.\(Self.claudeID.prefix(8))"])
		XCTAssertEqual(midLine["reset"] as? Bool, true, "not a line start")
		for bad in ["../x", "1.2.3", "abc.92338855", "99999999999999999999.92338855"] {
			XCTAssertThrowsError(try transcripts.transcript("w1:p1", query: ["since": bad])) {
				XCTAssertEqual(($0 as? APIError)?.code, "bad_request", bad)
			}
		}
		XCTAssertThrowsError(try transcripts.transcript("w1:p1", query: ["limit": "0"]))
	}

	func testOnlyTheNamedSessionIsEverRead() throws {
		let transcripts = makeTranscripts()
		// A pane whose agent reports no session, and one that names a path.
		panes["w1:p3"] = Self.info(agent: "claude", name: "x", session: nil)
		XCTAssertEqual(try entries(transcripts.transcript("w1:p3", query: [:])), [])
		panes["w1:p4"] = Self.info(agent: "claude", name: "y", session: "../../../etc/passwd")
		XCTAssertEqual(try entries(transcripts.transcript("w1:p4", query: [:])), [])
		panes["w1:p5"] = Self.info(agent: "bash", name: "z", session: Self.claudeID)
		XCTAssertEqual(try entries(transcripts.transcript("w1:p5", query: [:])), [])
		for id in ["tmux:p1", "m_mini.w1:p1"] {
			XCTAssertThrowsError(try transcripts.transcript(id, query: [:])) {
				XCTAssertEqual(($0 as? APIError)?.code, "transcript_unavailable")
			}
		}
		XCTAssertThrowsError(try transcripts.transcript("w9:p9", query: [:])) {
			XCTAssertEqual(($0 as? APIError)?.status, 404, "a pane that never had an agent")
		}
	}

	func testTheConversationOutlivesTheAgentAndTheHelper() throws {
		let state = root.appendingPathComponent("transcripts.json").path
		let transcripts = makeTranscripts(state: state)
		// Seen in a listing only: the phone never opened this chat before the agent exited.
		transcripts.note { [panes] in [panes["w1:p2"]!.merging(["pane_id": "w1:p2"]) { $1 }] }
		panes["w1:p2"] = nil
		let ended = try transcripts.transcript("w1:p2", query: [:])
		XCTAssertEqual(ended["ended"] as? Bool, true)
		XCTAssertEqual(ended["name"] as? String, "cx")
		XCTAssertEqual(try entries(ended).filter { $0.kind == .user }.count, 4)

		// A restarted helper still knows it.
		let restarted = makeTranscripts(state: state)
		XCTAssertEqual(try restarted.transcript("w1:p2", query: [:])["session_id"] as? String, Self.codexID)
		let mode = try FileManager.default.attributesOfItem(atPath: state)[.posixPermissions] as? Int
		XCTAssertEqual(mode, 0o600)

		// A new agent in the same pane, before its log exists, shows nothing of the old one.
		panes["w1:p2"] = Self.info(agent: "claude", name: "cx", session: "42068914-6d86-42a1-acc0-cfbd36e1e9ee")
		let fresh = try restarted.transcript("w1:p2", query: [:])
		XCTAssertEqual(try entries(fresh), [])
		XCTAssertEqual(fresh["ended"] as? Bool, false)
	}

	func testRouteIsSignedAndAdvertised() throws {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/transcript")?.name, "agents.transcript")
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/transcript")?.auth, .signed)
		XCTAssertNil(LinkAPI.match("POST", "/v1/agents/w1:p1/transcript"))
	}

	func testOverHTTP() async throws {
		let daemon = try TestDaemon()
		defer { daemon.stop() }
		let unsigned = try await SoftPhone.send(URLRequest(url: URL(string: daemon.baseURL.absoluteString + "/v1/agents/w1:p1/transcript")!))
		XCTAssertEqual(unsigned.status, 401)
		let phone = try await daemon.pairedPhone()
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String])?.contains("agent_transcript") == true)
		let tmux = try await phone.call("GET", "/v1/agents/tmux:p1/transcript")
		XCTAssertEqual(tmux.status, 404)
		XCTAssertEqual(tmux.errorCode, "transcript_unavailable")
		let both = try await phone.call("GET", "/v1/agents/w1:p1/transcript?since=0.a&before=0.a")
		XCTAssertEqual(both.status, 400)
	}

	// MARK: Agents that start without a log

	/// A Codex started from New agent has no rollout until its first prompt and herdr names no
	/// session yet: the chat is empty, and the pane binds as soon as the rollout appears in
	/// its folder, with an `agent.transcript` event so the phone reads it.
	func testCodexStartedWithoutASessionBindsWhenItsRolloutAppears() throws {
		panes["w1:p3"] = Self.info(agent: "codex", name: "cnew", session: nil)
		let transcripts = makeTranscripts()
		_ = try transcripts.transcript("w1:p2", query: [:])
		XCTAssertEqual(try entries(try transcripts.transcript("w1:p3", query: [:])), [])
		let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
		let day = root.appendingPathComponent(String(format: "codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
		try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
		let id = "01a182f0-af6c-78b1-abf3-31466ce625f9"
		let lines = [
			#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/private/tmp/r1transcript/sandbox"}}"#,
			#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"hi from new codex"}]}}}"#,
		]
		try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: day.appendingPathComponent("rollout-2026-10-28T08-36-00-\(id).jsonl"))
		transcripts.tick()
		XCTAssertTrue(published.contains { $0.0 == "agent.transcript" && $0.1["id"] as? String == "w1:p3" })
		let answer = try transcripts.transcript("w1:p3", query: [:])
		XCTAssertEqual(answer["session_id"] as? String, id)
		// A session another pane already reads is never taken by folder.
		XCTAssertEqual(transcripts.binding("w1:p2")?.sessionID, Self.codexID)
	}

	/// A turn with a prompt and no end, quiet for two seconds, is an agent waiting on the owner.
	func testOpenQuietTurnIsWaiting() throws {
		let transcripts = makeTranscripts()
		_ = try transcripts.transcript("w1:p1", query: [:])
		XCTAssertFalse(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)), "the fixture's last turn ended")
		let handle = try FileHandle(forWritingTo: claudeLog)
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(#"{"type":"user","uuid":"u-open","message":{"role":"user","content":"Edit calc.py"}}"#.utf8 + [0x0A]))
		try handle.close()
		XCTAssertFalse(transcripts.waiting("w1:p1"), "just written: the agent may still be thinking")
		XCTAssertTrue(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(3)))
	}

	private func append(_ lines: [[String: Any]], to url: URL) throws {
		let handle = try FileHandle(forWritingTo: url)
		try handle.seekToEnd()
		for line in lines { try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: line) + [0x0A]) }
		try handle.close()
	}

	/// Claude Code's idle compaction ("Compacted while idle, before the prompt cache expired")
	/// writes a boundary and a summary `user` line after the turn ended, and no turn end.
	func testIdleCompactionIsNotWaiting() throws {
		let transcripts = makeTranscripts()
		_ = try transcripts.transcript("w1:p1", query: [:])
		try append(
			[
				["type": "system", "subtype": "compact_boundary", "uuid": "cb-1", "content": "Conversation compacted"],
				["type": "user", "uuid": "cs-1", "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
					"message": ["role": "user", "content": "This session is being continued from a previous conversation."]],
				["type": "system", "subtype": "informational", "content": "Compacted while idle, before the prompt cache expired"],
			], to: claudeLog)
		XCTAssertFalse(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)))
		XCTAssertEqual(transcripts.turnOpen("w1:p1"), false)
		let read = try entries(transcripts.transcript("w1:p1", query: [:]))
		XCTAssertEqual(read.last?.text, "Conversation compacted")
		XCTAssertFalse(read.contains { $0.id == "cs-1" }, "the summary is not a prompt")
	}

	/// The pane's agent moves to a new session (continued, cleared, restarted): the transcript,
	/// the turn and the cursor follow herdr's session id, not the one bound first.
	func testTranscriptFollowsTheSessionWhenThePaneSwitches() throws {
		let transcripts = makeTranscripts()
		let first = try transcripts.transcript("w1:p1", query: [:])
		let oldCursor = try XCTUnwrap(first["cursor"] as? String)
		// The old session was left mid-turn.
		try append([["type": "user", "uuid": "u-open", "message": ["role": "user", "content": "Edit calc.py"]]], to: claudeLog)
		XCTAssertTrue(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)))

		let nextID = "7b0e4c1a-9a2f-4d55-8f3e-0c6d2b1a9e77"
		let next = claudeLog.deletingLastPathComponent().appendingPathComponent(nextID + ".jsonl")
		try Data().write(to: next)
		try append(
			[
				["type": "user", "uuid": "n-1", "timestamp": "2026-10-28T23:39:36.313Z",
					"message": ["role": "user", "content": "keep going"]],
				["type": "assistant", "uuid": "n-2", "message": ["role": "assistant", "content": [["type": "text", "text": "On it"]]]],
				["type": "system", "subtype": "turn_duration", "durationMs": 900],
			], to: next)
		panes["w1:p1"] = Self.info(agent: "claude", name: "cc", session: nextID)

		let followed = try transcripts.transcript("w1:p1", query: ["since": oldCursor])
		XCTAssertEqual(followed["session_id"] as? String, nextID)
		XCTAssertEqual(followed["reset"] as? Bool, true, "the old session's cursor starts the new one over")
		XCTAssertEqual(try entries(followed).map(\.text), ["keep going", "On it"])
		XCTAssertEqual(transcripts.binding("w1:p1")?.path, next.path)
		XCTAssertFalse(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)), "the new session's turn ended")

		// A phone on the new cursor reads on from there.
		let cursor = try XCTUnwrap(followed["cursor"] as? String)
		XCTAssertTrue(cursor.hasSuffix("." + nextID.prefix(8)))
		try append([["type": "user", "uuid": "n-3", "message": ["role": "user", "content": "thanks"]]], to: next)
		XCTAssertEqual(try entries(transcripts.transcript("w1:p1", query: ["since": cursor])).map(\.id), ["n-3"])
	}

	/// herdr names a new session whose log isn't written yet: the old session no longer
	/// answers for the pane, so its open turn can't keep the agent "blocked".
	func testANewSessionWithoutALogDropsTheOldOne() throws {
		let transcripts = makeTranscripts()
		_ = try transcripts.transcript("w1:p1", query: [:])
		try append([["type": "user", "uuid": "u-open", "message": ["role": "user", "content": "Edit calc.py"]]], to: claudeLog)
		XCTAssertTrue(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)))
		panes["w1:p1"] = Self.info(agent: "claude", name: "cc", session: "42068914-6d86-42a1-acc0-cfbd36e1e9ee")
		transcripts.ensureBound("w1:p1")
		XCTAssertNil(transcripts.binding("w1:p1"))
		XCTAssertFalse(transcripts.waiting("w1:p1", now: Date().addingTimeInterval(10)))
	}
}
