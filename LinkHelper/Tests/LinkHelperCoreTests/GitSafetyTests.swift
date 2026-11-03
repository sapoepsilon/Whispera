import Foundation
import XCTest

@testable import LinkHelperCore

/// git in an agent's workspace never runs a program the repository's own config names.
final class GitSafetyTests: XCTestCase {
	func testArgumentsAndEnvironmentCarryTheHardening() throws {
		let arguments = GitSafety.arguments(["status"])
		XCTAssertEqual(arguments.last, "status")
		for pair in ["core.fsmonitor=", "core.hooksPath=/dev/null", "protocol.file.allow=never", "log.showSignature=false"] {
			let index = arguments.firstIndex(of: pair)
			XCTAssertNotNil(index, pair)
			if let index { XCTAssertEqual(arguments[index - 1], "-c") }
		}
		let environment = GitSafety.environment([
			"GIT_DIR": "/elsewhere", "GIT_WORK_TREE": "/elsewhere", "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='x'",
			"GIT_EXTERNAL_DIFF": "/x", "HOME": "/Users/qa",
		])
		XCTAssertNil(environment["GIT_DIR"])
		XCTAssertNil(environment["GIT_WORK_TREE"])
		XCTAssertNil(environment["GIT_CONFIG_PARAMETERS"])
		XCTAssertNil(environment["GIT_EXTERNAL_DIFF"])
		XCTAssertEqual(environment["HOME"], "/Users/qa")
		XCTAssertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
		XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")

		let command = GitSafety.envCommand(["-C", "/tmp", "rev-parse", "--show-toplevel"])
		XCTAssertEqual(command.path, "/usr/bin/env")
		XCTAssertTrue(command.arguments.contains("GIT_CONFIG_NOSYSTEM=1"))
		let git = try XCTUnwrap(command.arguments.firstIndex(of: "/usr/bin/git"))
		XCTAssertEqual(Array(command.arguments[(git + 1)...]), GitSafety.arguments(["-C", "/tmp", "rev-parse", "--show-toplevel"]))
		XCTAssertEqual(command.arguments[..<git].filter { $0 == "-u" }.count, GitSafety.unsetVariables.count)
	}

	func testEveryWorkspaceScriptStartsHardened() {
		for script in [CodeReader.filesScript, CodeReader.fileScript, RepositoryDiff.listScript, RepositoryDiff.patchScript,
			RepositoryDiff.fileScript]
		{
			XCTAssertTrue(script.hasPrefix(GitSafety.shellPrelude))
			XCTAssertTrue(script.contains("core.fsmonitor="))
		}
	}

	/// A repository whose `.git/config` sets an fsmonitor hook and a clean filter that each
	/// touch a marker file: plain git runs both; the code reader and the diff run neither.
	final class Hostile {
		let base = URL(fileURLWithPath: "/tmp/wlg-" + UUID().uuidString.prefix(8))
		var root: URL { base.appendingPathComponent("repo") }
		var fsmonitorMarker: URL { base.appendingPathComponent("fsmonitor-ran") }
		var filterMarker: URL { base.appendingPathComponent("filter-ran") }

		init(filterName: String = "evil") throws {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try git(["init", "-q"])
			try Data("hello\n".utf8).write(to: root.appendingPathComponent("a.txt"))
			try Data("*.txt filter=\(filterName)\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
			try git(["add", "."])
			try git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "fixture"])
			try Data("hello again\n".utf8).write(to: root.appendingPathComponent("a.txt"))
			let fsmonitor = try script("fsmonitor.sh", "touch '\(fsmonitorMarker.path)'\nexit 1\n")
			let filter = try script("filter.sh", "touch '\(filterMarker.path)'\ncat\n")
			try git(["config", "core.fsmonitor", fsmonitor])
			try git(["config", "filter.\(filterName).clean", filter])
			try git(["config", "filter.\(filterName).required", "true"])
		}

		func script(_ name: String, _ body: String) throws -> String {
			let url = base.appendingPathComponent(name)
			try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
			return url.path
		}

		@discardableResult
		func git(_ arguments: [String]) throws -> HerdrCLI.RunResult {
			try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path] + arguments, timeout: 10)
		}

		var ran: [String] {
			[fsmonitorMarker, filterMarker].filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
		}

		func reset() { for marker in [fsmonitorMarker, filterMarker] { try? FileManager.default.removeItem(at: marker) } }

		deinit { try? FileManager.default.removeItem(at: base) }
	}

	func testHostileRepositoryConfigRunsNothing() throws {
		let repo = try Hostile()
		// The fixture is live: plain git runs both programs.
		try repo.git(["status", "--porcelain"])
		try repo.git(["diff"])
		XCTAssertEqual(Set(repo.ran), ["fsmonitor-ran", "filter-ran"])
		repo.reset()

		let reader = CodeReader.local
		let list = try reader.files(cwd: repo.root.path)
		XCTAssertNotNil(list["files"])
		let file = try reader.file(cwd: repo.root.path, path: "a.txt")
		XCTAssertEqual(file["status"] as? String, "modified")
		let diff = RepositoryDiff(reader)
		let changes = try diff.changes(cwd: repo.root.path, scope: .all)
		XCTAssertTrue((changes["patch"] as? String ?? "").contains("+hello again"), "\(changes)")
		_ = try diff.file(cwd: repo.root.path, scope: .unstaged, path: "a.txt")
		let top = GitSafety.envCommand(["-C", repo.root.path, "status", "--porcelain"])
		XCTAssertEqual(try HerdrCLI.spawn(top.path, top.arguments, timeout: 10).status, 0)
		XCTAssertEqual(repo.ran, [])
	}

	/// A filter name a `-c` pair cannot carry is refused outright, never run.
	func testOddFilterNameFailsClosed() throws {
		let repo = try Hostile(filterName: "x=y")
		repo.reset()
		XCTAssertThrowsError(try CodeReader.local.files(cwd: repo.root.path))
		_ = try? RepositoryDiff(CodeReader.local).changes(cwd: repo.root.path, scope: .all)
		XCTAssertFalse(repo.ran.contains("filter-ran"))
	}
}
