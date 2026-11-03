import Foundation
import XCTest

@testable import LinkHelperCore

/// `GET /v1/agents/{id}/mac-file`: which files an agent mentioned the phone may preview, and
/// which it is refused (outside the allowlist, behind a symlink, secret-named, wrong type).
final class MacFilesTests: XCTestCase {
	static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data(repeating: 0, count: 40)

	/// A home folder, a workspace, a scratch folder and a private folder, all throwaway.
	final class Fixture {
		let base: URL
		var home: URL { base.appendingPathComponent("home") }
		var workspace: URL { base.appendingPathComponent("home/Developer/app") }
		var scratch: URL { base.appendingPathComponent("scratch") }
		var privateDir: URL { base.appendingPathComponent("home/Documents") }

		init() throws {
			base = URL(fileURLWithPath: MacFiles.realPath(NSTemporaryDirectory())!)
				.appendingPathComponent("wlmf-" + UUID().uuidString.prefix(8))
			for dir in [workspace, scratch, privateDir, home.appendingPathComponent(".ssh"), home.appendingPathComponent("Downloads"),
				home.appendingPathComponent("Library/Keychains")]
			{
				try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			}
			try MacFilesTests.png.write(to: workspace.appendingPathComponent("shot.png"))
			try Data("<h1>Report</h1>".utf8).write(to: workspace.appendingPathComponent("report.html"))
			try MacFilesTests.png.write(to: scratch.appendingPathComponent("scratch.png"))
			try MacFilesTests.png.write(to: home.appendingPathComponent("Downloads/dl.png"))
			try Data("Host *\n".utf8).write(to: home.appendingPathComponent(".ssh/config"))
			try Data("TOKEN=fixture\n".utf8).write(to: workspace.appendingPathComponent(".env"))
			try Data("fixture".utf8).write(to: workspace.appendingPathComponent("notes.md"))
			try MacFilesTests.png.write(to: privateDir.appendingPathComponent("passport.png"))
			try Data("not a png".utf8).write(to: workspace.appendingPathComponent("fake.png"))
			try Data("fixture".utf8).write(to: home.appendingPathComponent("Library/Keychains/login.keychain-db"))
		}

		func files() -> MacFiles {
			MacFiles.allowlist(cwd: workspace.path, gitTopLevel: nil, home: home.path, temporary: scratch.path)
		}

		func link(_ name: String, to target: URL, in dir: URL? = nil) throws -> String {
			let url = (dir ?? workspace).appendingPathComponent(name)
			try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
			return url.path
		}

		deinit { try? FileManager.default.removeItem(at: base) }
	}

	private func assertRefused(_ expression: @autoclosure () throws -> Any, _ status: Int, _ code: String, reason: String? = nil,
		file: StaticString = #filePath, line: UInt = #line)
	{
		XCTAssertThrowsError(try expression(), file: file, line: line) { error in
			guard let api = error as? APIError else { return XCTFail("not an APIError: \(error)", file: file, line: line) }
			XCTAssertEqual(api.status, status, file: file, line: line)
			XCTAssertEqual(api.code, code, file: file, line: line)
			if let reason { XCTAssertEqual(api.extra["reason"] as? String, reason, file: file, line: line) }
		}
	}

	func testTheSharedTmpFolderIsNotARoot() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		XCTAssertFalse(files.roots.contains("/private/tmp"), "world-writable: any local user could plant a file")
		XCTAssertTrue(files.roots.contains(MacFiles.realPath(fixture.scratch.path)!), "the per-user temporary folder stays")
		let planted = URL(fileURLWithPath: "/private/tmp/wlmf-planted-\(UUID().uuidString.prefix(8)).png")
		try MacFilesTests.png.write(to: planted)
		defer { try? FileManager.default.removeItem(at: planted) }
		assertRefused(try files.read(planted.path), 403, "file_denied", reason: "outside_allowed")
	}

	func testTheOpenedPathIsWhatGetsChecked() throws {
		let fixture = try Fixture()
		let path = fixture.workspace.appendingPathComponent("shot.png").path
		let fd = open(path, O_RDONLY)
		XCTAssertGreaterThanOrEqual(fd, 0)
		defer { close(fd) }
		XCTAssertEqual(MacFiles.openedPath(fd), MacFiles.realPath(path))
		// A link swapped in for the file's directory resolves elsewhere; the check sees the target.
		let elsewhere = fixture.privateDir.appendingPathComponent("passport.png").path
		let other = open(elsewhere, O_RDONLY)
		defer { close(other) }
		XCTAssertFalse(fixture.files().isAllowed(MacFiles.openedPath(other)!))
	}

