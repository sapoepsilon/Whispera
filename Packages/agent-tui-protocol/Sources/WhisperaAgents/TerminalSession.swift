// SPDX-License-Identifier: MIT
import Foundation

/// A provider's pane. Hosts own connections, permissions and UI.
public struct TerminalSession: Sendable, Equatable {
    public var id: String
    public var name: String
    public var command: String?
    public var cwd: String?
    public var workspaceID: String?
    public var workspaceName: String?
    public var tabID: String?
    public var focused: Bool
    public init(id: String, name: String, command: String? = nil, cwd: String? = nil,
                workspaceID: String? = nil, workspaceName: String? = nil, tabID: String? = nil, focused: Bool = false) {
        self.id = id; self.name = name; self.command = command; self.cwd = cwd
        self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.tabID = tabID; self.focused = focused
    }
}

/// An independently importable adapter may implement transport as well as display.
/// Implementations must send literal prompt text and bound reads and subprocesses.
public protocol AgentSessionTransport: Sendable {
    var providerID: String { get }
    func sessions() throws -> [TerminalSession]
    func snapshot(_ paneID: String, lines: Int, visible: Bool) throws -> String
    func send(_ text: String, to paneID: String) throws
    func sendKeys(_ keys: [String], to paneID: String) throws
}
