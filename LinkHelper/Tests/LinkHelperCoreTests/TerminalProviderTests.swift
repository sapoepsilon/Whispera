import Foundation
import XCTest
@testable import LinkHelperCore

final class TerminalProviderTests: XCTestCase {
    func testOwnerWorkspaceNamesComeFromMetadata() throws {
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let client = HerdrClient(socketPath: rig.localSocket)
        let list = try client.listAgents()["agents"] as! [[String: Any]]
        XCTAssertEqual(list.first?["name"] as? String, "Mobile review w1")
        XCTAssertEqual(try client.getAgent("w1:p1")["agent"].flatMap { $0 as? [String: Any] }?["name"] as? String, "Mobile review w1")
    }
    func testPrivateTmuxDirectoryAndReadOnlyDiff() throws {
        guard let executable = HerdrCLI.resolve("tmux", environment: ProcessInfo.processInfo.environment) else { throw XCTSkip("tmux unavailable") }
        let root = URL(fileURLWithPath: "/tmp/wlt-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("t.sock").path
        defer { _ = try? HerdrCLI.spawn(executable, ["-S", socket, "kill-server"], timeout: 3); try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws { XCTAssertEqual(try HerdrCLI.spawn("/usr/bin/git", ["-C", root.path] + args, timeout: 3).status, 0) }
        try git(["init", "-q"])
        let file = root.appendingPathComponent("example.swift")
        try Data("let timeout = 5\n".utf8).write(to: file); try git(["add", "."])
        try git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "fixture"])
        try Data("let timeout = 30\n".utf8).write(to: file)
        XCTAssertEqual(try HerdrCLI.spawn(executable, ["-S", socket, "new-session", "-d", "-s", "qa", "-n", "Mobile images", "-c", root.path, "/bin/zsh", "-f"], timeout: 3).status, 0)
        let tmux = try XCTUnwrap(TmuxDirectory(configured: executable, socket: socket))
        let row = try XCTUnwrap(tmux.list().first); let id = try XCTUnwrap(row["id"] as? String)
        XCTAssertEqual(row["name"] as? String, "Mobile images")
        let directory = AgentDirectory(local: HerdrClient(socketPath: root.appendingPathComponent("missing.sock").path), cli: HerdrCLI(configured: ""), tmux: tmux)
        XCTAssertEqual((try directory.list()["agents"] as? [[String: Any]])?.count, 1)
        _ = try directory.prompt(id, text: "echo WHISPERA_PRIVATE_TMUX_OK", wait: nil)
        let deadline = Date().addingTimeInterval(3); var text = ""
        repeat { Thread.sleep(forTimeInterval: 0.1); text = try directory.read(id, source: "recent", lines: 100)["text"] as? String ?? "" } while !text.contains("WHISPERA_PRIVATE_TMUX_OK") && Date() < deadline
        XCTAssertTrue(text.contains("WHISPERA_PRIVATE_TMUX_OK"))
        let patch = try directory.diff(id, staged: false)["patch"] as? String ?? ""
        XCTAssertTrue(patch.contains("-let timeout = 5")); XCTAssertTrue(patch.contains("+let timeout = 30"))
        XCTAssertThrowsError(try directory.sendKeys(id, keys: ["run-shell"]))
        XCTAssertThrowsError(try directory.prompt(id, text: "bad\u{1B}[201~payload", wait: nil))
        XCTAssertThrowsError(try directory.get("tmux:p1;kill-server"))
        XCTAssertEqual((try directory.prompt(id, text: "exit", wait: nil)["agent"] as? [String: Any])?["id"] as? String, id)
    }
}
