import Foundation
import XCTest

@testable import LinkHelperCore

/// The phone's read-only code reader: what it lists, what it serves and what it refuses.
final class CodeReaderTests: XCTestCase {
	/// A throwaway repository with a sibling directory outside it that symlinks try to reach.
	final class Fixture {
		let base: URL
		let root: URL
		let outside: URL

		init() throws {
			base = URL(fileURLWithPath: "/tmp/wlc-" + UUID().uuidString.prefix(8))
			root = base.appendingPathComponent("repo")
			outside = base.appendingPathComponent("outside")
			try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
			try write("outside/private.txt", "not yours\n", in: base)
			try git(["init", "-q"])
			try write(".gitignore", "build/\n*.log\nconfig.local.json\n")
			try write("Sources/App/main.swift", (1...40).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n")
			try write("tool.py", "def main():\n    return 1\n")
			try write("README.md", "# Fixture\n")
			try write(".env", "TOKEN=fixture-not-a-secret\n")
			try write("certs/server.pem", "fixture\n")
			try write("deploy/id_ed25519", "fixture\n")
			try write("config/secrets.yaml", "fixture: true\n")
			try write("gone.txt", "bye\n")
			try write("config.local.json", "{}\n")
			try git(["add", "."])
			try git(["add", "-f", "config.local.json"])
			try git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "fixture"])
			var lines = (1...40).map { "let line\($0) = \($0)" }
			lines[4] = "let line5 = 500"
			lines.insert("let inserted = true", at: 20)
			lines.remove(at: 35)
			try write("Sources/App/main.swift", lines.joined(separator: "\n") + "\n")
			try write("new.swift", "struct New {}\nlet a = 1\n")
			try write("build/out.txt", "ignored\n")
			try write("debug.log", "ignored\n")
			try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
		}

		func write(_ path: String, _ text: String, in directory: URL? = nil) throws {
			let url = (directory ?? root).appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data(text.utf8).write(to: url)
		}

