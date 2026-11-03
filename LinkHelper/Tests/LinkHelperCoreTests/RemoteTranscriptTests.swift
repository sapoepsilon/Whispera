import Foundation
import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// The transcripts of agents on another herdr machine, read over ssh into a local mirror. The
/// "remote" is a sandboxed `sh` with its own HOME (named to break naive quoting) running the
/// helper's real scripts against real files: never a real ssh or another Mac.
final class RemoteTranscriptTests: XCTestCase {
	static let claudeID = AgentTranscriptTests.claudeID
	static let codexID = AgentTranscriptTests.codexID
	static let subagentSession = AgentSubagentTests.sessionID
	static let id = "m_main.w1:p1"

	var root: URL!
	var home: URL!
	var project: URL!
	var claudeLog: URL!
	var panes: [String: [String: Any]] = [:]
	var down = false
	var scripts: [String] = []
	var outputs: [Int] = []
	var published: [(String, [String: Any])] = []

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-transcripts-\(UUID().uuidString.prefix(8))")
		// A HOME no unquoted or double-quoted expansion survives.
		home = root.appendingPathComponent("remote home 'q' $(touch PWNED) `touch PWNED2`")
		project = home.appendingPathComponent(".claude/projects/-private-tmp-r1transcript-sandbox")
		try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
		claudeLog = project.appendingPathComponent(Self.claudeID + ".jsonl")
		try FileManager.default.copyItem(at: fixture("claude-haiku.jsonl"), to: claudeLog)
		panes = ["w1:p1": AgentTranscriptTests.info(agent: "claude", name: "cc", session: Self.claudeID)]
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
	}

	private func fixture(_ path: String) throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(path)
	}

	/// The fake ssh: the script in a clean `sh` whose HOME is the remote home, from `root`.
	private func shell(_ machine: String, _ script: String, _ timeout: TimeInterval) throws -> Data {
		guard !down, machine == "main" else { throw APIError(503, "herdr_unavailable", "machine unreachable: Connection refused") }
		scripts.append(script)
		let result = try HerdrCLI.spawn(
			"/usr/bin/env", ["-i", "HOME=" + home.path, "PATH=/usr/bin:/bin", "/bin/sh", "-c", "cd " + HerdrCLI.shellQuote(root.path) + "; " + script],
			timeout: timeout)
		outputs.append(result.stdout.count)
		return result.stdout
	}

	private func makeRemote(window: Int = 2 << 20) -> RemoteTranscripts {
		let remote = RemoteTranscripts(
			shell: { [unowned self] in try self.shell($0, $1, $2) },
			readAgent: { [unowned self] machine, pane in
				guard machine == "main" else { throw APIError(404, "not_found", "no such herdr machine") }
				if self.down { throw APIError(503, "herdr_unavailable", "machine unreachable") }
				return self.panes[pane]
			},
			cacheDir: root.appendingPathComponent("mirror").path,
			publish: { [unowned self] in self.published.append(($0, $1)) })
		remote.window = window
		remote.fresh = 0
		return remote
	}

	private func makeTranscripts(_ remote: RemoteTranscripts) -> AgentTranscripts {
		AgentTranscripts(
			readAgent: { _ in nil }, locator: SessionLocator(claudeHome: root, codexHome: root), statePath: nil, remote: remote)
	}

	private func entries(_ answer: [String: Any]) throws -> [SessionEntry] {
		try JSONDecoder().decode([SessionEntry].self, from: JSONSerialization.data(withJSONObject: answer["entries"] ?? []))
	}

	private func offset(_ cursor: Any?) throws -> Int {
		try XCTUnwrap(Int(try XCTUnwrap((cursor as? String)?.split(separator: ".").first)))
	}

	private func append(_ text: String, to url: URL) throws {
		let handle = try FileHandle(forWritingTo: url)
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
		try handle.close()
	}

	private func lines(_ url: URL) throws -> [String] {
		try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
	}

	// MARK: Reading

	func testARemoteAgentsTranscriptIsItsLogReadLikeALocalOne() throws {
		let transcripts = makeTranscripts(makeRemote())
		let answer = try transcripts.transcript(Self.id, query: [:])
		let local = try SessionLog.read(claudeLog, harness: .claude)
		XCTAssertEqual(try entries(answer), local.entries)
		XCTAssertEqual(answer["session_id"] as? String, Self.claudeID)
		XCTAssertEqual(answer["harness"] as? String, "claude")
		XCTAssertEqual(answer["title"] as? String, "Python Point class formatting")
		XCTAssertEqual(answer["ended"] as? Bool, false)
		XCTAssertEqual(answer["has_earlier"] as? Bool, false)
		XCTAssertEqual(try offset(answer["cursor"]), local.end)
		XCTAssertEqual(scripts.count, 1, "found and fetched in one round trip")
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED2").path))
	}

	func testTheCursorFetchesOnlyWhatWasAppended() throws {
		let remote = makeRemote()
		let transcripts = makeTranscripts(remote)
		let first = try transcripts.transcript(Self.id, query: [:])
		let cursor = try XCTUnwrap(first["cursor"] as? String)
		let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: claudeLog.path)[.size] as? Int)

		let line = #"{"type":"user","uuid":"u-new-1","timestamp":"2026-10-28T10:00:00Z","message":{"role":"user","content":"one more thing"}}"#
		try append(line + "\n", to: claudeLog)
		let next = try transcripts.transcript(Self.id, query: ["since": cursor])
		XCTAssertEqual(try entries(next).map(\.text), ["one more thing"])
		XCTAssertEqual(try entries(next).first?.offset, size)
		XCTAssertEqual(next["reset"] as? Bool, false)
		XCTAssertEqual(remote.mirror(Self.id)?.log.fetched, size + line.utf8.count + 1)
		XCTAssertTrue(scripts.last!.contains("N=\(size);"), "the sync asks from the mirrored end")
		XCTAssertLessThan(outputs.last!, 1024, "only the new line came back")

		// A line still being written waits for the next read.
		try append(#"{"type":"user","uuid":"u-new-2""#, to: claudeLog)
		let partial = try transcripts.transcript(Self.id, query: ["since": try XCTUnwrap(next["cursor"] as? String)])
		XCTAssertTrue(try entries(partial).isEmpty)
		try append(#","timestamp":"2026-10-28T10:00:01Z","message":{"role":"user","content":"and another"}}"# + "\n", to: claudeLog)
		let rest = try transcripts.transcript(Self.id, query: ["since": try XCTUnwrap(partial["cursor"] as? String)])
		XCTAssertEqual(try entries(rest).map(\.text), ["and another"])
	}

	func testALongLogIsMirroredFromItsEndInRemoteOffsetsAndPagedBack() throws {
		let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: claudeLog.path)[.size] as? Int)
		let remote = makeRemote(window: 6 << 10)
		let transcripts = makeTranscripts(remote)
		let answer = try transcripts.transcript(Self.id, query: ["limit": "4"])
		let local = try SessionLog.read(claudeLog, harness: .claude, limit: 4)
		let first = try entries(answer)
		XCTAssertFalse(first.isEmpty)
		XCTAssertEqual(first, Array(local.entries.suffix(first.count)), "the remote file's offsets and ids")
		XCTAssertEqual(answer["has_earlier"] as? Bool, true)
		let mirror = try XCTUnwrap(remote.mirror(Self.id))
		XCTAssertGreaterThan(mirror.log.base, 0, "only the end was fetched")
		XCTAssertLessThanOrEqual(mirror.log.fetched - mirror.log.base, 2 * (6 << 10), "the window, paged back once at most")
		XCTAssertEqual(mirror.log.fetched, size)
		XCTAssertTrue(outputs.allSatisfy { $0 < (6 << 10) * 4 / 3 + 1024 }, "each answer is capped at the window")

		// Paging back past the mirror's start fetches the bytes before it; a short page of a
		// heavy log is the newest part of what a direct read would give.
		var start = try XCTUnwrap(answer["start"] as? String)
		var older = first
		var pages = 0
		var more = true
		while more, pages < 50 {
			let page = try transcripts.transcript(Self.id, query: ["before": start, "limit": "4"])
			let read = try entries(page)
			let direct = try SessionLog.read(claudeLog, harness: .claude, before: try offset(start), limit: 4)
			XCTAssertEqual(read, Array(direct.entries.suffix(read.count)), "page \(pages)")
			older = read + older
			start = try XCTUnwrap(page["start"] as? String)
			more = page["has_earlier"] as? Bool ?? false
			pages += 1
		}
		XCTAssertFalse(more)
		XCTAssertEqual(older, try SessionLog.read(claudeLog, harness: .claude, limit: 1000).entries, "every entry once, in order")
		XCTAssertEqual(remote.mirror(Self.id)?.log.base, 0)
	}

	func testABacklogLongerThanTheWindowStartsOverAtTheEnd() throws {
		let remote = makeRemote(window: 8 << 10)
		let transcripts = makeTranscripts(remote)
		let first = try transcripts.transcript(Self.id, query: [:])
		let cursor = try XCTUnwrap(first["cursor"] as? String)
		var appended = ""
		for index in 0..<200 {
			appended += #"{"type":"user","uuid":"u-\#(index)","timestamp":"2026-10-28T10:00:00Z","message":{"role":"user","content":"line \#(index) padding padding padding"}}"# + "\n"
		}
		try append(appended, to: claudeLog)
		let next = try transcripts.transcript(Self.id, query: ["since": cursor, "limit": "10"])
		XCTAssertEqual(next["reset"] as? Bool, true, "the phone replaces what it shows")
		XCTAssertEqual(try entries(next).last?.text, "line 199 padding padding padding")
		XCTAssertLessThan(outputs.last!, (8 << 10) * 4 / 3 + 1024, "never more than the window per answer")
	}

	// MARK: Rotation and sessions

	func testAReplacedLogStartsOver() throws {
		let remote = makeRemote()
		let transcripts = makeTranscripts(remote)
		let first = try transcripts.transcript(Self.id, query: [:])
		let cursor = try XCTUnwrap(first["cursor"] as? String)
		// Same name, other content, longer than the old one: only its head tells.
		let other = try lines(fixture("claude-subagents.jsonl"))
		var text = other.joined(separator: "\n") + "\n"
		while text.utf8.count < 40_000 { text += other.last! + "\n" }
		try text.write(to: claudeLog, atomically: true, encoding: .utf8)
		let next = try transcripts.transcript(Self.id, query: ["since": cursor])
		XCTAssertEqual(next["reset"] as? Bool, true)
		XCTAssertEqual(try entries(next), try SessionLog.read(claudeLog, harness: .claude).entries)

		// Truncated.
		try (other.prefix(3).joined(separator: "\n") + "\n").write(to: claudeLog, atomically: true, encoding: .utf8)
		let shorter = try transcripts.transcript(Self.id, query: ["since": try XCTUnwrap(next["cursor"] as? String)])
		XCTAssertEqual(shorter["reset"] as? Bool, true)
		XCTAssertEqual(try entries(shorter), try SessionLog.read(claudeLog, harness: .claude).entries)
	}

	func testANewSessionInThePaneIsFollowed() throws {
		let transcripts = makeTranscripts(makeRemote())
		let first = try transcripts.transcript(Self.id, query: [:])
		let cursor = try XCTUnwrap(first["cursor"] as? String)
		// The agent was cleared: herdr names a new session, written in the same folder.
		let newID = "5a5a5a5a-1111-2222-3333-444444444444"
		let line = #"{"type":"user","uuid":"u-fresh","timestamp":"2026-10-28T10:00:00Z","message":{"role":"user","content":"fresh start"}}"#
		try (line + "\n").write(to: project.appendingPathComponent(newID + ".jsonl"), atomically: true, encoding: .utf8)
		panes["w1:p1"] = AgentTranscriptTests.info(agent: "claude", name: "cc", session: newID)
		let next = try transcripts.transcript(Self.id, query: ["since": cursor])
		XCTAssertEqual(next["session_id"] as? String, newID)
		XCTAssertEqual(next["reset"] as? Bool, true, "the old session's cursor is stale")
		XCTAssertEqual(try entries(next).map(\.text), ["fresh start"])
	}

	func testALogNotWrittenYetIsAnEmptyLiveTranscript() throws {
		panes["w1:p1"] = AgentTranscriptTests.info(agent: "claude", name: "cc", session: "77777777-1111-2222-3333-444444444444")
		let answer = try makeTranscripts(makeRemote()).transcript(Self.id, query: [:])
		XCTAssertEqual(try entries(answer), [])
		XCTAssertEqual(answer["ended"] as? Bool, false)
	}

	func testCodexRolloutsAreFoundByIdWithTheirTitle() throws {
		let day = home.appendingPathComponent(".codex/sessions/2026/10/28")
		try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
		let rollout = day.appendingPathComponent("rollout-2026-10-28T01-49-39-\(Self.codexID).jsonl")
		try FileManager.default.copyItem(at: fixture("codex-low.jsonl"), to: rollout)
		try Data(#"{"id":"\#(Self.codexID)","thread_name":"Draft __eq__ function plan"}"#.utf8 + [0x0A])
			.write(to: home.appendingPathComponent(".codex/session_index.jsonl"))
		panes["w1:p2"] = AgentTranscriptTests.info(agent: "codex", name: "cx", session: Self.codexID)
		let transcripts = makeTranscripts(makeRemote())
		let answer = try transcripts.transcript("m_main.w1:p2", query: [:])
		XCTAssertEqual(answer["harness"] as? String, "codex")
		XCTAssertEqual(answer["title"] as? String, "Draft __eq__ function plan")
		XCTAssertEqual(try entries(answer), try SessionLog.read(rollout, harness: .codex).entries)
	}

	// MARK: Unavailable

	func testAnUnreachableMachineServesWhatWasMirroredOrFallsBackToTheScreen() throws {
		let transcripts = makeTranscripts(makeRemote())
		down = true
		XCTAssertThrowsError(try transcripts.transcript(Self.id, query: [:])) { error in
			XCTAssertEqual((error as? APIError)?.code, "transcript_unavailable", "never read: the phone shows the screen")
		}
		down = false
		let first = try transcripts.transcript(Self.id, query: [:])
		down = true
		let offline = try transcripts.transcript(Self.id, query: [:])
		XCTAssertEqual(try entries(offline), try entries(first))
		XCTAssertEqual(offline["stale"] as? Bool, true)
		XCTAssertThrowsError(try transcripts.transcript("m_other.w1:p1", query: [:])) { error in
			XCTAssertEqual((error as? APIError)?.status, 404)
		}
	}

	func testWithoutRemoteReadsAMachinesAgentsAreUnavailable() throws {
		let transcripts = AgentTranscripts(readAgent: { _ in nil }, statePath: nil)
		XCTAssertThrowsError(try transcripts.transcript(Self.id, query: [:])) { error in
			XCTAssertEqual((error as? APIError)?.code, "transcript_unavailable")
		}
	}

	// MARK: Injection

	func testOnlyValidatedSingleQuotedValuesReachTheRemoteShell() throws {
		let remote = makeRemote()
		let transcripts = makeTranscripts(remote)
		// herdr reports something that is not a session id: nothing runs.
		panes["w1:p1"] = AgentTranscriptTests.info(agent: "claude", name: "cc", session: "x'; touch PWNED; '")
		XCTAssertThrowsError(try transcripts.transcript(Self.id, query: [:]))
		XCTAssertTrue(scripts.isEmpty)

		// A hostile folder only ever becomes a slug.
		var info = AgentTranscriptTests.info(agent: "claude", name: "cc", session: Self.claudeID)
		info["cwd"] = "/tmp/a'$(touch PWNED)\"`touch PWNED2`;b"
		panes["w1:p1"] = info
		_ = try transcripts.transcript(Self.id, query: [:])
		let script = try XCTUnwrap(scripts.last)
		XCTAssertTrue(script.contains("'" + SessionLocator.claudeSlug("/tmp/a'$(touch PWNED)\"`touch PWNED2`;b") + "'"))
		XCTAssertFalse(script.contains("$(touch"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED2").path))
		// The session was still found, through the other project folders.
		XCTAssertEqual(remote.mirror(Self.id)?.log.remote, claudeLog.path)

		// The path the remote found goes back single-quoted (HOME holds quotes and `$(…)`).
		_ = try transcripts.transcript(Self.id, query: [:])
		XCTAssertTrue(scripts.last!.contains("F=" + HerdrCLI.shellQuote(claudeLog.path) + ";"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
	}

	func testPathsTheRemoteAnswersAreCheckedBeforeUse() throws {
		let mirror = RemoteTranscripts.Mirror(
			machine: "main", harness: .claude, sessionID: Self.claudeID,
			log: .init(remote: "", local: root.appendingPathComponent("x")))
		XCTAssertTrue(RemoteTranscripts.isValidRemotePath("/Users/a/.claude/projects/-x/\(Self.claudeID).jsonl", mirror))
		XCTAssertFalse(RemoteTranscripts.isValidRemotePath("/etc/passwd", mirror))
		XCTAssertFalse(RemoteTranscripts.isValidRemotePath("relative/projects/\(Self.claudeID).jsonl", mirror))
		XCTAssertFalse(RemoteTranscripts.isValidRemotePath("/a/projects/../../\(Self.claudeID).jsonl", mirror))
		XCTAssertFalse(RemoteTranscripts.isValidRemotePath("/a/projects/x\n/\(Self.claudeID).jsonl", mirror))
		XCTAssertFalse(RemoteTranscripts.isValidSubagentFile("agent-../../x.jsonl"))
		XCTAssertFalse(RemoteTranscripts.isValidSubagentFile("agent-a b.jsonl"))
		XCTAssertTrue(RemoteTranscripts.isValidSubagentFile("agent-ab27a809cd2067164.meta.json"))
	}

	func testTheShellGoesOverTheDirectSSHAsOneArgument() throws {
		let log = root.appendingPathComponent("ssh-argv.log").path
		let ssh = root.appendingPathComponent("ssh").path
		try Data(
			"""
			#!/bin/sh
			for a in "$@"; do printf '%s\\n' "$a" >> '\(log)'; done
			while [ "$1" != "--" ]; do shift; done
			shift; shift
			cd \(HerdrCLI.shellQuote(root.path))
			exec /usr/bin/env -i HOME=\(HerdrCLI.shellQuote(home.path)) PATH=/usr/bin:/bin /bin/sh -c "$1"

			""".utf8
		).write(to: URL(fileURLWithPath: ssh))
		chmod(ssh, 0o755)
		let mirror = RemoteTranscripts.Mirror(
			machine: "main", harness: .claude, sessionID: Self.claudeID,
			log: .init(remote: "?/private/tmp/r1transcript/sandbox", local: root.appendingPathComponent("x")))
		let script = try RemoteTranscripts.syncScript(mirror, window: 1 << 20, subagentBudget: 1 << 20, subagentWindow: 1 << 16)
		let result = try HerdrCLI.spawnShell(ssh, "fake-main.ts", script, timeout: 8)
		let answer = try RemoteTranscripts.parse(result.stdout)
		XCTAssertEqual(answer.path, claudeLog.path)
		XCTAssertEqual(answer.log?.bytes, try Data(contentsOf: claudeLog))
		let argv = try String(contentsOfFile: log, encoding: .utf8)
		XCTAssertTrue(argv.contains("Compression=yes\n"))
		XCTAssertTrue(argv.contains("BatchMode=yes\n"))
		XCTAssertTrue(argv.contains("--\nfake-main.ts\n"))
		XCTAssertThrowsError(try HerdrCLI.spawnShell(ssh, "-oProxyCommand=x", script, timeout: 8))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
	}

	func testACutOffAnswerIsNotApplied() throws {
		let full = Data("\n\(RemoteTranscripts.ready)\nPATH /a/projects/x/\(Self.claudeID).jsonl\nSIZE 10\nHEAD \nDATA 0 aGVsbG8K\nEND\n".utf8)
		XCTAssertEqual(try RemoteTranscripts.parse(full).log?.bytes, Data("hello\n".utf8))
		let cut = full.prefix(full.count - 4)
		XCTAssertThrowsError(try RemoteTranscripts.parse(cut))
		XCTAssertThrowsError(try RemoteTranscripts.parse(Data("motd only\n".utf8)))
		XCTAssertFalse(try RemoteTranscripts.parse(Data("noise\n\(RemoteTranscripts.ready)\nMISSING\n".utf8)).found)
	}

	// MARK: Subagents and watching

	private func writeSubagentSession(finished: Bool) throws -> URL {
		let log = project.appendingPathComponent(Self.subagentSession + ".jsonl")
		let folder = project.appendingPathComponent(Self.subagentSession + "/subagents")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try? FileManager.default.removeItem(at: log)
		try FileManager.default.copyItem(at: fixture("claude-subagents.jsonl"), to: log)
		for id in [AgentSubagentTests.count, AgentSubagentTests.read] {
			for ext in ["jsonl", "meta.json"] {
				let target = folder.appendingPathComponent("agent-\(id).\(ext)")
				try? FileManager.default.removeItem(at: target)
				try FileManager.default.copyItem(at: fixture("claude-subagents/subagents/agent-\(id).\(ext)"), to: target)
			}
		}
		panes["w1:p1"] = AgentTranscriptTests.info(agent: "claude", name: "cc", session: Self.subagentSession)
		return folder
	}

	func testSubagentsAndTheirLogsComeAlongInTheSameRoundTrip() throws {
		let folder = try writeSubagentSession(finished: true)
		let transcripts = makeTranscripts(makeRemote())
		let answer = try transcripts.transcript(Self.id, query: [:])
		XCTAssertEqual(scripts.count, 1)
		let list = try JSONDecoder().decode([SessionSubagent].self, from: JSONSerialization.data(withJSONObject: answer["subagents"] ?? []))
		XCTAssertEqual(Set(list.map(\.id)), [AgentSubagentTests.count, AgentSubagentTests.read])
		XCTAssertEqual(answer["subagents_source"] as? String, "log")

		let child = try transcripts.subagentTranscript(Self.id, subagent: AgentSubagentTests.count, query: [:])
		let local = try SessionLog.readSubagent(folder.appendingPathComponent("agent-\(AgentSubagentTests.count).jsonl"), harness: .claude)
		XCTAssertEqual(try entries(child), local.entries)
		XCTAssertThrowsError(try transcripts.subagentTranscript(Self.id, subagent: "a0000000000000000", query: [:]))
		XCTAssertThrowsError(try transcripts.subagentTranscript(Self.id, subagent: "../x", query: [:]))
	}

	func testASubagentAskedForIsFetchedFirstWhenTheBudgetRanOut() throws {
		let folder = try writeSubagentSession(finished: true)
		let remote = makeRemote()
		// Room for about one subagent's files per sync.
		remote.subagentBudget = 7_000
		let transcripts = makeTranscripts(remote)
		_ = try transcripts.transcript(Self.id, query: [:])
		XCTAssertLessThan(remote.mirror(Self.id)?.subagents.count ?? 0, 4, "not every file came in the first sync")
		remote.fresh = 60
		for sid in [AgentSubagentTests.count, AgentSubagentTests.read] {
			let child = try transcripts.subagentTranscript(Self.id, subagent: sid, query: [:])
			let local = try SessionLog.readSubagent(folder.appendingPathComponent("agent-\(sid).jsonl"), harness: .claude)
			XCTAssertEqual(try entries(child), local.entries, sid)
		}
	}

	func testAWatchedRemoteLogThatGrowsPublishesAnEvent() throws {
		let remote = makeRemote()
		let transcripts = makeTranscripts(remote)
		_ = try transcripts.transcript(Self.id, query: [:])
		remote.tick()
		XCTAssertFalse(published.contains { $0.0 == "agent.transcript" }, "nothing new")
		try append(#"{"type":"user","uuid":"u-tick","message":{"role":"user","content":"hi"}}"# + "\n", to: claudeLog)
		remote.tick()
		let event = try XCTUnwrap(published.last { $0.0 == "agent.transcript" })
		XCTAssertEqual(event.1["id"] as? String, Self.id)
		XCTAssertEqual(event.1["size"] as? Int, try FileManager.default.attributesOfItem(atPath: claudeLog.path)[.size] as? Int)
		// The phone's read after the event answers from the mirror without another sync.
		remote.fresh = 60
		let syncs = remote.syncs
		_ = try transcripts.transcript(Self.id, query: [:])
		XCTAssertEqual(remote.syncs, syncs)
	}
}
