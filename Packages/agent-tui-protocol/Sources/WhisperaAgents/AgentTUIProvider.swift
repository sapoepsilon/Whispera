// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// A provider converts a terminal snapshot into readable content and describes
/// keyboard actions. Transport, authentication, views and agent launch policy
/// belong to the importing application. Unknown TUIs can always show raw text.
public protocol AgentTUIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func transcript(from snapshot: String) -> AgentTranscript
    func keys(for action: AgentTerminalAction) -> [String]
}

public enum AgentTerminalAction: Sendable, Equatable {
    case previous, next, previousTab, nextTab, confirm, cancel
}

public struct PlainTerminalProvider: AgentTUIProvider {
    public let id = "terminal"
    public let displayName = "Terminal"
    public init() {}
    public func transcript(from snapshot: String) -> AgentTranscript {
        AgentTranscript(items: snapshot.isEmpty ? [] : [.message(snapshot)])
    }
    public func keys(for action: AgentTerminalAction) -> [String] {
        switch action {
        case .previous: return ["up"]
        case .next: return ["down"]
        case .previousTab: return ["shift+left"]
        case .nextTab: return ["shift+right"]
        case .confirm: return ["enter"]
        case .cancel: return ["esc"]
        }
    }
}

/// Hosts supply adapters explicitly; no executable discovery or implicit writes.
public struct AgentTUIRegistry: Sendable {
    private let providers: [String: any AgentTUIProvider]
    public init(_ providers: [any AgentTUIProvider]) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
    public func provider(_ id: String) -> any AgentTUIProvider {
        providers[id] ?? PlainTerminalProvider()
    }
}