		func link(_ path: String, to destination: String) throws {
			try FileManager.default.createSymbolicLink(
				atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
		}

		func git(_ arguments: [String]) throws {
			let result = try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path] + arguments, timeout: 10)
			XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
		}

		func remove() { try? FileManager.default.removeItem(at: base) }
	}

	var fixture: Fixture!

	override func setUpWithError() throws { fixture = try Fixture() }
	override func tearDown() { fixture.remove() }

	/// The same scripts through the quoting `ssh` uses, run by a local shell instead of a host.
	static let overSSH = CodeReader { script, arguments, timeout in
		try HerdrCLI.spawn("/bin/sh", ["-c", CodeReader.remoteCommand(script, arguments)], timeout: timeout)
	}

	func readers() -> [(String, CodeReader)] { [("local", .local), ("ssh", Self.overSSH)] }

	func assertRefused(
		_ expression: @autoclosure () throws -> Any, _ status: Int, _ code: String, reason: String? = nil,
		file: StaticString = #filePath, line: UInt = #line
	) {
		XCTAssertThrowsError(try expression(), file: file, line: line) { error in
			guard let error = error as? APIError else { return XCTFail("not an APIError: \(error)", file: file, line: line) }
			XCTAssertEqual(error.status, status, error.message, file: file, line: line)
			XCTAssertEqual(error.code, code, error.message, file: file, line: line)
			if let reason { XCTAssertEqual(error.extra["reason"] as? String, reason, file: file, line: line) }
		}
	}

	// MARK: Listing

	func testTheListIsTheTrackedAndNewFilesWithChangesAndDenialsMarked() throws {
		for (name, reader) in readers() {
			let list = try reader.files(cwd: fixture.root.appendingPathComponent("Sources").path)
			let files = try XCTUnwrap(list["files"] as? [String], name)
			XCTAssertTrue(files.contains("Sources/App/main.swift"), name)
			XCTAssertTrue(files.contains("new.swift"), "untracked, not ignored: \(name)")
			XCTAssertFalse(files.contains("build/out.txt"), "ignored and untracked: \(name)")
			XCTAssertFalse(files.contains("debug.log"), name)
			XCTAssertFalse(files.contains("gone.txt"), "deleted in the worktree: \(name)")
			XCTAssertEqual(files, files.sorted(), name)
			XCTAssertEqual((list["root"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, "repo", name)
			let changed = Dictionary(
				uniqueKeysWithValues: (list["changed"] as? [[String: String]] ?? []).map { ($0["path"]!, $0["status"]!) })
			XCTAssertEqual(changed["Sources/App/main.swift"], "modified", name)
			XCTAssertEqual(changed["new.swift"], "untracked", name)
			XCTAssertEqual(changed["gone.txt"], "deleted", name)
			let denied = Dictionary(
				uniqueKeysWithValues: (list["denied"] as? [[String: Any]] ?? []).map {
					($0["path"] as! String, $0["reason"] as! String)
				})
			XCTAssertEqual(denied[".env"], "secret_name", name)
			XCTAssertEqual(denied["certs/server.pem"], "secret_name", name)
			XCTAssertEqual(denied["deploy/id_ed25519"], "secret_name", name)
			XCTAssertEqual(denied["config/secrets.yaml"], "secret_name", name)
			XCTAssertEqual(denied["config.local.json"], "gitignored", "tracked but matches .gitignore: \(name)")
			XCTAssertNil(denied["tool.py"], name)
			XCTAssertTrue((list["recent"] as? [String] ?? []).contains("tool.py"), name)
			XCTAssertEqual(list["max_file_bytes"] as? Int, 2 * 1024 * 1024, name)
		}
	}

	func testADirectoryOutsideGitIsNoRepository() {
		for (_, reader) in readers() {
			assertRefused(try reader.files(cwd: fixture.outside.path), 409, "no_repository")
			assertRefused(try reader.file(cwd: fixture.outside.path, path: "private.txt"), 409, "no_repository")
		}
	}

	// MARK: Serving

	func testAChangedFileComesWithItsLanguageAndHunks() throws {
		for (name, reader) in readers() {
			let file = try reader.file(cwd: fixture.root.path, path: "Sources/App/main.swift")
			XCTAssertEqual(file["language"] as? String, "swift", name)
			XCTAssertEqual(file["status"] as? String, "modified", name)
			XCTAssertEqual(file["lines"] as? Int, 40, name)
			XCTAssertEqual(file["binary"] as? Bool, false, name)
			XCTAssertTrue((file["content"] as? String ?? "").contains("let line5 = 500"), name)
			let hunks = (file["hunks"] as? [[String: Any]] ?? []).map { "\($0["kind"]!)@\($0["start"]!)+\($0["count"]!)" }
			XCTAssertEqual(hunks, ["change@5+1", "add@21+1", "delete@35+0"], name)
			let python = try reader.file(cwd: fixture.root.path, path: "tool.py")
			XCTAssertEqual(python["language"] as? String, "python", name)
			XCTAssertEqual((python["hunks"] as? [Any])?.count, 0, name)
			XCTAssertTrue(python["status"] is NSNull, name)
			let new = try reader.file(cwd: fixture.root.path, path: "new.swift")
			XCTAssertEqual(new["status"] as? String, "untracked", name)
			XCTAssertEqual((new["hunks"] as? [[String: Any]])?.first?["count"] as? Int, 2, name)
		}
	}

	func testBinaryFilesComeWithoutContent() throws {
		try Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]).write(to: fixture.root.appendingPathComponent("logo.png"))
		for (name, reader) in readers() {
			let file = try reader.file(cwd: fixture.root.path, path: "logo.png")
			XCTAssertEqual(file["binary"] as? Bool, true, name)
			XCTAssertTrue(file["content"] is NSNull, name)
			XCTAssertEqual(file["size"] as? Int, 8, name)
		}
	}

	func testFilesOverTheCapAreRefusedWithTheirSize() throws {
		let big = String(repeating: "x", count: CodeReader.maxFileBytes) + "\n"
		try fixture.write("big.txt", big)
		try fixture.write("fits.txt", String(repeating: "y", count: CodeReader.maxFileBytes - 1) + "\n")
		for (name, reader) in readers() {
			XCTAssertThrowsError(try reader.file(cwd: fixture.root.path, path: "big.txt"), name) { error in
				let error = error as! APIError
				XCTAssertEqual(error.status, 413)
				XCTAssertEqual(error.code, "file_too_large")
				XCTAssertEqual(error.extra["size"] as? Int, CodeReader.maxFileBytes + 1)
			}
			XCTAssertEqual(try reader.file(cwd: fixture.root.path, path: "fits.txt")["size"] as? Int, CodeReader.maxFileBytes, name)
		}
	}

	// MARK: Path safety

	func testPathsThatClimbOrAreAbsoluteAreRefusedBeforeTheFilesystem() {
		let bad = [
			"", "../outside/private.txt", "Sources/../../outside/private.txt", "Sources/./App/main.swift",
			"/etc/hosts", "~/.zshrc", "Sources//App/main.swift", "Sources/App/", "..", "a\u{0}b", "a\nb",
			String(repeating: "a/", count: 600) + "x",
		]
		var calls = 0
		let counting = CodeReader { _, _, _ in
			calls += 1
			return HerdrCLI.RunResult(status: 0, stdout: Data(), stderr: Data())
		}
		for path in bad {
			assertRefused(try counting.file(cwd: fixture.root.path, path: path), 400, "bad_path")
		}
		XCTAssertEqual(calls, 0, "no path reached a shell")
	}

	func testSymlinksThatLeaveTheWorkspaceAreRefused() throws {
		try fixture.link("hosts", to: "/etc/hosts")
		try fixture.link("sneaky.txt", to: "../outside/private.txt")
		try fixture.link("chain.txt", to: "sneaky.txt")
		try fixture.link("outdir", to: fixture.outside.path)
		try fixture.link("loop.txt", to: "loop.txt")
		try fixture.link("readme-link.md", to: "README.md")
		try fixture.link("innocent.txt", to: ".env")
		try fixture.git(["add", "hosts", "sneaky.txt", "chain.txt", "outdir", "loop.txt", "readme-link.md", "innocent.txt"])
		for (name, reader) in readers() {
			let cwd = fixture.root.path
			assertRefused(try reader.file(cwd: cwd, path: "hosts"), 403, "file_denied", reason: "outside_root")
			assertRefused(try reader.file(cwd: cwd, path: "sneaky.txt"), 403, "file_denied", reason: "outside_root")
			assertRefused(try reader.file(cwd: cwd, path: "chain.txt"), 403, "file_denied", reason: "outside_root")
			assertRefused(try reader.file(cwd: cwd, path: "loop.txt"), 403, "file_denied", reason: "outside_root")
			// A symlinked directory is one entry to Git; nothing below it is in the workspace.
			assertRefused(try reader.file(cwd: cwd, path: "outdir/private.txt"), 404, "file_not_found")
			assertRefused(try reader.file(cwd: cwd, path: "innocent.txt"), 403, "file_denied", reason: "secret_name")
			XCTAssertEqual(
				try reader.file(cwd: cwd, path: "readme-link.md")["content"] as? String, "# Fixture\n",
				"a link that stays inside is fine: \(name)")
		}
	}

	func testADirectorySymlinkInTheIndexCannotReachOutside() throws {
		// The index says `vendor/private.txt` is a file while `vendor` is now a link out.
		try fixture.write("vendor/private.txt", "inside\n")
		try fixture.git(["add", "vendor/private.txt"])
		try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("vendor"))
		try fixture.link("vendor", to: fixture.outside.path)
		for (_, reader) in readers() {
			assertRefused(try reader.file(cwd: fixture.root.path, path: "vendor/private.txt"), 403, "file_denied", reason: "outside_root")
		}
	}

	func testSecretFilesAreDeniedAndSaySo() throws {
		try fixture.write(".env.production", "fixture\n")
		try fixture.write("keys/signing.key", "fixture\n")
		try fixture.write(".netrc", "fixture\n")
		try fixture.write("ios/dist.p12", "fixture\n")
		for (name, reader) in readers() {
			for path in [".env", ".env.production", "certs/server.pem", "keys/signing.key", "deploy/id_ed25519", ".netrc",
				"config/secrets.yaml", "ios/dist.p12"]
			{
				XCTAssertThrowsError(try reader.file(cwd: fixture.root.path, path: path), "\(name) \(path)") { error in
					let error = error as! APIError
					XCTAssertEqual(error.status, 403, path)
					XCTAssertEqual(error.code, "file_denied", path)
					XCTAssertEqual(error.extra["reason"] as? String, "secret_name", path)
					XCTAssertTrue(error.message.contains("secret"), path)
				}
			}
			assertRefused(try reader.file(cwd: fixture.root.path, path: "debug.log"), 403, "file_denied", reason: "gitignored")
			assertRefused(try reader.file(cwd: fixture.root.path, path: "build/out.txt"), 403, "file_denied", reason: "gitignored")
			assertRefused(try reader.file(cwd: fixture.root.path, path: "config.local.json"), 403, "file_denied", reason: "gitignored")
		}
	}

	func testUntrackedPathsOutsideGitsViewAreNotFound() throws {
		for (_, reader) in readers() {
			assertRefused(try reader.file(cwd: fixture.root.path, path: "nope.swift"), 404, "file_not_found")
			assertRefused(try reader.file(cwd: fixture.root.path, path: "Sources"), 404, "file_not_found")
			assertRefused(try reader.file(cwd: fixture.root.path, path: ".git/config"), 404, "file_not_found")
			assertRefused(try reader.file(cwd: fixture.root.path, path: "gone.txt"), 404, "file_not_found")
		}
	}

	func testShellMetacharactersInPathsAreJustNames() throws {
		let odd = "it's $(touch pwned) `x` ;a&b.txt"
		try fixture.write(odd, "odd\n")
		for (name, reader) in readers() {
			XCTAssertEqual(try reader.file(cwd: fixture.root.path, path: odd)["content"] as? String, "odd\n", name)
			XCTAssertTrue(try reader.files(cwd: fixture.root.path)["files"].map { ($0 as! [String]).contains(odd) } ?? false, name)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pwned").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: "pwned"))
	}

	func testSecretNameRules() {
		for path in [".env", ".env.local", "a/.ENV", "x.pem", "a/b.key", "id_rsa", "id_rsa.pub", ".netrc", "MySecrets.swift",
			"secrets/x.txt", "home/.ssh/config", ".aws/credentials", "a.p12"]
		{
			XCTAssertEqual(CodeReader.secretReason(path), "secret_name", path)
		}
		for path in ["environment.swift", "keyboard.swift", "Sources/Keys.swift", "pemberton.txt", "README.md", "envoy.yaml"] {
			XCTAssertNil(CodeReader.secretReason(path), path)
		}
		XCTAssertEqual(CodeReader.language("Package.swift"), "swift")
		XCTAssertEqual(CodeReader.language("a/b/Makefile"), "makefile")
		XCTAssertEqual(CodeReader.language("x.tsx"), "tsx")
		XCTAssertNil(CodeReader.language(".gitignore"))
	}

	// MARK: HTTP

	/// End to end: the signed routes resolve the agent's cwd and pass the rules through.
	func testTheSignedRoutesServeTheAgentsWorkspace() async throws {
		let rig = try FakeHerdrRig(localCwd: fixture.root.appendingPathComponent("Sources").path)
		defer { rig.stop() }
		let helper = try TestDaemon(herdrSocket: rig.localSocket)
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let list = try await phone.call("GET", "/v1/agents/w1:p1/files")
		XCTAssertEqual(list.status, 200)
		XCTAssertTrue((list.json["files"] as? [String] ?? []).contains("tool.py"))
		let file = try await phone.call("GET", "/v1/agents/w1:p1/file?path=Sources%2FApp%2Fmain.swift")
		XCTAssertEqual(file.status, 200)
		XCTAssertEqual(file.json["language"] as? String, "swift")
		let secret = try await phone.call("GET", "/v1/agents/w1:p1/file?path=.env")
		XCTAssertEqual(secret.status, 403)
		let envelope = secret.json["error"] as? [String: Any]
		XCTAssertEqual(envelope?["code"] as? String, "file_denied")
		XCTAssertEqual(envelope?["reason"] as? String, "secret_name")
		let status0 = try await phone.call("GET", "/v1/agents/w1:p1/file?path=..%2Foutside%2Fprivate.txt").status
		XCTAssertEqual(status0, 400)
		let status1 = try await phone.call("GET", "/v1/agents/w1:p1/file").status
		XCTAssertEqual(status1, 400)
		let status2 = try await phone.call("POST", "/v1/agents/w1:p1/file?path=tool.py", json: [:]).status
		XCTAssertEqual(status2, 404, "no write route")
		let status3 = try await phone.call("PUT", "/v1/agents/w1:p1/files", json: [:]).status
		XCTAssertEqual(status3, 404)
		let unsigned = try await SoftPhone.send(
			URLRequest(url: helper.baseURL.appendingPathComponent("v1/agents/w1:p1/files")))
		XCTAssertEqual(unsigned.status, 401)
		let capabilities = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((capabilities.json["capabilities"] as? [String] ?? []).contains("code_reader"))
	}
}
