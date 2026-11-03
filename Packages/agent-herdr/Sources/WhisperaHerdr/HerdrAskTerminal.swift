// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation
import WhisperaAgents

/// The ask layer's view of one HERDR agent: `agent.read` (plain and ANSI), `agent.send_keys`
/// and `agent.get`'s `blocked` status. The host supplies the socket call (method, params →
/// the reply's `result`) and so keeps its own connection, allowlist and machine routing.
/// Text is typed as one key per character: `agent.send_keys` accepts any single character,
/// so no `pane.*` write is needed.
public struct HerdrAskTerminal: AgentAskTerminal {
    public typealias Call = @Sendable (_ method: String, _ params: [String: Any]) throws -> [String: Any]

    public let target: String
    private let call: Call
    public static let chunk = 48

    public init(target: String, call: @escaping Call) {
        self.target = target
        self.call = call
    }

    public func read() throws -> AskTerminalScreen {
        func text(_ format: String) throws -> String {
            let result = try call("agent.read", ["target": target, "source": "visible", "lines": 80,
                                                 "format": format, "strip_ansi": format == "text"])
            return (result["read"] as? [String: Any])?["text"] as? String ?? ""
        }
        let plain = try text("text")
        return AskTerminalScreen(text: plain, ansi: try? text("ansi"))
    }

    public func send(keys: [String]) throws {
        guard !keys.isEmpty else { return }
        _ = try call("agent.send_keys", ["target": target, "keys": keys])
    }

    public func type(_ text: String) throws {
        let keys = Self.keys(typing: text)
        var start = 0
        while start < keys.count {
            try send(keys: Array(keys[start..<min(keys.count, start + Self.chunk)]))
            start += Self.chunk
        }
    }

    public func blocked() throws -> Bool? {
        let result = try call("agent.get", ["target": target])
        return ((result["agent"] as? [String: Any])?["agent_status"] as? String) == "blocked"
    }

    /// One HERDR key per character; a space is the `space` key.
    public static func keys(typing text: String) -> [String] {
        text.map { $0 == " " ? "space" : String($0) }
    }
}
