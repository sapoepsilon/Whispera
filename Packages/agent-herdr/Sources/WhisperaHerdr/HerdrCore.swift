// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation
import WhisperaAgents

/// Agent ids for herdr-core (`hc`) terminals. hc addresses are flat (`t9`, `t1b`) or carry the
/// machine that runs them (`mac-b/t7`). A slash cannot sit in a URL path segment, so a
/// remote address is written with a colon: `hc:t9`, `hc:mac-b:t7`. Both directions are
/// syntax checks only; a host still has to find the address in hc's current listing.
public enum HerdrCoreID {
    public static let prefix = "hc:"

    public static func isHerdrCore(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// `t` and 1-15 lowercase letters or digits.
    public static func isValidTerminal(_ terminal: String) -> Bool {
        terminal.first == "t" && (2...16).contains(terminal.utf8.count)
            && terminal.utf8.dropFirst().allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    /// 1-40 ASCII letters, digits, `-`, `_` or `.`, not starting with `-` or `.`.
    public static func isValidMachine(_ machine: String) -> Bool {
        guard (1...40).contains(machine.utf8.count), let first = machine.unicodeScalars.first, first != "-", first != "." else {
            return false
        }
        return machine.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    /// The agent id for an hc address, nil for one this encoding cannot carry.
    public static func id(address: String) -> String? {
        let parts = address.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return isValidTerminal(parts[0]) ? prefix + parts[0] : nil
        case 2:
            return isValidMachine(parts[0]) && isValidTerminal(parts[1]) ? prefix + parts[0] + ":" + parts[1] : nil
        default:
            return nil
        }
    }

    /// The hc address an agent id names, nil when the id is not a well-formed hc id.
    public static func address(_ id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return isValidTerminal(parts[0]) ? parts[0] : nil
        case 2:
            return isValidMachine(parts[0]) && isValidTerminal(parts[1]) ? parts[0] + "/" + parts[1] : nil
        default:
            return nil
        }
    }

    /// The machine of a remote hc id; nil for this machine's terminals and for other ids.
    public static func machine(_ id: String) -> String? {
        guard let address = address(id), let slash = address.firstIndex(of: "/") else { return nil }
        return String(address[..<slash])
    }

    public static func isRemote(_ id: String) -> Bool { machine(id) != nil }
}

/// herdr-core's terminals render like any other; their transcript marks are best effort.
public struct HerdrCoreTUIProvider: AgentTUIProvider {
    public let id = "hc"
    public let displayName = "herdr-core"
    public init() {}
    public func transcript(from snapshot: String) -> AgentTranscript { AgentTranscript(parsing: snapshot) }
    public func keys(for action: AgentTerminalAction) -> [String] { PlainTerminalProvider().keys(for: action) }
}

/// The public projection of hc's `Terminal` object. hc has no agent records: a terminal's
/// program reports its own status over OSC 7501, and Herdr.app's workspace and tab live in its
/// labels (`herdr.space`, `herdr.tab`, `where`). Nothing here is read from the screen.
public enum HerdrCoreAgent {
    /// Program names hc may run as an agent, by what a 7501 report or the foreground calls it.
    public static let knownAgents: [String: String] = [
        "claude": "claude", "claude-code": "claude", "codex": "codex", "pi": "pi", "opencode": "opencode",
        "gemini": "gemini", "amp": "amp", "droid": "droid", "crush": "crush", "qwen": "qwen", "goose": "goose",
        "cursor-agent": "cursor-agent", "copilot": "copilot", "omp": "omp",
    ]

    /// hc's status words, as the phone reads them. A terminal whose program never reported (a
    /// plain shell, `cat`) is `unknown`, as is a word hc adds later.
    public static let statuses: Set<String> = ["idle", "working", "done", "blocked", "error"]

    public static func status(_ terminal: [String: Any]) -> String {
        guard let state = (terminal["status"] as? [String: Any])?["state"] as? String, statuses.contains(state) else {
            return "unknown"
        }
        return state
    }

    /// What blocked it, when the program said: `permission`, `question` or `auth`.
    public static func blockedKind(_ terminal: [String: Any]) -> String? {
        guard status(terminal) == "blocked" else { return nil }
        return clean((terminal["status"] as? [String: Any])?["kind"])
    }

    /// The agent in the terminal: its 7501 `app` first (Claude Code says `claude-code`), else the
    /// foreground program when it is a known agent CLI. nil for a shell or any other program.
    public static func kind(_ terminal: [String: Any]) -> String? {
        if let app = clean((terminal["status"] as? [String: Any])?["app"])?.lowercased(), let known = knownAgents[app] {
            return known
        }
        let foreground = terminal["foreground"] as? [String: Any]
        let argv0 = (foreground?["argv"] as? [String])?.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        if let argv0, let known = knownAgents[argv0] { return known }
        if let name = clean(foreground?["name"])?.lowercased(), let known = knownAgents[name] { return known }
        return nil
    }

