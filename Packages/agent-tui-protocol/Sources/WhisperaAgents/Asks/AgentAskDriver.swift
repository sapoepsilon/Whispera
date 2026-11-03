// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// One read of an agent's terminal: plain text, and the same screen with its colours when the
/// harness can give them (they show which of Claude Code's tabs is active).
public struct AskTerminalScreen: Sendable, Equatable {
	public var text: String
	public var ansi: String?

	public init(text: String, ansi: String? = nil) {
		self.text = text
		self.ansi = ansi
	}
}

/// What a harness (herdr, tmux, …) gives the ask layer for one pane. Key names are the
/// shared vocabulary: `up`, `down`, `left`, `right`, `tab`, `shift+tab`, `enter`, `esc`,
/// `space`, `backspace`, `ctrl+u`. `type` enters literal text without pressing Enter.
public protocol AgentAskTerminal: Sendable {
	func read() throws -> AskTerminalScreen
	func send(keys: [String]) throws
	func type(_ text: String) throws
	/// Whether the harness itself says the agent waits on the owner; nil when it cannot tell
	/// (tmux), and detection rests on parsing the screen.
	func blocked() throws -> Bool?
}

extension AgentAskTerminal {
	public func blocked() throws -> Bool? { nil }
}

/// Enters semantic answers into an ask by keys, one step at a time: every key batch is
/// planned from a fresh read and its effect is confirmed by reading again before the next
/// one, so a screen that changed (answered on the Mac, a new ask) never gets blind keys.
public struct AgentAskDriver: Sendable {
	public struct Report: Equatable, Sendable {
		public var promptID: String
		/// Key batches sent, typed text counted as one.
		public var steps: Int
		public var keys: Int
	}

	public let terminal: any AgentAskTerminal
	public var poll: TimeInterval
	public var timeout: TimeInterval

	public init(terminal: any AgentAskTerminal, poll: TimeInterval = 0.12, timeout: TimeInterval = 3) {
		self.terminal = terminal
		self.poll = poll
		self.timeout = timeout
	}

	/// The ask on screen now, without sending anything.
	public func current() throws -> AgentAsk? {
		let read = try terminal.read()
		return AgentAskParser.ask(text: read.text, ansi: read.ansi)
	}

	/// Reads the questions of `ask` that are not on screen by moving between its tabs, then
	/// returns to the step it was on. Only navigation keys are sent; nothing is answered.
	public func discover(_ ask: AgentAsk) throws -> AgentAsk {
		guard ask.source == .claude || ask.source == .codex, !ask.complete else { return ask }
		var session = Session(driver: self, ask: ask)
		let start = try session.read().step
		for index in session.ask.questions.indices where !session.ask.questions[index].isRead {
			_ = try session.go(to: index)
		}
		_ = try session.go(to: start)
		return session.ask
	}

	/// Enters `answers` and submits. Throws before sending anything when the screen no
	/// longer shows `ask` (`AgentAskError.changed`) or the answers do not fit it, and stops
	/// at the first key that does not have its effect (`AgentAskError.stuck`, with how far it
	/// got). Nothing is submitted after a stop; a cursor left on the free-text row is moved off
	/// it so the harness reports the agent as waiting again.
	public func submit(_ ask: AgentAsk, answers: [AgentAskAnswer]) throws -> Report {
		if ask.source == .menu { return try submitMenu(ask, answers: answers) }
		guard ask.source != .acp else { throw AgentAskError.invalidAnswer("an ACP ask is answered through its AgentAskSource") }
		var session = Session(driver: self, ask: ask)
		let first = try session.read()
		guard first.ask.id == ask.id, first.ask.complete else { throw AgentAskError.changed(first.ask.id) }
		let byQuestion = try first.ask.validate(answers)
		do {
			for index in session.ask.questions.indices {
				let answer = byQuestion[index]!
				let question = session.ask.questions[index]
				session.at = index
				_ = try session.go(to: index)
				if question.multiSelect {
					try session.answerMulti(question, answer)
				} else {
					try session.answerSingle(question, answer, last: index == session.ask.questions.count - 1)
				}
			}
			session.at = session.ask.questions.count
			if session.ask.hasSubmitStep { try session.confirmReview(byQuestion) }
			try session.awaitGone()
		} catch AgentAskError.stuck(let reason, _) {
			throw AgentAskError.stuck(reason, progress: session.stopped())
		}
		return Report(promptID: ask.id, steps: session.steps, keys: session.keys)
	}

