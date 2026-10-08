import Foundation
import WhisperaTmux
import WhisperaAgents

/// Process execution remains in the trusted Mac host; the package receives arguments only.
final class TmuxDirectory: @unchecked Sendable {
    private let client: TmuxClient
    init?(configured: String, socket: String? = nil) {
        guard let executable = HerdrCLI.resolve(configured, environment: ProcessInfo.processInfo.environment) else { return nil }
        client = TmuxClient { arguments in
            let result = try HerdrCLI.spawn(executable, (socket.map { ["-S", $0] } ?? []) + arguments, timeout: 5)
            guard result.status == 0 else { throw APIError(503, "tmux_unavailable", "tmux session unavailable; check it on your Mac") }
            return String(decoding: result.stdout, as: UTF8.self)
        }
    }
    private func pane(_ id: String) throws -> String {
        guard id.hasPrefix("tmux:p"), id.count > 6, id.dropFirst(6).utf8.allSatisfy({ (48...57).contains($0) }) else { throw APIError(400, "bad_request", "Invalid tmux pane") }
        return "%" + id.dropFirst(6)
    }
    func list() throws -> [[String: Any]] { try client.sessions().map(project) }
    private func project(_ session: TerminalSession) -> [String: Any] {
        ["id": "tmux:p" + session.id.dropFirst(), "provider": "tmux", "name": session.name,
         "agent": session.command ?? "terminal", "display_agent": session.command ?? "terminal", "status": "unknown",
         "cwd": session.cwd ?? "", "workspace_id": "tmux:" + (session.workspaceID ?? ""),
         "workspace_label": session.workspaceName ?? "", "tab_id": session.tabID ?? "", "focused": session.focused,
         "machine": ["id": "local", "label": "This Mac"]]
    }
    func get(_ id: String) throws -> [String: Any] {
        let pane = try pane(id)
        guard let session = try client.sessions().first(where: { $0.id == pane }) else { throw APIError(404, "not_found", "tmux pane no longer exists") }
        return project(session)
    }
    func read(_ id: String, source: String, lines: Int) throws -> [String: Any] {
        ["id": id, "source": source, "text": try client.snapshot(pane(id), lines: lines, visible: source == "visible"), "truncated": false]
    }
    func send(_ text: String, id: String) throws { try client.send(text, to: pane(id)) }
    func keys(_ keys: [String], id: String) throws { try client.sendKeys(keys, to: pane(id)) }
}
