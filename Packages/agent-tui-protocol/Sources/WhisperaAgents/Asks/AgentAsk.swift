// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import CryptoKit
import Foundation

/// An interactive question an agent is waiting on, independent of the agent's UI and of the
/// terminal it runs in: Claude Code's AskUserQuestion form, Codex's request_user_input, a
/// permission confirm or a numbered menu. Answers are semantic (`AgentAskAnswer`); the keys
/// that enter them are planned by `AgentAskDriver` against a fresh read of the screen.
public struct AgentAsk: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// A permission prompt: options that approve or deny.
		case confirm
		/// One question, one choice.
		case single
		/// One question, any number of choices.
		case multi
		/// Several questions, or a review step before submitting.
		case form
		/// One question answered with text only.
		case freeText = "free_text"
		/// A dialog that is not a permission (a folder-trust check, an update notice, a picker):
		/// one question, the agent's own option labels, no approve/deny meaning.
		case menu
	}

	/// Which UI drew the ask; it decides how the answer is keyed in.
	public enum Source: String, Codable, Sendable { case claude, codex, menu, acp }

	public struct Option: Codable, Equatable, Sendable {
		/// `"1"`, `"2"`, … in screen order.
		public var id: String
		public var label: String
		public var description: String?
		/// `approve`, `deny` or `other` for a confirm's options.
		public var kind: String?
		/// Choosing it quits the agent or ends its session ("No, exit"): ask before sending.
		public var destructive: Bool?

		public init(id: String, label: String, description: String? = nil, kind: String? = nil, destructive: Bool? = nil) {
			self.id = id
			self.label = label
			self.description = description
			self.kind = kind
			self.destructive = destructive
		}
	}

	public struct Question: Codable, Equatable, Sendable {
		public var header: String?
		/// Empty while the question has not been read yet (a tab not visited).
		public var text: String
		public var options: [Option]
		public var multiSelect: Bool
		/// Whether a free-text answer is accepted (Claude's "Type something", Codex's notes).
		public var allowsOther: Bool
		public var otherLabel: String?
		/// The agent's UI marks the question answered.
		public var answered: Bool

		public init(
			header: String? = nil, text: String, options: [Option], multiSelect: Bool = false, allowsOther: Bool = false,
			otherLabel: String? = nil, answered: Bool = false
		) {
			self.header = header
			self.text = text
			self.options = options
			self.multiSelect = multiSelect
			self.allowsOther = allowsOther
			self.otherLabel = otherLabel
			self.answered = answered
		}

		enum CodingKeys: String, CodingKey {
			case header, text, options, answered
			case multiSelect = "multi_select"
			case allowsOther = "allows_other"
			case otherLabel = "other_label"
		}

		public var isRead: Bool { !text.isEmpty }
	}

	/// The prompt id: identifies the ask's content, not its cursor or step.
	public var id: String
	public var source: Source
	public var kind: Kind
	public var title: String?
	public var detail: String?
	public var questions: [Question]
	/// The question on screen; `questions.count` is the review / submit step.
	public var step: Int
	/// A review screen with a Submit button follows the questions.
	public var hasSubmitStep: Bool
	/// Every question has been read. An incomplete ask needs `AgentAskDriver.discover` (it
	/// moves between the ask's tabs, never answers) before it can be shown in full.
	public var complete: Bool
	public var cancelKey: String?
	/// For a menu ask: `permission`, `trust`, `notice` or `menu` (`ChoiceMenu.Purpose`).
	public var purpose: String?

	public init(
		source: Source, kind: Kind, title: String? = nil, detail: String? = nil, questions: [Question], step: Int = 0,
		hasSubmitStep: Bool = false, cancelKey: String? = nil, id: String? = nil, purpose: String? = nil
	) {
		self.purpose = purpose
		self.source = source
		self.kind = kind
		self.title = title
		self.detail = detail
		self.questions = questions
		self.step = step
		self.hasSubmitStep = hasSubmitStep
		self.complete = questions.allSatisfy(\.isRead)
		self.cancelKey = cancelKey
		self.id = ""
		self.id = id ?? fingerprint()
	}

	enum CodingKeys: String, CodingKey {
		case id = "prompt_id"
		case source, kind, title, detail, questions, step, complete, purpose
		case hasSubmitStep = "has_submit_step"
		case cancelKey = "cancel_key"
	}

	/// A digest of what the ask asks: its source, headers, questions and option labels.
	public func fingerprint() -> String {
		var parts = [source.rawValue, title ?? ""]
		for question in questions {
			parts.append([question.header ?? "", question.text, question.multiSelect ? "m" : "s"].joined(separator: "\u{1F}"))
			parts += question.options.map { "\($0.id)\u{1F}\($0.label)" }
		}
		let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))
		return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	/// Recomputes `complete` and `id` after questions were filled in.
	public mutating func refreshIdentity() {
		complete = questions.allSatisfy(\.isRead)
		id = fingerprint()
	}

	/// A permission prompt (`confirm`) or any other dialog (`menu`) as an ask. Its id is the
	/// menu's own prompt id, so the same id answers it through either endpoint.
	public init(menu: ChoiceMenu) {
		let confirm = menu.isPermission
		// Codex pickers print a description column after the label.
		let options = menu.options.map { option -> Option in
			let (label, description) = CodexAskParser.split(option.label)
			return Option(
				id: option.id, label: label, description: description, kind: confirm ? option.kind.rawValue : nil,
				destructive: option.destructive ? true : nil)
		}
		self.init(
			source: .menu, kind: confirm ? .confirm : .menu, title: menu.title, detail: menu.detail,
			questions: [Question(header: menu.title, text: menu.question, options: options)], cancelKey: menu.cancelKey,
			id: menu.id, purpose: menu.purpose.rawValue)
	}

	/// The ask as a JSON object (snake_case keys), for hosts that build `[String: Any]` replies.
	public var jsonObject: [String: Any] {
		guard let data = try? JSONEncoder().encode(self),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return [:] }
		return object
	}
}