	func submitMenu(_ ask: AgentAsk, answers: [AgentAskAnswer]) throws -> Report {
		let text = try terminal.read().text
		guard let menu = ChoiceMenuParser.parse(text) else { throw AgentAskError.unparsed }
		guard menu.id == ask.id else { throw AgentAskError.changed(menu.id) }
		guard answers.count == 1, answers[0].question == 0, answers[0].optionIDs.count == 1, answers[0].other == nil,
			let keys = menu.keys(for: answers[0].optionIDs[0])
		else { throw AgentAskError.invalidAnswer("a menu takes one option id") }
		try terminal.send(keys: keys)
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if ChoiceMenuParser.parse(try terminal.read().text)?.id != menu.id {
				return Report(promptID: ask.id, steps: 1, keys: keys.count)
			}
			Thread.sleep(forTimeInterval: poll)
		}
		throw AgentAskError.stuck("the menu is still on screen after the choice")
	}

	/// The state of one submit or discovery: the ask as read so far and what was sent.
	struct Session {
		let driver: AgentAskDriver
		var ask: AgentAsk
		var steps = 0
		var keys = 0
		/// The question being entered (`questions.count` once at the review).
		var at = 0

		struct Read {
			var screen: AskScreen
			var ask: AgentAsk
			var step: Int
		}

		var terminal: any AgentAskTerminal { driver.terminal }

		/// A fresh read that must still be this ask; its step resolved from the tab colours,
		/// the review screen or the question text.
		/// A read that rides out a frame caught mid-redraw (see `waitFor`).
		mutating func read() throws -> Read { try waitFor("read the ask") { _ in true } }

		mutating func readOnce() throws -> Read {
			let raw = try terminal.read()
			guard let screen = AgentAskParser.screen(text: raw.text, ansi: raw.ansi) else { throw AgentAskError.unparsed }
			var merged = ask
			guard merged.merge(screen) else { throw AgentAskError.changed(AgentAsk(screen: screen).id) }
			ask = merged
			return Read(screen: screen, ask: merged, step: merged.step)
		}

		mutating func send(_ batch: [String]) throws {
			guard !batch.isEmpty else { return }
			try terminal.send(keys: batch)
			steps += 1
			keys += batch.count
		}

		/// Polls until `done` holds for a read of this ask, else throws `stuck(what)`.
		@discardableResult
		mutating func waitFor(_ what: String, _ done: (Read) -> Bool) throws -> Read {
			let deadline = Date().addingTimeInterval(driver.timeout)
			var lastError: AgentAskError?
			while true {
				do {
					let state = try readOnce()
					if done(state) { return state }
					lastError = nil
				} catch let error as AgentAskError {
					// A frame caught mid-redraw; a real change persists past the deadline.
					if case .invalidAnswer = error { throw error }
					lastError = error
				}
				guard Date() < deadline else { throw lastError ?? AgentAskError.stuck(what) }
				Thread.sleep(forTimeInterval: driver.poll)
			}
		}

		/// Shows question `target` (or the review step at `questions.count`).
		mutating func go(to target: Int) throws -> Read {
			for _ in 0..<(2 * ask.questions.count + 4) {
				let state = try read()
				if state.step == target { return state }
				if state.screen.dialect == .claude, state.screen.cursor == .other {
					// The free-text row is an input: Tab and arrows edit it. Step off it first.
					try send(["up"])
					try waitFor("leave the text row") { $0.screen.cursor != .other }
					continue
				}
				let forward = target > state.step
				let key: String
				switch state.screen.dialect {
				case .claude: key = forward ? "tab" : "shift+tab"
				case .codex: key = forward ? "right" : "left"
				}
				let from = state.step
				try send([key])
				try waitFor("move to question \(target + 1)") { $0.step != from }
			}
			throw AgentAskError.stuck("could not reach question \(target + 1)")
		}

		/// Moves the cursor to `row` (options, then the free-text row, then "Next").
		mutating func moveCursor(to row: Int) throws {
			let state = try read()
			guard let current = state.screen.cursorRow else { throw AgentAskError.stuck("the cursor is not on the list") }
			guard current != row else { return }
			let delta = row - current
			try send(Array(repeating: delta > 0 ? "down" : "up", count: abs(delta)))
			try waitFor("move the cursor") { $0.screen.cursorRow == row }
		}

		mutating func setOther(_ text: String) throws {
			var state = try read()
			if AgentAskDriver.matches(state.screen.otherText, text) { return }
			switch state.screen.dialect {
			case .claude:
				if state.screen.otherText != nil {
					try send(["ctrl+u"])
					state = try waitFor("clear the text row") { $0.screen.otherText == nil }
				}
			case .codex:
				if state.screen.notesOpen, state.screen.otherText != nil {
					try send(["tab"])
					state = try waitFor("clear the notes") { !$0.screen.notesOpen }
				}
				if !state.screen.notesOpen {
					try send(["tab"])
					state = try waitFor("open the notes") { $0.screen.notesOpen }
				}
			}
			try terminal.type(text)
			steps += 1
			keys += text.count
			try waitFor("type the answer") { AgentAskDriver.matches($0.screen.otherText, text) }
		}

		mutating func verifyQuestion(_ question: AgentAsk.Question) throws {
			let state = try read()
			guard state.screen.questionText == question.text,
				state.screen.options.map(\.label) == question.options.map(\.label)
			else { throw AgentAskError.changed(state.ask.id) }
		}

		mutating func answerSingle(_ question: AgentAsk.Question, _ answer: AgentAskAnswer, last: Bool) throws {
			try verifyQuestion(question)
			let from = try read().step
			let row = answer.optionIDs.first.flatMap { id in question.options.firstIndex { $0.id == id } }
				?? question.options.count
			try moveCursor(to: row)
			if let other = answer.other { try setOther(other) }
			try send(["enter"])
			if last, !ask.hasSubmitStep { return }
			try waitFor("confirm the answer") { $0.step != from }
		}

		mutating func answerMulti(_ question: AgentAsk.Question, _ answer: AgentAskAnswer) throws {
			try verifyQuestion(question)
			for (index, option) in question.options.enumerated() {
				let want = answer.optionIDs.contains(option.id)
				guard try read().screen.options[index].checked != want else { continue }
				try moveCursor(to: index)
				try send(["space"])
				try waitFor("toggle \(option.label)") { $0.screen.options[index].checked == want }
			}
			let otherRow = question.options.count
			if let other = answer.other {
				try moveCursor(to: otherRow)
				try setOther(other)
				if !(try read().screen.otherChecked) {
					try send(["enter"])
					try waitFor("check the typed answer") { $0.screen.otherChecked }
				}
			} else if try read().screen.otherChecked {
				try moveCursor(to: otherRow)
				try send(["ctrl+u"])
				let state = try waitFor("clear the typed answer") { $0.screen.otherText == nil }
				if state.screen.otherChecked {
					try send(["enter"])
					try waitFor("uncheck the typed answer") { !$0.screen.otherChecked }
				}
			}
			let from = try read().step
			try moveCursor(to: otherRow + 1)
			try send(["enter"])
			try waitFor("go past the question") { $0.step != from }
		}

		/// Checks the review lists the answers just entered, then presses Submit.
		mutating func confirmReview(_ answers: [Int: AgentAskAnswer]) throws {
			var state = try go(to: ask.questions.count)
			let lines = state.screen.review ?? []
			for (index, question) in ask.questions.enumerated() {
				guard let answer = answers[index] else { continue }
				let labels = answer.optionIDs.compactMap { id in question.options.first { $0.id == id }?.label }
					+ [answer.other].compactMap { $0 }
				// By text; by position only when the review lists every question, so a line
				// that did not parse can never lend its neighbour's answer.
				let line = lines.first { AgentAskDriver.squash($0.question) == AgentAskDriver.squash(question.text) }
					?? (lines.count == ask.questions.count ? lines[index] : nil)
				guard let line else {
					throw AgentAskError.stuck("the review does not list question \(index + 1)")
				}
				let shown = AgentAskDriver.squash(line.answer)
				guard labels.allSatisfy({ shown.contains(AgentAskDriver.squash($0)) }) else {
					throw AgentAskError.stuck("the review does not show the answer entered for question \(index + 1)")
				}
			}
			guard let submit = state.screen.reviewButtons.firstIndex(where: { $0.hasPrefix("Submit") }),
				let current = state.screen.reviewCursor
			else { throw AgentAskError.stuck("the review has no Submit button under a cursor") }
			if current != submit {
				let delta = submit - current
				try send(Array(repeating: delta > 0 ? "down" : "up", count: abs(delta)))
				state = try waitFor("move to Submit") { $0.screen.reviewCursor == submit }
			}
			try send(["enter"])
		}

		/// After a stop: what the form shows now, with the cursor stepped off the free-text row
		/// (navigation only; nothing is typed, chosen or submitted). Never throws.
		mutating func stopped() -> AgentAskProgress {
			var progress = AgentAskProgress(
				questions: ask.questions.count, stoppedAt: at, step: nil, answered: [], steps: steps)
			guard steps > 0 else {
				progress.step = ask.step
				progress.answered = ask.questions.indices.filter { ask.questions[$0].answered }
				return progress
			}
			guard var state = try? readOnce() else { return progress }
			if state.screen.dialect == .claude, state.screen.cursor == .other {
				if (try? send(["up"])) != nil, let after = try? waitFor("leave the text row", { $0.screen.cursor != .other }) {
					state = after
					progress.parked = true
				}
			}
			progress.step = state.step
			progress.answered = state.ask.questions.indices.filter { state.ask.questions[$0].answered }
			progress.steps = steps
			return progress
		}

		/// Waits until the screen no longer shows this ask.
		mutating func awaitGone() throws {
			let deadline = Date().addingTimeInterval(driver.timeout)
			while Date() < deadline {
				let raw = try terminal.read()
				guard let screen = AgentAskParser.screen(text: raw.text, ansi: raw.ansi) else { return }
				var merged = ask
				if !merged.merge(screen) { return }
				Thread.sleep(forTimeInterval: driver.poll)
			}
			throw AgentAskError.stuck("the ask is still on screen after submitting")
		}
	}

	static func squash(_ value: String) -> String {
		value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	/// The typed text on screen is `text` (whitespace-insensitive; a clipped display counts).
	static func matches(_ shown: String?, _ text: String) -> Bool {
		guard let shown else { return false }
		let display = squash(shown)
		let wanted = squash(text)
		if display == wanted { return true }
		let clipped = display.hasSuffix("…") ? String(display.dropLast()) : display
		return clipped.count >= 20 && wanted.hasPrefix(clipped)
	}
}
