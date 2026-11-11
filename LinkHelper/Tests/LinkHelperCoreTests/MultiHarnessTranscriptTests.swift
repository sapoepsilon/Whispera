import WhisperaAgents
import WhisperaHerdr
import XCTest

@testable import LinkHelperCore

/// Codex and omp sessions read into the same entries as Claude Code's, from logs captured by
/// running each CLI on a one-line fix (`omp -p`, `omp` in an hc terminal, `codex exec --json`),
/// and the hc terminals they ran in projected onto the phone's agent objects.
final class MultiHarnessTranscriptTests: XCTestCase {
	static let ompID = "01a1c8f6-afa9-735a-8f90-01a9c3b8495c"
	static let ompInteractiveID = "01a1c8fb-50bc-7088-97b3-02b3f17c7ca6"
	static let codexID = "01a1c8f6-d6fd-75f1-be40-a95aa41ae7be"

	var root: URL!
	var locator: SessionLocator!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString.prefix(8))")
		locator = SessionLocator(
			claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"),
			ompHome: root.appendingPathComponent("omp"))
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
	}

	private func fixture(_ name: String, _ ext: String = "jsonl") throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
	}

	/// Places an omp fixture where omp keeps it, in a folder named the way omp names them.
	@discardableResult
	private func placeOmp(_ name: String, id: String, folder: String = "--private-tmp-omp-transcript-sandbox--") throws -> URL {
		let dir = root.appendingPathComponent("omp/sessions/\(folder)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let file = dir.appendingPathComponent("2026-11-11T04-56-12-457Z_\(id).jsonl")
		try FileManager.default.copyItem(at: try fixture(name), to: file)
		// A copy keeps the fixture's date; the agent wrote this log just now.
		try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
		return file
	}

	// MARK: omp reader

	func testOmpPrintModeReadsAsMessagesToolsAndADiff() throws {
		let page = try SessionLog.read(try fixture("omp-deepseek"), harness: .omp)
		let entries = page.entries
		XCTAssertEqual(entries.map(\.kind), [
			.user, .assistant, .tool, .toolResult, .tool, .toolResult, .tool, .toolResult, .assistant,
		])
		XCTAssertTrue(entries[0].text?.hasPrefix("Read hello.py, change greet") == true)
		XCTAssertEqual(entries[1].text, "I'll read the file first.")

		let read = try XCTUnwrap(entries[2].tool)
		XCTAssertEqual(read.name, "read")
		XCTAssertEqual(read.kind, .read)
		XCTAssertEqual(read.argument, "hello.py")
		XCTAssertEqual(entries[3].result?.toolID, read.id)
		XCTAssertEqual(entries[3].result?.output, "def greet(name):\n    return \"hi \" + name")

		let edit = try XCTUnwrap(entries[4].tool)
		XCTAssertEqual(edit.kind, .edit)
		XCTAssertEqual(edit.path, "hello.py")
		XCTAssertEqual(edit.edits, [SessionEdit(old: "return \"hi \" + name", new: "return \"hello, \" + name")])
		let applied = try XCTUnwrap(entries[5].result)
		XCTAssertEqual(applied.toolID, edit.id)
		XCTAssertEqual(applied.diff, [" def greet(name):", "-    return \"hi \" + name", "+    return \"hello, \" + name"])
		XCTAssertFalse(applied.isError)

		let run = try XCTUnwrap(entries[6].tool)
		XCTAssertEqual(run.kind, .run)
		XCTAssertEqual(run.argument, #"python3 -c "import hello; print(hello.greet(\"x\"))""#)
		XCTAssertEqual(entries[7].result?.output, "hello, x\n")
		XCTAssertEqual(entries[8].text, "Output: `hello, x")
		XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "ids are unique")
	}

	func testOmpInteractiveSessionHasItsTitleAndPagesLikeTheOthers() throws {
		let url = try fixture("omp-interactive")
		let all = try SessionLog.read(url, harness: .omp)
		XCTAssertEqual(all.title, "🐍 CALC: Fix add function in calc.py")
		XCTAssertEqual(all.entries.filter { $0.kind == .tool }.map { $0.tool?.kind }, [.read, .edit, .run])

		// Backward pages of two meet the whole read exactly, and forward from a cursor is empty.
		var page = try SessionLog.read(url, harness: .omp, limit: 2)
		var ids = page.entries.map(\.id)
		while page.hasEarlier {
			page = try SessionLog.read(url, harness: .omp, before: page.start, limit: 2)
			ids = page.entries.map(\.id) + ids
		}
		XCTAssertEqual(ids, all.entries.map(\.id))
		XCTAssertEqual(try SessionLog.read(url, harness: .omp, since: all.end).entries, [])
	}

	func testOmpTurnIsOpenWhileACallWaitsAndClosedAfterTheReply() throws {
		let full = try fixture("omp-interactive")
		XCTAssertEqual(SessionLog.turn(full, harness: .omp)?.open, false)

		// Cut right after the bash call was written: the turn waits on that call.
		let lines = try String(contentsOf: full, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
		let cut = try XCTUnwrap(lines.firstIndex { $0.contains(#""name":"bash""#) })
		let partial = root.appendingPathComponent("partial.jsonl")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try (lines[...cut].joined(separator: "\n") + "\n").write(to: partial, atomically: true, encoding: .utf8)
		let turn = try XCTUnwrap(SessionLog.turn(partial, harness: .omp))
		XCTAssertTrue(turn.open)
		XCTAssertEqual(turn.pendingTool?.name, "bash")
		XCTAssertEqual(turn.pendingTool?.kind, .run)
	}

	func testOmpAbortAndErrorStopsAreNotices() {
		let reader = OmpSessionReader()
		let aborted: [String: Any] = [
			"type": "message", "id": "a1",
			"message": ["role": "assistant", "content": [["type": "text", "text": "Starting"]], "stopReason": "aborted"],
		]
		XCTAssertEqual(reader.entries(line: aborted, offset: 0).map(\.kind), [.assistant, .notice])
		XCTAssertEqual(reader.entries(line: aborted, offset: 0).last?.text, "Interrupted")
		let failed: [String: Any] = [
			"type": "message", "id": "a2",
			"message": ["role": "assistant", "content": [], "stopReason": "error", "errorMessage": "socket closed"],
		]
		XCTAssertEqual(reader.entries(line: failed, offset: 0).map(\.text), ["Error: socket closed"])
		XCTAssertEqual(reader.entries(line: ["type": "compaction", "id": "c"], offset: 0).map(\.kind), [.notice])
		XCTAssertEqual(reader.entries(line: ["type": "custom", "customType": "tool_execution_start"], offset: 0), [])
	}

	func testOmpAskCallCarriesItsQuestionsAndAnswers() throws {
		let call: [String: Any] = [
			"type": "toolCall", "id": "call_1", "name": "ask",
			"arguments": [
				"i": "Clarify the target",
				"questions": [[
					"id": "target", "question": "Where should it go?",
					"options": [["label": "Left", "description": "x"], ["label": "Right", "description": "y"]],
				]],
			],
		]
		let reader = OmpSessionReader()
		let asked = reader.entries(
			line: ["type": "message", "id": "m1", "message": ["role": "assistant", "content": [call], "stopReason": "toolUse"]],
			offset: 0)
		let tool = try XCTUnwrap(asked.first?.tool)
		XCTAssertEqual(tool.questions, [SessionQuestion(header: "target", question: "Where should it go?", options: ["Left", "Right"])])
		let answered = reader.entries(
			line: [
				"type": "message", "id": "m2",
				"message": [
					"role": "toolResult", "toolCallId": "call_1", "toolName": "ask", "content": [["type": "text", "text": "Right"]],
					"details": ["results": [["question": "Where should it go?", "selectedOptions": ["Right"]]]],
				],
			], offset: 10)
		XCTAssertEqual(answered.first?.result?.answers, [SessionAnswer(question: "Where should it go?", answer: "Right")])
	}

	// MARK: Locating omp logs

	func testOmpLogIsFoundByIdOrByTheFolderItRanIn() throws {
		let placed = try placeOmp("omp-interactive", id: Self.ompInteractiveID)
		XCTAssertEqual(locator.ompLog(sessionID: Self.ompInteractiveID)?.lastPathComponent, placed.lastPathComponent)
		XCTAssertNil(locator.ompLog(sessionID: "../../etc/passwd"))
		XCTAssertEqual(SessionLocator.sessionID(of: placed, harness: .omp), Self.ompInteractiveID)

		// The log names /tmp/…; hc reports the resolved /private/tmp/….
		let after = Date().addingTimeInterval(-60)
		XCTAssertEqual(
			locator.newestOmpLog(cwd: "/private/tmp/omp-transcript/sandbox", after: after)?.lastPathComponent, placed.lastPathComponent)
		XCTAssertNil(locator.newestOmpLog(cwd: "/private/tmp/elsewhere", after: after))
		XCTAssertNil(locator.newestOmpLog(cwd: "/private/tmp/omp-transcript/sandbox", after: Date().addingTimeInterval(60)))
	}

	func testAnOmpAgentWithoutASessionIdIsReadFromItsFolder() throws {
		try placeOmp("omp-interactive", id: Self.ompInteractiveID)
		let info: [String: Any] = [
			"pane_id": "hc:t39", "agent": "omp", "name": "wl-omp", "cwd": "/private/tmp/omp-transcript/sandbox",
		]
		XCTAssertEqual(AgentTranscripts.harness(info), .omp)
		let transcripts = AgentTranscripts(readAgent: { _ in info }, locator: locator, statePath: nil)
		let answer = try transcripts.transcript("hc:t39", query: [:])
		XCTAssertEqual(answer["harness"] as? String, "omp")
		XCTAssertEqual(answer["session_id"] as? String, Self.ompInteractiveID)
		XCTAssertEqual(answer["title"] as? String, "🐍 CALC: Fix add function in calc.py")
		let entries = try JSONDecoder().decode(
			[SessionEntry].self, from: JSONSerialization.data(withJSONObject: answer["entries"] ?? []))
		XCTAssertEqual(entries.first?.kind, .user)
		XCTAssertTrue(entries.contains { $0.tool?.kind == .edit && $0.tool?.edits?.isEmpty == false })
		XCTAssertTrue(entries.contains { $0.result?.diff?.contains("+    return a + b") == true })
		XCTAssertEqual(transcripts.turnOpen("hc:t39"), false)

		// The listing counts it as a live agent for subagents (none: omp's aren't followed).
		XCTAssertNil(transcripts.annotate(["id": "hc:t39", "agent": "omp"])["subagents_running"])
	}

	// MARK: Codex exec

	func testCodexExecRolloutReadsAsTheSameEntries() throws {
		let page = try SessionLog.read(try fixture("codex-exec"), harness: .codex)
		let entries = page.entries
		XCTAssertEqual(entries.first?.kind, .user)
		XCTAssertTrue(entries.first?.text?.hasPrefix("Read hello.py") == true)
		XCTAssertEqual(entries.last?.kind, .assistant)
		let tools = entries.compactMap(\.tool)
		XCTAssertTrue(tools.contains { $0.kind == .edit && $0.path?.hasSuffix("hello.py") == true && $0.diff?.contains { $0.hasPrefix("+") } == true })
		XCTAssertTrue(tools.contains { $0.kind == .run && $0.argument.contains("hello.greet") })
		let results = entries.compactMap(\.result)
		XCTAssertTrue(results.contains { $0.output.contains("hello, x") })
		XCTAssertEqual(SessionLog.turn(try fixture("codex-exec"), harness: .codex)?.open, false)
	}

	// MARK: hc terminals

	private func terminals() throws -> [String: [String: Any]] {
		let data = try Data(contentsOf: try fixture("hc-terminals", "json"))
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
	}

	func testHcTerminalsNameTheirAgentStateAndSince() throws {
		let all = try terminals()
		let machine: [String: Any] = ["id": "local", "label": "This Mac"]

		let omp = try XCTUnwrap(HerdrCoreAgent.agent(try XCTUnwrap(all["omp-done"]), machine: machine))
		XCTAssertEqual(omp["agent"] as? String, "omp")
		XCTAssertEqual(omp["display_agent"] as? String, "omp")
		XCTAssertEqual(omp["provider"] as? String, "hc")
		XCTAssertEqual(omp["status"] as? String, "done")
		XCTAssertEqual(omp["status_since_ms"] as? Int, all["omp-done"]?["status_ms"] as? Int)
		XCTAssertEqual(omp["name"] as? String, "wl-omp")

		let working = try XCTUnwrap(HerdrCoreAgent.agent(try XCTUnwrap(all["codex-working"]), machine: machine))
		XCTAssertEqual(working["agent"] as? String, "codex")
		XCTAssertEqual(working["status"] as? String, "working")
		XCTAssertNotNil(working["status_since_ms"])
		XCTAssertEqual(HerdrCoreAgent.agent(try XCTUnwrap(all["codex-done"]), machine: machine)?["status"] as? String, "done")

		XCTAssertTrue(HerdrCoreDirectory.startableKinds.contains("omp"))
		XCTAssertTrue(HerdrCoreDirectory.startableKinds.isSuperset(of: ["claude", "codex"]))
	}
}
