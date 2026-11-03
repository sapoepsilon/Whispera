// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation
import WhisperaAgents

/// HERDR captures the agent's terminal, including readable transcript marks.
/// Parsing is a best-effort projection, not a reconstructed chat history.
public struct HerdrTUIProvider: AgentTUIProvider {
    public let id = "herdr"
    public let displayName = "HERDR"
    public init() {}
    public func transcript(from snapshot: String) -> AgentTranscript {
        AgentTranscript(parsing: snapshot)
    }
    public func keys(for action: AgentTerminalAction) -> [String] {
        PlainTerminalProvider().keys(for: action)
    }

    /// The safe public projection of HERDR's agent_info wire object.
    public static func agent(_ info: [String: Any]) -> [String: Any] {
        func value(_ key: String) -> Any { info[key].flatMap { $0 is NSNull ? nil : $0 } ?? NSNull() }
        let status = (info["agent_status"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let cwd = (info["foreground_cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (info["cwd"] as? String)
        let terminalTitle = clean(info["terminal_title_stripped"]) ?? clean(info["terminal_title"]) ?? clean(info["title"])
        let tabName = clean(info["tab_label"]).flatMap { Int($0) == nil ? $0 : nil }
        let name = clean(info["name"]) ?? tabName ?? clean(info["workspace_label"]) ?? terminalTitle
        return ["id": value("pane_id"), "provider": "herdr", "agent": value("agent"), "display_agent": value("display_agent"),
                "name": name ?? NSNull(), "title": terminalTitle ?? NSNull(), "status": status, "cwd": cwd ?? NSNull(),
                "workspace_label": clean(info["workspace_label"]) ?? NSNull(), "tab_label": clean(info["tab_label"]) ?? NSNull(),
                "workspace_id": value("workspace_id"), "tab_id": value("tab_id"),
                "focused": (info["focused"] as? Bool) ?? false, "revision": value("revision"),
                "state_labels": info["state_labels"] as? [String: Any] ?? [:]]
    }

    /// Enrich agent wire objects with display names from HERDR's metadata-only APIs.
    public static func named(_ agents: [[String: Any]], workspaces: [[String: Any]], tabs: [[String: Any]]) -> [[String: Any]] {
        let workspaces = Dictionary(workspaces.compactMap { row -> (String, String)? in
            guard let id = row["workspace_id"] as? String, let label = clean(row["label"]) else { return nil }
            return (id, label)
        }, uniquingKeysWith: { _, last in last })
        let tabs = Dictionary(tabs.compactMap { row -> (String, String)? in
            guard let id = row["tab_id"] as? String, let label = clean(row["label"]) else { return nil }
            return (id, label)
        }, uniquingKeysWith: { _, last in last })
        return agents.map { row in
            var row = row
            if let id = row["workspace_id"] as? String, let label = workspaces[id] { row["workspace_label"] = label }
            if let id = row["tab_id"] as? String, let label = tabs[id] { row["tab_label"] = label }
            return row
        }
    }
    private static func clean(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let stripped = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(240))
    }
}
