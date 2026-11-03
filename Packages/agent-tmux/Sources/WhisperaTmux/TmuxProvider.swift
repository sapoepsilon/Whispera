// SPDX-License-Identifier: MIT
import Foundation
import WhisperaAgents

public struct TmuxTUIProvider: AgentTUIProvider {
    public let id = "tmux"
    public let displayName = "tmux"
    public init() {}
    public func transcript(from snapshot: String) -> AgentTranscript { AgentTranscript(parsing: snapshot) }
    public func keys(for action: AgentTerminalAction) -> [String] { PlainTerminalProvider().keys(for: action) }
}

/// Host-injected, argument-only execution keeps subprocesses and SSH outside the package.
/// Configure a private socket in the host's runner to use isolated servers.
public struct TmuxClient: AgentSessionTransport {
    public let providerID = "tmux"
    public typealias Runner = @Sendable ([String]) throws -> String
    private let run: Runner
    public init(run: @escaping Runner) { self.run = run }
    public enum Failure: Error { case invalidPane, invalidKeys, textTooLong }
    public static let separator = "\u{1F}"
    public static let listFormat = ["pane_id", "session_id", "session_name", "window_id", "window_name",
                                   "pane_title", "pane_current_path", "pane_current_command", "pane_active", "pane_dead"]
        .map { "#{\($0)}" }.joined(separator: separator)
    public func sessions() throws -> [TerminalSession] {
        Self.parseSessions(try run(["list-panes", "-a", "-F", Self.listFormat]))
    }
    public static func parseSessions(_ text: String) -> [TerminalSession] {
        text.split(separator: "\n").compactMap { line in
            let f = String(line).components(separatedBy: separator)
            guard f.count == 10, validPane(f[0]), f[9] == "0" else { return nil }
            // Window names are explicitly user-controlled; pane titles are also set by TUIs.
            let name = f[4].isEmpty ? (f[5].isEmpty ? f[2] : f[5]) : f[4]
            return TerminalSession(id: f[0], name: name, command: f[7], cwd: f[6],
                                   workspaceID: f[1], workspaceName: f[2], tabID: f[3], focused: f[8] == "1")
        }
    }
    public func snapshot(_ paneID: String, lines: Int, visible: Bool) throws -> String {
        try validate(paneID)
        var args = ["capture-pane", "-p", "-J", "-t", paneID]
        if !visible { args += ["-S", "-\(max(1, min(lines, 2000)))"] }
        return try run(args)
    }
    public func send(_ text: String, to paneID: String) throws {
        try validate(paneID)
        guard !text.isEmpty, text.unicodeScalars.count <= 12000, !text.contains("\u{0}"), !text.contains("\u{1B}") else { throw Failure.textTooLong }
        // Bracketed paste prevents multiline prompts becoming separate shell commands.
        // Text remains a single literal argument; nothing is evaluated by a shell.
        _ = try run(["send-keys", "-t", paneID, "-l", "--", "\u{1B}[200~" + text + "\u{1B}[201~"])
        _ = try run(["send-keys", "-t", paneID, "Enter"])
    }
    public func sendKeys(_ keys: [String], to paneID: String) throws {
        try validate(paneID)
        let names = ["up":"Up", "down":"Down", "left":"Left", "right":"Right", "shift+left":"S-Left",
                     "shift+right":"S-Right", "enter":"Enter", "esc":"Escape", "ctrl+c":"C-c", "tab":"Tab", "shift+tab":"BTab",
                     "space":"Space", "backspace":"BSpace", "ctrl+u":"C-u"]
        guard !keys.isEmpty, keys.count <= 16 else { throw Failure.invalidKeys }
        let mapped = try keys.map { key -> String in
            guard let value = names[key.lowercased()] else { throw Failure.invalidKeys }; return value
        }
        _ = try run(["send-keys", "-t", paneID] + mapped)
    }
    /// The visible screen with its colours (`capture-pane -e`): asks read the active tab from them.
    public func snapshotANSI(_ paneID: String) throws -> String {
        try validate(paneID)
        return try run(["capture-pane", "-p", "-e", "-J", "-t", paneID])
    }
    /// Literal text without Enter or bracketed paste, for an ask's free-text field. One line,
    /// no control characters: it can only type, never run a key binding.
    public func type(_ text: String, to paneID: String) throws {
        try validate(paneID)
        guard !text.isEmpty, text.count <= 500, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { throw Failure.textTooLong }
        _ = try run(["send-keys", "-t", paneID, "-l", "--", text])
    }
    private func validate(_ pane: String) throws { guard Self.validPane(pane) else { throw Failure.invalidPane } }
    private static func validPane(_ pane: String) -> Bool {
        pane.first == "%" && pane.count > 1 && pane.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// The ask layer's view of one tmux pane. tmux has no notion of an agent waiting on its
/// owner, so `blocked()` is nil and an ask is known only by parsing the screen.
public struct TmuxAskTerminal: AgentAskTerminal {
    public let client: TmuxClient
    public let pane: String
    public init(client: TmuxClient, pane: String) { self.client = client; self.pane = pane }
    public func read() throws -> AskTerminalScreen {
        AskTerminalScreen(text: try client.snapshot(pane, lines: 0, visible: true), ansi: try? client.snapshotANSI(pane))
    }
    public func send(keys: [String]) throws { try client.sendKeys(keys, to: pane) }
    public func type(_ text: String) throws { try client.type(text, to: pane) }
}