    /// The foreground program's short name (`zsh`, `cat`), for terminals without an agent.
    public static func program(_ terminal: [String: Any]) -> String? {
        let foreground = terminal["foreground"] as? [String: Any]
        if let argv0 = (foreground?["argv"] as? [String])?.first, !argv0.isEmpty {
            return clean(URL(fileURLWithPath: argv0).lastPathComponent)
        }
        return clean(foreground?["name"]) ?? (terminal["argv"] as? [String])?.first.flatMap { clean(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    /// `where` is Herdr.app's `<workspace> / <tab>`.
    static func place(_ labels: [String: Any]) -> (workspace: String?, tab: String?) {
        guard let place = clean(labels["where"]) else { return (nil, nil) }
        guard let split = place.range(of: " / ", options: .backwards) else { return (place, nil) }
        return (clean(String(place[..<split.lowerBound])), clean(String(place[split.upperBound...])))
    }

    /// The label a host sets on terminals it starts, for the name the owner gave.
    public static let nameLabel = "whispera.name"

    /// The agent object for one hc terminal, nil when its address cannot be carried in an id.
    /// `machine` is the `{"id","label"}` object of the machine it runs on.
    public static func agent(_ terminal: [String: Any], machine: [String: Any]) -> [String: Any]? {
        guard let address = terminal["address"] as? String, let id = HerdrCoreID.id(address: address) else { return nil }
        let labels = terminal["labels"] as? [String: Any] ?? [:]
        let place = place(labels)
        let title = clean(terminal["title"]) ?? clean((terminal["status"] as? [String: Any])?["title"])
        let kind = kind(terminal)
        let program = program(terminal)
        let name = clean(terminal["name"]) ?? clean(labels[nameLabel]) ?? place.workspace ?? title ?? address
        let foreground = terminal["foreground"] as? [String: Any]
        let cwd = clean(foreground?["cwd"]) ?? clean(terminal["cwd"])
        let statusObject = terminal["status"] as? [String: Any]
        var agent: [String: Any] = [
            "id": id, "provider": "hc", "agent": kind ?? NSNull(), "display_agent": kind ?? program ?? "terminal",
            "name": name, "title": title ?? NSNull(), "status": status(terminal), "cwd": cwd ?? NSNull(),
            "workspace_label": place.workspace ?? NSNull(), "tab_label": place.tab ?? NSNull(),
            "workspace_id": clean(labels["herdr.space"]).map { "hc:" + $0 } ?? NSNull(),
            "tab_id": clean(labels["herdr.tab"]) ?? NSNull(), "focused": false, "revision": NSNull(),
            "machine": machine, "state_labels": [String: Any](),
        ]
        if let turn = terminal["turn"] as? Int { agent["turn"] = turn }
        // When hc last saw the status change (Unix ms): the phone's "Working · 2m 14s".
        if let since = terminal["status_ms"] as? Int, since > 0 { agent["status_since_ms"] = since }
        if let kind = blockedKind(terminal) { agent["status_kind"] = kind }
        if let message = clean(statusObject?["msg"]) { agent["status_message"] = message }
        return agent
    }

    public static func clean(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let stripped = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(240))
    }
}

/// The ask layer's view of one hc terminal: `terminal.read` (text only: hc has no ANSI read),
/// `terminal.keys`, and `terminal.get`'s self-reported `blocked` status. The host supplies the
/// call (method, params → the reply's `result`) with its own connection and allowlist, and
/// `address` is one it found in hc's listing.
public struct HerdrCoreAskTerminal: AgentAskTerminal {
    public typealias Call = @Sendable (_ method: String, _ params: [String: Any]) throws -> [String: Any]

    public let address: String
    private let call: Call
    public static let chunk = 48

    public init(address: String, call: @escaping Call) {
        self.address = address
        self.call = call
    }

    public func read() throws -> AskTerminalScreen {
        let result = try call("terminal.read", ["terminal": address, "lines": 0])
        return AskTerminalScreen(text: result["text"] as? String ?? "", ansi: nil)
    }

    public func send(keys: [String]) throws {
        guard !keys.isEmpty else { return }
        _ = try call("terminal.keys", ["terminal": address, "keys": keys])
    }

    /// hc presses keys, not characters: a lowercase letter, digit, space or unshifted US
    /// punctuation is its own key, an uppercase letter is `shift+<letter>`, and anything else
    /// (`!`, `?`, quotes, non-ASCII) has no key hc can press. Refused before any key is sent,
    /// so an answer is never typed half-way.
    public func type(_ text: String) throws {
        guard let keys = Self.keys(typing: text) else {
            let first = text.first { Self.key(for: $0) == nil }.map(String.init) ?? ""
            throw AgentAskError.invalidAnswer("herdr-core can't type \u{201C}\(first)\u{201D}; answer this one on the Mac")
        }
        var start = 0
        while start < keys.count {
            try send(keys: Array(keys[start..<min(keys.count, start + Self.chunk)]))
            start += Self.chunk
        }
    }

    public func blocked() throws -> Bool? {
        HerdrCoreAgent.status(try call("terminal.get", ["terminal": address])) == "blocked"
    }

    static let unshifted = Set("abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./")

    static func key(for character: Character) -> String? {
        if character == " " { return "space" }
        if unshifted.contains(character) { return String(character) }
        if character.isASCII, character.isUppercase, let lower = character.lowercased().first, unshifted.contains(lower) {
            return "shift+" + String(lower)
        }
        return nil
    }

    /// The keys that type `text`, nil when some character has none.
    public static func keys(typing text: String) -> [String]? {
        var keys: [String] = []
        for character in text {
            guard let key = key(for: character) else { return nil }
            keys.append(key)
        }
        return keys
    }
}
