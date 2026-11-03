import Foundation
import XCTest

@testable import LinkHelperCore

/// The Changes screen's patch: every changed file, tracked or not, from any subdirectory.
final class RepositoryDiffTests: XCTestCase {
	final class Fixture {
		let root: URL

		init() throws {
			root = URL(fileURLWithPath: "/tmp/wld-" + UUID().uuidString.prefix(8))
			try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
			try git(["init", "-q"])
			try write(".gitignore", "build/\n")
			try write("Sources/App/main.swift", "let a = 1\nlet b = 2\n")
			try write("Sources/App/other.swift", "let x = 1\n")
			try write("old name.txt", "keep\nme\nhere\nplease\n")
			try write("gone.txt", "bye\n")
			try write("run.sh", "echo hi\n")
			try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
			try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("assets/logo.bin"))
			try git(["add", "."])
			try git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "fixture"])
			// Unstaged edits, a staged edit, a rename, a deletion, a mode change and a binary.
			try write("Sources/App/main.swift", "let a = 1\nlet b = 3\n")
			try write("Sources/App/other.swift", "let x = 2\n")
			try git(["add", "Sources/App/other.swift"])
			try git(["mv", "old name.txt", "new name.txt"])
			try git(["rm", "-q", "gone.txt"])
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)
			try Data([0, 9, 2, 3]).write(to: root.appendingPathComponent("assets/logo.bin"))
			try write("staged-new.swift", "struct Staged {}\n")
			try git(["add", "staged-new.swift"])
			// Untracked: text, empty, nested, a secret name, too large, and an ignored file.
			try write("notes.md", "brand\nnew\n")
			try write("empty.txt", "")
			try write("Sources/App/Untracked.swift", "struct U {}\n")
			try write(".env", "TOKEN=fixture-not-a-secret\n")
			try write("big.log", String(repeating: "0123456789abcdef\n", count: 40_000))
			try write("build/out.txt", "ignored\n")
		}

		func write(_ path: String, _ text: String) throws {
			let url = root.appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data(text.utf8).write(to: url)
		}

		func git(_ arguments: [String]) throws {
			let result = try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path] + arguments, timeout: 10)
			XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
		}

		func remove() { try? FileManager.default.removeItem(at: root) }
	}

	private var fixture: Fixture!

	override func setUpWithError() throws { fixture = try Fixture() }
	override func tearDown() { fixture?.remove() }

	private func changes(_ scope: RepositoryDiff.Scope, cwd: String? = nil) throws -> [String: Any] {
		try RepositoryDiff(CodeReader.local).changes(cwd: cwd ?? fixture.root.path, scope: scope)
	}

	/// The `diff --git` headers' new-side paths, in order.
	private func files(_ patch: String) -> [String] {
		patch.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.map { line in
			let header = String(line.dropFirst("diff --git ".count))
			return String(header[header.range(of: " b/")!.upperBound...])
		}
	}

	func testAllChangesListEveryFileFromASubdirectory() throws {
		let answer = try changes(.all, cwd: fixture.root.appendingPathComponent("Sources/App").path)
		let patch = try XCTUnwrap(answer["patch"] as? String)
		let names = files(patch)
		for name in [
			"Sources/App/main.swift", "Sources/App/other.swift", "new name.txt", "gone.txt", "run.sh", "assets/logo.bin",
			"staged-new.swift", "notes.md", "empty.txt", "Sources/App/Untracked.swift", ".env", "big.log",
		] {
			XCTAssertTrue(names.contains(name), "\(name) missing from \(names)")
		}
		XCTAssertFalse(names.contains("build/out.txt"), "ignored files stay out")
		XCTAssertEqual(answer["files"] as? Int, names.count)
		XCTAssertEqual(answer["untracked"] as? Int, 5)
		XCTAssertEqual(answer["scope"] as? String, "all")
		XCTAssertEqual(answer["staged"] as? Bool, false)
		XCTAssertTrue(patch.contains("+let b = 3"))
		XCTAssertTrue(patch.contains("+let x = 2"), "staged edits are part of all changes")
		XCTAssertTrue(patch.contains("rename from old name.txt"))
		XCTAssertTrue(patch.contains("Binary files a/assets/logo.bin and b/assets/logo.bin differ"))
		XCTAssertTrue(patch.contains("new mode 100755"))
		XCTAssertTrue(patch.contains("+brand\n+new\n"))
		XCTAssertTrue(patch.contains("diff --git a/empty.txt b/empty.txt\nnew file mode 100644\n"))
		XCTAssertFalse(patch.contains("TOKEN="), "a secret-named untracked file is listed, not read")
		XCTAssertTrue(patch.contains("diff --git a/.env b/.env\nnew file mode 100644\nwhispera-omitted: secret\n"))
		XCTAssertTrue(patch.contains("diff --git a/big.log b/big.log\nnew file mode 100644\nwhispera-omitted: too_large 680000\n"))
		XCTAssertEqual(answer["truncated"] as? Bool, true)
	}

	func testStagedAndUnstagedScopes() throws {
		let staged = try XCTUnwrap(try changes(.staged)["patch"] as? String)
		XCTAssertEqual(Set(files(staged)), ["Sources/App/other.swift", "new name.txt", "gone.txt", "staged-new.swift"])
		let unstaged = try XCTUnwrap(try changes(.unstaged)["patch"] as? String)
		XCTAssertEqual(
			Set(files(unstaged)),
			["Sources/App/main.swift", "run.sh", "assets/logo.bin", "notes.md", "empty.txt", "Sources/App/Untracked.swift", ".env", "big.log"])
	}

	func testARepositoryWithoutCommitsShowsItsFiles() throws {
		let root = URL(fileURLWithPath: "/tmp/wld-" + UUID().uuidString.prefix(8))
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		XCTAssertEqual(try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path, "init", "-q"], timeout: 5).status, 0)
		try Data("added\n".utf8).write(to: root.appendingPathComponent("a.txt"))
		try Data("loose\n".utf8).write(to: root.appendingPathComponent("b.txt"))
		XCTAssertEqual(try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path, "add", "a.txt"], timeout: 5).status, 0)
		let patch = try XCTUnwrap(try changes(.all, cwd: root.path)["patch"] as? String)
		XCTAssertEqual(files(patch), ["a.txt", "b.txt"])
	}

	func testOutsideARepositoryIsNoRepository() throws {
		let directory = URL(fileURLWithPath: "/tmp/wld-" + UUID().uuidString.prefix(8))
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		XCTAssertThrowsError(try changes(.all, cwd: directory.path)) { error in
			XCTAssertEqual((error as? APIError)?.code, "no_repository")
		}
	}

	/// Past the byte budget every file still has its header; a file over the cap is omitted.
	func testABudgetCutKeepsEveryFileHeader() {
		let small = "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"
		let huge = "diff --git a/huge.txt b/huge.txt\nindex 1..2 100644\n--- a/huge.txt\n+++ b/huge.txt\n@@ -1 +1,40000 @@\n"
			+ String(repeating: "+0123456789abcdef\n", count: 40_000)
		var body = small + huge
		var repeats = 0
		while body.utf8.count <= RepositoryDiff.maxPatchBytes { body += small; repeats += 1 }
		// The last small block straddles the cut; the two after it are past it.
		let names = ["a.txt", "huge.txt"] + Array(repeating: "a.txt", count: repeats + 1) + ["late one.txt", "q\"uote.txt"]
		let (text, count) = RepositoryDiff.trackedPatch(Data((body + small).utf8), names: names)
		XCTAssertEqual(count, names.count)
		XCTAssertTrue(text.hasPrefix(small))
		XCTAssertTrue(text.contains("diff --git a/huge.txt b/huge.txt\nindex 1..2 100644\nwhispera-omitted: too_large"))
		XCTAssertTrue(text.hasSuffix("diff --git a/late one.txt b/late one.txt\nwhispera-omitted: limit\ndiff --git \"a/q\\\"uote.txt\" \"b/q\\\"uote.txt\"\nwhispera-omitted: limit\n"))
		XCTAssertLessThan(text.utf8.count, RepositoryDiff.maxPatchBytes)
	}

	func testSplitFilesKeepsEachBlockWhole() {
		let patch = "diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+diff --git a/fake b/fake\ndiff --git a/b b/b\nBinary files a/b and b/b differ\n"
		XCTAssertEqual(RepositoryDiff.splitFiles(patch), [
			"diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+diff --git a/fake b/fake\n", "diff --git a/b b/b\nBinary files a/b and b/b differ\n",
		])
		XCTAssertEqual(RepositoryDiff.splitFiles(""), [])
	}

	// MARK: Big and messy work trees

	/// A synthetic repository: one tracked edit, 50 000 untracked files in one folder, 400
	/// loose untracked files and a note. The old route read up to 300 untracked files one
	/// process each (31 s on a real tree) and timed out; this one answers well inside its budget.
	func testFiftyThousandUntrackedFilesAnswerInsideTheBudget() throws {
		let root = fixture.root
		let manager = FileManager.default
		for folder in 0..<50 {
			let directory = root.appendingPathComponent("junk/d\(folder)")
			try manager.createDirectory(at: directory, withIntermediateDirectories: true)
			for file in 0..<1000 {
				manager.createFile(atPath: directory.appendingPathComponent("f\(file).txt").path, contents: Data("line \(file)\n".utf8))
			}
		}
		// The loose files sit in a tracked folder that sorts after `notes.md`.
		try fixture.write("tools/keep.txt", "keep\n")
		try fixture.git(["add", "tools/keep.txt"])
		try fixture.git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "tools", "--", "tools/keep.txt"])
		for file in 0..<400 {
			manager.createFile(atPath: root.appendingPathComponent("tools/gen\(file).swift").path, contents: Data("let g\(file) = \(file)\n".utf8))
		}
		let started = Date()
		let answer = try changes(.all)
		let elapsed = Date().timeIntervalSince(started)
		XCTAssertLessThan(elapsed, 5, "the diff took \(elapsed) s")
		let patch = try XCTUnwrap(answer["patch"] as? String)
		let names = files(patch)
		XCTAssertTrue(patch.contains("+let b = 3"), "tracked edits still show")
		XCTAssertTrue(patch.contains("+brand\n+new\n"), "a small untracked file is read")
		XCTAssertTrue(patch.contains("diff --git a/junk b/junk\nnew file mode 100644\nwhispera-omitted: folder 50000\n"),
			"a folder of 50 000 untracked files is one entry")
		XCTAssertFalse(names.contains { $0.hasPrefix("junk/") })
		XCTAssertEqual(answer["untracked_total"] as? Int, 50_405)
		XCTAssertEqual(answer["untracked"] as? Int, 406)
		XCTAssertEqual(answer["partial"] as? Bool, false)
		XCTAssertEqual(answer["truncated"] as? Bool, true)
		// 300 untracked files are read; the rest are listed for the phone to fetch one by one.
		let limited = patch.components(separatedBy: "new file mode 100644\nwhispera-omitted: limit\n").count - 1
		XCTAssertEqual(limited, 406 - 2 - RepositoryDiff.maxUntrackedDiffs, "406 untracked: a folder, a secret and 300 read")
		XCTAssertEqual(answer["files"] as? Int, names.count)
		let later = try XCTUnwrap(names.last { $0.hasPrefix("tools/gen") })
		let one = try RepositoryDiff(CodeReader.local).file(cwd: root.path, scope: .all, path: later)
		XCTAssertTrue((one["patch"] as? String ?? "").contains("+let g"), "a listed file's patch comes on its own")
	}

	/// When the patch does not finish in time, every file still comes back by name.
	func testAPatchPastTheBudgetStillListsEveryFile() throws {
		let slow = RepositoryDiff { script, arguments, timeout in
			if script == RepositoryDiff.patchScript { throw APIError(504, "herdr_timeout", "herdr did not answer in \(Int(timeout)) s") }
			return try CodeReader.local.run(script, arguments, timeout)
		}
		let answer = try slow.changes(cwd: fixture.root.path, scope: .all, refresh: true)
		let patch = try XCTUnwrap(answer["patch"] as? String)
		XCTAssertEqual(answer["partial"] as? Bool, true)
		XCTAssertEqual(answer["partial_reason"] as? String, "time")
		XCTAssertEqual(answer["truncated"] as? Bool, true)
		XCTAssertEqual(Set(files(patch)), [
			"Sources/App/main.swift", "Sources/App/other.swift", "new name.txt", "gone.txt", "run.sh", "assets/logo.bin",
			"staged-new.swift", "notes.md", "empty.txt", "Sources/App/Untracked.swift", ".env", "big.log",
		])
		XCTAssertTrue(patch.contains("diff --git a/notes.md b/notes.md\nnew file mode 100644\nwhispera-omitted: limit\n"))
		XCTAssertTrue(patch.contains("diff --git a/.env b/.env\nnew file mode 100644\nwhispera-omitted: secret\n"))
		XCTAssertFalse(patch.contains("TOKEN="))
	}

	func testOneFileOnItsOwn() throws {
		let diff = RepositoryDiff(CodeReader.local)
		let cwd = fixture.root.appendingPathComponent("Sources").path
		XCTAssertTrue((try diff.file(cwd: cwd, scope: .all, path: "Sources/App/main.swift")["patch"] as? String ?? "").contains("+let b = 3"))
		let note = try diff.file(cwd: cwd, scope: .all, path: "notes.md")
		XCTAssertTrue((note["patch"] as? String ?? "").hasPrefix("diff --git a/notes.md b/notes.md\nnew file mode 100644\n"))
		XCTAssertEqual(note["untracked"] as? Bool, true)
		XCTAssertEqual(try diff.file(cwd: cwd, scope: .staged, path: "notes.md")["patch"] as? String, "")
		let secret = try diff.file(cwd: cwd, scope: .all, path: ".env")["patch"] as? String ?? ""
		XCTAssertEqual(secret, "diff --git a/.env b/.env\nnew file mode 100644\nwhispera-omitted: secret\n")
		XCTAssertEqual(try diff.file(cwd: cwd, scope: .all, path: "big.log")["patch"] as? String,
			"diff --git a/big.log b/big.log\nnew file mode 100644\nwhispera-omitted: too_large 680000\n")
		XCTAssertThrowsError(try diff.file(cwd: cwd, scope: .all, path: "../etc/passwd")) { error in
			XCTAssertEqual((error as? APIError)?.code, "bad_path")
		}
	}

	/// The real index is never written: untracked files are shown through a throwaway copy.
	func testTheIndexIsLeftAlone() throws {
		let index = fixture.root.appendingPathComponent(".git/index")
		let before = try Data(contentsOf: index)
		_ = try changes(.all)
		_ = try changes(.unstaged)
		XCTAssertEqual(try Data(contentsOf: index), before)
		let status = try HerdrCLI.spawn("/usr/bin/git", ["-C", fixture.root.path, "status", "--porcelain"], timeout: 5)
		XCTAssertTrue(String(decoding: status.stdout, as: UTF8.self).contains("?? notes.md"))
	}

	func testAnUnreadableUntrackedFileDoesNotHideTheOthers() throws {
		try fixture.write("locked.txt", "private\n")
		let locked = fixture.root.appendingPathComponent("locked.txt").path
		try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
		let patch = try XCTUnwrap(try changes(.all)["patch"] as? String)
		XCTAssertTrue(patch.contains("diff --git a/locked.txt b/locked.txt\nnew file mode 100644\nwhispera-omitted: unreadable\n"))
		XCTAssertTrue(patch.contains("+brand\n+new\n"))
		XCTAssertTrue(patch.contains("+struct U {}"))
	}

	func testAnswersAreCachedUntilTheTreeOrRefreshChanges() throws {
		let first = try changes(.all)
		XCTAssertEqual(first["cached"] as? Bool, false)
		XCTAssertEqual(try changes(.all)["cached"] as? Bool, true)
		let fresh = try RepositoryDiff(CodeReader.local).changes(cwd: fixture.root.path, scope: .all, refresh: true)
		XCTAssertEqual(fresh["cached"] as? Bool, false)
		try fixture.write("another.txt", "x\n")
		let changed = try changes(.all)
		XCTAssertEqual(changed["cached"] as? Bool, false, "a new untracked file changes the key")
		XCTAssertTrue(files(changed["patch"] as? String ?? "").contains("another.txt"))
	}

	func testUntrackedFoldersFold() {
		let many = (0..<201).map { "gen/f\($0)" }
		let entries = RepositoryDiff.untrackedEntries(
			folders: ["a.txt", "few/", "gen/", "nested/"], files: ["a.txt", "few/x", "few/y"] + many + ["nested/"], complete: true)
		XCTAssertEqual(entries, [
			.init(path: "a.txt", kind: .file), .init(path: "few/x", kind: .file), .init(path: "few/y", kind: .file),
			.init(path: "gen", kind: .folder(201)), .init(path: "nested", kind: .repository),
		])
		let cut = RepositoryDiff.untrackedEntries(folders: ["a/", "z/"], files: ["a/1"], complete: false)
		XCTAssertEqual(cut, [.init(path: "a/1", kind: .file), .init(path: "z", kind: .folder(nil))])
	}

	// MARK: HTTP

	func testTheDiffRouteServesEveryChangedFile() async throws {
		let rig = try FakeHerdrRig(localCwd: fixture.root.appendingPathComponent("Sources").path)
		defer { rig.stop() }
		let helper = try TestDaemon(herdrSocket: rig.localSocket)
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let working = try await phone.call("GET", "/v1/agents/w1:p1/diff?staged=0")
		XCTAssertEqual(working.status, 200)
		let patch = working.json["patch"] as? String ?? ""
		XCTAssertEqual(files(patch).count, 12, files(patch).joined(separator: ", "))
		XCTAssertEqual(working.json["staged"] as? Bool, false)
		let staged = try await phone.call("GET", "/v1/agents/w1:p1/diff?staged=1")
		XCTAssertEqual(files(staged.json["patch"] as? String ?? "").count, 4)
		XCTAssertEqual(staged.json["staged"] as? Bool, true)
		let unstaged = try await phone.call("GET", "/v1/agents/w1:p1/diff?scope=unstaged")
		XCTAssertEqual(files(unstaged.json["patch"] as? String ?? "").count, 8)
		let bad = try await phone.call("GET", "/v1/agents/w1:p1/diff?scope=everything").status
		XCTAssertEqual(bad, 400)
		let one = try await phone.call("GET", "/v1/agents/w1:p1/diff?path=notes.md")
		XCTAssertEqual(one.status, 200)
		XCTAssertTrue((one.json["patch"] as? String ?? "").contains("+brand"))
		let escaping = try await phone.call("GET", "/v1/agents/w1:p1/diff?path=..%2Fx").status
		XCTAssertEqual(escaping, 400)
		let refreshed = try await phone.call("GET", "/v1/agents/w1:p1/diff?refresh=1")
		XCTAssertEqual(refreshed.json["cached"] as? Bool, false)
		XCTAssertEqual(refreshed.json["partial"] as? Bool, false)
	}
}