	func testFilesUnderTheWorkspaceScratchAndDownloadsAreServed() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		let shot = try files.read(fixture.workspace.appendingPathComponent("shot.png").path)
		XCTAssertEqual(shot.kind, .image)
		XCTAssertEqual(shot.contentType, "image/png")
		XCTAssertEqual(shot.data, Self.png)
		let html = try files.read(fixture.workspace.appendingPathComponent("report.html").path)
		XCTAssertEqual(html.kind, .html)
		XCTAssertEqual(String(decoding: html.data, as: UTF8.self), "<h1>Report</h1>")
		XCTAssertEqual(try files.read(fixture.scratch.appendingPathComponent("scratch.png").path).kind, .image)
		XCTAssertEqual(try files.read(fixture.home.appendingPathComponent("Downloads/dl.png").path).kind, .image)
	}

	func testFilesOutsideTheAllowlistAreRefused() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		assertRefused(try files.read(fixture.privateDir.appendingPathComponent("passport.png").path), 403, "file_denied", reason: "outside_allowed")
		assertRefused(try files.read("/etc/hosts.txt"), 404, "file_not_found")
	}

	func testSecretNamesAreRefusedBeforeTheFilesystem() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		assertRefused(try files.read(fixture.home.appendingPathComponent(".ssh/config").path), 403, "file_denied", reason: "secret_name")
		assertRefused(try files.read(fixture.workspace.appendingPathComponent(".env").path), 403, "file_denied", reason: "secret_name")
		assertRefused(try files.read("/private/tmp/secrets/plan.png"), 403, "file_denied", reason: "secret_name")
		assertRefused(try files.read(fixture.home.appendingPathComponent("Library/Keychains/login.keychain-db").path), 403, "file_denied")
		XCTAssertEqual(MacFiles.secretReason("/Users/me/Library/Keychains/x.png"), "secret_name")
		XCTAssertEqual(MacFiles.secretReason("/Users/me/.aws/shot.png"), "secret_name")
		XCTAssertNil(MacFiles.secretReason("/private/tmp/claude-501/scratchpad/shot.png"))
	}

	func testSymlinksAreResolvedBeforeTheChecks() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		// An innocent name inside the workspace that leads outside it.
		let escape = try fixture.link("escape.png", to: fixture.privateDir.appendingPathComponent("passport.png"))
		assertRefused(try files.read(escape), 403, "file_denied", reason: "outside_allowed")
		// …or to a secret, under any name.
		let ssh = try fixture.link("config.txt", to: fixture.home.appendingPathComponent(".ssh/config"))
		assertRefused(try files.read(ssh), 403, "file_denied", reason: "secret_name")
		let env = try fixture.link("env.txt", to: fixture.workspace.appendingPathComponent(".env"))
		assertRefused(try files.read(env), 403, "file_denied", reason: "secret_name")
		// …or to a type that isn't served.
		let notes = try fixture.link("notes.png", to: fixture.workspace.appendingPathComponent("notes.md"))
		assertRefused(try files.read(notes), 415, "file_denied", reason: "unsupported_type")
		// A directory symlinked into the scratch folder doesn't widen it.
		let dir = try fixture.link("docs", to: fixture.privateDir, in: fixture.scratch)
		assertRefused(try files.read(dir + "/passport.png"), 403, "file_denied", reason: "outside_allowed")
		// A link that stays inside is fine.
		let inside = try fixture.link("latest.png", to: fixture.workspace.appendingPathComponent("shot.png"), in: fixture.scratch)
		XCTAssertEqual(try files.read(inside).data, Self.png)
	}

	func testOnlyPreviewableTypesWithMatchingBytesAreServed() throws {
		let fixture = try Fixture()
		let files = fixture.files()
		assertRefused(try files.read(fixture.workspace.appendingPathComponent("notes.md").path), 415, "file_denied", reason: "unsupported_type")
		assertRefused(try files.read(fixture.workspace.appendingPathComponent("fake.png").path), 415, "file_denied", reason: "unsupported_type")
	}

	func testSizeCapsAndPathRules() throws {
		let fixture = try Fixture()
		let big = fixture.workspace.appendingPathComponent("big.txt")
		try Data(repeating: 0x61, count: MacFiles.maxBytes(.text) + 1).write(to: big)
		assertRefused(try fixture.files().read(big.path), 413, "file_too_large")
		assertRefused(try fixture.files().read("relative/shot.png"), 400, "bad_path")
		assertRefused(try fixture.files().read(fixture.workspace.path + "/../app/shot.png"), 400, "bad_path")
		assertRefused(try fixture.files().read("/tmp/a\nb.png"), 400, "bad_path")
		assertRefused(try fixture.files().read(""), 400, "bad_path")
	}

	func testAWorkspaceAtTheHomeFolderOrRootAddsNoRoot() throws {
		let fixture = try Fixture()
		let atHome = MacFiles.allowlist(cwd: fixture.home.path, gitTopLevel: "/", home: fixture.home.path, temporary: fixture.scratch.path)
		XCTAssertFalse(atHome.roots.contains(fixture.home.path))
		XCTAssertFalse(atHome.roots.contains("/"))
		assertRefused(try atHome.read(fixture.privateDir.appendingPathComponent("passport.png").path), 403, "file_denied", reason: "outside_allowed")
		XCTAssertFalse(MacFiles.isNarrow("/Users", home: "/Users/me"))
		XCTAssertFalse(MacFiles.isNarrow("/Users/me/Library/Mail", home: "/Users/me"))
		XCTAssertTrue(MacFiles.isNarrow("/Users/me/Developer/app", home: "/Users/me"))
	}

	func testTheRouteIsSignedAndAdvertised() throws {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1%3Ap1/mac-file")?.name, "agents.mac_file")
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1%3Ap1/mac-file")?.auth, .signed)
		XCTAssertNil(LinkAPI.match("POST", "/v1/agents/w1%3Ap1/mac-file"))
	}
}

