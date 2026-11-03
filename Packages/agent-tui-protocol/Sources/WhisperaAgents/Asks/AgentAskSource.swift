// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// Where asks come from. Terminal harnesses (herdr, tmux) have no question API, so their asks
/// are parsed from the screen and keyed in by `AgentAskDriver`. A structured transport, such as
/// the Agent Client Protocol (ACP) or a future herdr question API, hands over the ask itself
/// and takes the answer as data: it implements this protocol and skips parsing and keys.
/// Hosts register one source per agent and stay agnostic of which kind it is.
public protocol AgentAskSource: Sendable {
	/// The ask the agent waits on now, if any.
	func pending() throws -> AgentAsk?
	/// Delivers answers to the ask with `promptID`; throws `AgentAskError.changed` when that
	/// ask is no longer pending.
	func answer(promptID: String, answers: [AgentAskAnswer]) throws
}

/// The screen-scraping source over any `AgentAskTerminal`.
public struct TerminalAskSource: AgentAskSource {
	public let driver: AgentAskDriver

	public init(terminal: any AgentAskTerminal) {
		driver = AgentAskDriver(terminal: terminal)
	}

	public func pending() throws -> AgentAsk? {
		guard let ask = try driver.current() else { return nil }
		return ask.complete ? ask : try driver.discover(ask)
	}

	public func answer(promptID: String, answers: [AgentAskAnswer]) throws {
		guard let ask = try pending() else { throw AgentAskError.changed(nil) }
		guard ask.id == promptID else { throw AgentAskError.changed(ask.id) }
		_ = try driver.submit(ask, answers: answers)
	}
}

/// ACP mapping: `session/request_permission` params to an ask, and an answer back to the
/// result. Option ids are ACP's `optionId`s, so no keys or indexes are involved.
public enum ACPAsk {
	/// `{"toolCall": {"title": …}, "options": [{"optionId", "name", "kind"}]}` → a confirm.
	public static func ask(permissionRequest params: [String: Any]) -> AgentAsk? {
		guard let rows = params["options"] as? [[String: Any]], !rows.isEmpty else { return nil }
		var options: [AgentAsk.Option] = []
		for row in rows {
			guard let id = row["optionId"] as? String, let name = row["name"] as? String else { return nil }
			let kind = (row["kind"] as? String).map { $0.hasPrefix("allow") ? "approve" : $0.hasPrefix("reject") ? "deny" : "other" }
			options.append(AgentAsk.Option(id: id, label: name, kind: kind))
		}
		let title = (params["toolCall"] as? [String: Any])?["title"] as? String
		return AgentAsk(
			source: .acp, kind: .confirm, title: title,
			questions: [AgentAsk.Question(header: title, text: title ?? "Allow this action?", options: options)])
	}

	/// The `session/request_permission` result for an answer, or `cancelled` without one.
	public static func result(_ answer: AgentAskAnswer?) -> [String: Any] {
		guard let id = answer?.optionIDs.first else { return ["outcome": ["outcome": "cancelled"]] }
		return ["outcome": ["outcome": "selected", "optionId": id]]
	}
}