/// The owner's answer to one question: chosen option ids and/or free text. Never keys.
public struct AgentAskAnswer: Codable, Equatable, Sendable {
	/// The question's index in `AgentAsk.questions`.
	public var question: Int
	public var optionIDs: [String]
	public var other: String?

	public init(question: Int, optionIDs: [String] = [], other: String? = nil) {
		self.question = question
		self.optionIDs = optionIDs
		self.other = other
	}

	enum CodingKeys: String, CodingKey {
		case question
		case optionIDs = "option_ids"
		case other
	}

	public static let maxOtherLength = 500

	/// Parses a JSON `answers` array (`[{question, option_ids, other}]`).
	public static func parse(_ value: Any?) -> [AgentAskAnswer]? {
		guard let rows = value as? [[String: Any]], (1...8).contains(rows.count) else { return nil }
		var answers: [AgentAskAnswer] = []
		for row in rows {
			guard let question = row["question"] as? Int, (0..<8).contains(question) else { return nil }
			let ids = row["option_ids"] as? [String] ?? []
			guard row["option_ids"] == nil || row["option_ids"] is [String], ids.count <= 9 else { return nil }
			var other: String?
			if let text = row["other"], !(text is NSNull) {
				guard let text = text as? String else { return nil }
				other = text
			}
			answers.append(AgentAskAnswer(question: question, optionIDs: ids, other: other))
		}
		return answers
	}
}

public enum AgentAskError: Error, Equatable, Sendable {
	/// The screen shows no ask, or one this code cannot read.
	case unparsed
	/// The screen shows a different ask than the one answered (its current prompt id, if any).
	case changed(String?)
	/// The answers do not fit the ask.
	case invalidAnswer(String)
	/// A key did not have the effect it should have; nothing more was sent. A submit that got
	/// partway says how far (`progress`), so the owner knows what is on screen.
	case stuck(String, progress: AgentAskProgress? = nil)
}

/// How far a submit got before it stopped, and what the form shows now.
public struct AgentAskProgress: Equatable, Sendable {
	public var questions: Int
	/// The question being entered when it stopped (an index; `questions` is the review step).
	public var stoppedAt: Int
	/// The step the form was left on (an index; `questions` is the review step); nil when the
	/// screen no longer shows the ask.
	public var step: Int?
	/// Questions the form shows as answered (Claude's ☒ tabs); nothing is submitted.
	public var answered: [Int]
	/// Key batches sent before it stopped.
	public var steps: Int
	/// The cursor was moved off the free-text row afterwards, so the harness sees the agent as
	/// waiting again (Claude Code reports `idle` while that row has focus).
	public var parked: Bool

	public init(questions: Int, stoppedAt: Int, step: Int?, answered: [Int], steps: Int, parked: Bool = false) {
		self.questions = questions
		self.stoppedAt = stoppedAt
		self.step = step
		self.answered = answered
		self.steps = steps
		self.parked = parked
	}

	public var atReview: Bool { stoppedAt >= questions }
}

extension AgentAsk {
	/// Checks answers against the ask: every read question answered once, option ids known,
	/// one choice for a single-select question, free text only where it is accepted.
	public func validate(_ answers: [AgentAskAnswer]) throws -> [Int: AgentAskAnswer] {
		guard complete else { throw AgentAskError.invalidAnswer("the ask has questions that were not read yet") }
		var byQuestion: [Int: AgentAskAnswer] = [:]
		for answer in answers {
			guard questions.indices.contains(answer.question) else {
				throw AgentAskError.invalidAnswer("question \(answer.question) does not exist")
			}
			guard byQuestion[answer.question] == nil else {
				throw AgentAskError.invalidAnswer("question \(answer.question) is answered twice")
			}
			let question = questions[answer.question]
			let known = Set(question.options.map(\.id))
			guard Set(answer.optionIDs).count == answer.optionIDs.count, answer.optionIDs.allSatisfy(known.contains) else {
				throw AgentAskError.invalidAnswer("question \(answer.question) has an unknown or repeated option id")
			}
			var answer = answer
			if let other = answer.other {
				let trimmed = other.trimmingCharacters(in: .whitespacesAndNewlines)
				answer.other = trimmed.isEmpty ? nil : trimmed
			}
			if let other = answer.other {
				guard question.allowsOther else {
					throw AgentAskError.invalidAnswer("question \(answer.question) takes no free text")
				}
				guard other.count <= AgentAskAnswer.maxOtherLength,
					other.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
				else {
					throw AgentAskError.invalidAnswer("question \(answer.question)'s text must be one line of at most 500 characters")
				}
			}
			let count = answer.optionIDs.count + (answer.other == nil ? 0 : 1)
			guard count >= 1 else { throw AgentAskError.invalidAnswer("question \(answer.question) has no answer") }
			if !question.multiSelect {
				// Codex attaches notes to a chosen option; elsewhere a single answer is one choice.
				let codexNotes = source == .codex && answer.optionIDs.count == 1
				guard count == 1 || codexNotes else {
					throw AgentAskError.invalidAnswer("question \(answer.question) takes one answer")
				}
			}
			byQuestion[answer.question] = answer
		}
		guard byQuestion.count == questions.count else {
			throw AgentAskError.invalidAnswer("every question needs an answer")
		}
		return byQuestion
	}
}