/// The route end to end against a helper with the fake herdr.
final class MacFilesRouteTests: XCTestCase {
	var rig: FakeHerdrRig!
	var helper: TestDaemon!
	var phone: SoftPhone!
	var dir: URL!

	override func setUp() async throws {
		rig = try FakeHerdrRig()
		let rig = self.rig!
		helper = try TestDaemon(engine: FakeEngine()) { config in
			config.herdrSocket = rig.localSocket
			config.herdrCLI = rig.cli
		}
		phone = try await helper.pairedPhone()
		dir = URL(fileURLWithPath: MacFiles.realPath(NSTemporaryDirectory())!)
			.appendingPathComponent("wlmf-route-" + UUID().uuidString.prefix(8))
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	}

	override func tearDown() {
		helper.stop()
		rig.stop()
		try? FileManager.default.removeItem(at: dir)
	}

	private func get(_ agent: String, _ path: String) async throws -> SoftPhone.Response {
		var components = URLComponents()
		components.queryItems = [URLQueryItem(name: "path", value: path)]
		let query = components.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
		return try await phone.call("GET", "/v1/agents/\(agent)/mac-file?\(query)")
	}

	func testAScratchImageAndPageComeBackAsBytesAndSecretsDoNot() async throws {
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("mac_files"))

		try MacFilesTests.png.write(to: dir.appendingPathComponent("shot.png"))
		try Data("<p>hi</p>".utf8).write(to: dir.appendingPathComponent("page.html"))
		let image = try await get("w1%3Ap1", dir.appendingPathComponent("shot.png").path)
		XCTAssertEqual(image.status, 200)
		XCTAssertEqual(image.body, MacFilesTests.png)
		XCTAssertEqual(image.headers["Content-Type"] as? String, "image/png")
		let page = try await get("w1%3Ap1", dir.appendingPathComponent("page.html").path)
		XCTAssertEqual(page.status, 200)
		XCTAssertEqual(String(decoding: page.body, as: UTF8.self), "<p>hi</p>")
		XCTAssertNotNil(page.headers["Content-Security-Policy"])

		try Data("TOKEN=x".utf8).write(to: dir.appendingPathComponent(".env"))
		let env = try await get("w1%3Ap1", dir.appendingPathComponent(".env").path)
		XCTAssertEqual(env.status, 403)
		XCTAssertEqual(env.errorCode, "file_denied")
		let ssh = try await get("w1%3Ap1", "~/.ssh/config")
		XCTAssertEqual(ssh.status, 403)
		let remote = try await get("m_fake-main.w9%3Ap2", dir.appendingPathComponent("shot.png").path)
		XCTAssertEqual(remote.status, 409)
		XCTAssertEqual(remote.errorCode, "remote_machine")
	}
}
