// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// How the owner answers an elicitation: Accept with field values, Decline, or Cancel (Esc).
public enum ElicitationAction: Equatable, Sendable {
	case accept([ElicitationFieldValue])
	case decline
	case cancel

	public var name: String {
		switch self {
		case .accept: return "accept"
		case .decline: return "decline"
		case .cancel: return "cancel"
		}
	}
}

/// One field's value in an Accept: a boolean for a checkbox, text for a text, number or enum
/// field (an enum takes one of its option labels). Fields left out keep what the form shows.
public struct ElicitationFieldValue: Codable, Equatable, Sendable {
	public var field: Int
	public var value: ElicitationForm.Value

	public init(field: Int, value: ElicitationForm.Value) {
		self.field = field
		self.value = value
	}
}

public enum ElicitationError: Error, Equatable, Sendable {
	/// The screen shows no elicitation (or no dialog, for a dismiss).
	case gone
	/// The screen shows a different form than the one answered (its id, if any).
	case changed(String?)
	/// The values do not fit the form.
	case invalidAnswer(String)
	/// A key did not have its effect; nothing more was sent. `at` says where it stopped
	/// ("field 2 of 3 (Job note)", "the Accept button").
	case stuck(String, at: String)
}

/// Enters an elicitation answer by keys (Space toggles, ↑/↓ move, → and ← open and close an
/// enum, Enter presses a button, Esc cancels), reading the screen after every key batch and
/// stopping at the first one that does not have its effect, the way `AgentAskDriver` does.
public struct ElicitationDriver: Sendable {
	public struct Report: Equatable, Sendable {
		public var promptID: String
		public var action: String
		public var steps: Int
		public var keys: Int
	}

	public let terminal: any AgentAskTerminal
	public var poll: TimeInterval
	public var timeout: TimeInterval
	/// How long the form must be left alone before Enter. Claude Code 2.1.314 drops an Enter
	/// that comes within a few tens of milliseconds of the cursor reaching a button, though the
	/// screen already shows the cursor there (3 of 4 live answers through the helper, 2026-10-30).
	public var settle: TimeInterval

	public init(terminal: any AgentAskTerminal, poll: TimeInterval = 0.12, timeout: TimeInterval = 3, settle: TimeInterval = 0.3) {
		self.terminal = terminal
		self.poll = poll
		self.timeout = timeout
		self.settle = settle
	}

	/// The form on screen now, without sending anything.
	public func current() throws -> ElicitationForm? {
		ElicitationFormParser.parse(try terminal.read().text)
	}

	/// Reads the kinds the screen does not show (unfocused unset fields) and the options of
	/// enums by moving onto each such field (and opening an enum, then closing it), then puts
	/// the cursor back. Only navigation keys are sent; no value changes.
	public func discover(_ form: ElicitationForm) throws -> ElicitationForm {
		guard !form.complete else { return form }
		var session = Session(driver: self, form: form)
		let start = try session.read().focus ?? .field(0)
		for index in session.form.fields.indices {
			let field = session.form.fields[index]
			guard field.kind == .unknown || (field.kind == .choice && field.options.isEmpty) else { continue }
			try session.go(to: .field(index))
			if session.form.fields[index].kind == .choice, session.form.fields[index].options.isEmpty {
				try session.expand(index)
				try session.collapse()
			}
		}
		try session.go(to: start)
		return session.form
	}

	/// Answers `form`. Throws before sending anything when the screen no longer shows it
	/// (`changed`, `gone`) or the values do not fit it, and stops at the first key that does
	/// not take (`stuck`, with where). Nothing is pressed after a stop.
	public func answer(_ form: ElicitationForm, _ action: ElicitationAction) throws -> Report {
		var session = Session(driver: self, form: form)
		let first = try session.read()
		guard first.id == form.id else { throw ElicitationError.changed(first.id) }
		switch action {
		case .cancel:
			try session.send(["esc"])
			try session.awaitGone(at: "Esc")
		case .decline:
			try session.go(to: .decline)
			try session.press(at: "the Decline button")
		case .accept(let values):
			let byField = try validate(session.form, values)
			for (index, value) in byField.sorted(by: { $0.key < $1.key }) {
				try session.set(index, value)
			}
			try session.go(to: .accept)
			try session.press(at: "the Accept button")
		}
		return Report(promptID: form.id, action: action.name, steps: session.steps, keys: session.keys)
	}

	/// Esc on a dialog no form parser reads, confirmed by the dialog leaving the screen.
	public func dismiss(_ dialog: BlockedDialog) throws -> Report {
		let before = BlockedDialogParser.parse(try terminal.read().text)
		guard let before else { throw ElicitationError.gone }
		guard before.lines == dialog.lines else { throw ElicitationError.changed(nil) }
		try terminal.send(keys: ["esc"])
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			Thread.sleep(forTimeInterval: poll)
			if BlockedDialogParser.parse(try terminal.read().text)?.lines != dialog.lines {
				return Report(promptID: "", action: "cancel", steps: 1, keys: 1)
			}
		}
		throw ElicitationError.stuck("the dialog is still on screen after Esc", at: "Esc")
	}

	func validate(_ form: ElicitationForm, _ values: [ElicitationFieldValue]) throws -> [Int: ElicitationForm.Value] {
		var byField: [Int: ElicitationForm.Value] = [:]
		for entry in values {
			guard form.fields.indices.contains(entry.field) else {
				throw ElicitationError.invalidAnswer("the form has no field \(entry.field + 1)")
			}
			guard byField[entry.field] == nil else { throw ElicitationError.invalidAnswer("field \(entry.field + 1) is given twice") }
			let field = form.fields[entry.field]
			switch (field.kind, entry.value) {
			case (.boolean, .bool), (.text, .text): break
			case (.choice, .text(let label)):
				guard field.options.contains(label) else {
					throw ElicitationError.invalidAnswer("\(field.label) has no option \u{201C}\(label)\u{201D}")
				}
			case (_, .unset): throw ElicitationError.invalidAnswer("unsetting \(field.label) is not supported")
			case (.unknown, _): throw ElicitationError.invalidAnswer("the kind of \(field.label) is not known yet; read the form first")
			default: throw ElicitationError.invalidAnswer("\(field.label) takes a \(field.kind == .boolean ? "boolean" : "text") value")
			}
			byField[entry.field] = entry.value
		}
		return byField
	}

	struct Session {
		let driver: ElicitationDriver
		var form: ElicitationForm
		var steps = 0
		var keys = 0

		var terminal: any AgentAskTerminal { driver.terminal }

		func place(_ focus: ElicitationForm.Focus?) -> String {
			switch focus {
			case .field(let index)?:
				return "field \(index + 1) of \(form.fields.count) (\(form.fields[index].label))"
			case .accept?: return "the Accept button"
			case .decline?: return "the Decline button"
			case nil: return "the form"
			}
		}

		mutating func read() throws -> ElicitationForm { try waitFor("read the form", at: "the form") { _ in true } }

		mutating func readOnce() throws -> ElicitationForm {
			guard let screen = ElicitationFormParser.parse(try terminal.read().text) else { throw ElicitationError.gone }
			var merged = form
			guard merged.merge(screen) else { throw ElicitationError.changed(screen.id) }
			form = merged
			return merged
		}

		mutating func send(_ batch: [String]) throws {
			guard !batch.isEmpty else { return }
			try terminal.send(keys: batch)
			steps += 1
			keys += batch.count
		}

		/// Polls until `done` holds for a read of this form, else throws `stuck(what, at:)`. A
		/// frame caught mid-redraw is read again; a real change outlasts the deadline.
		@discardableResult
		mutating func waitFor(_ what: String, at: String, _ done: (ElicitationForm) -> Bool) throws -> ElicitationForm {
			let deadline = Date().addingTimeInterval(driver.timeout)
			var lastError: ElicitationError?
			while true {
				do {
					let state = try readOnce()
					if done(state) { return state }
					lastError = nil
				} catch let error as ElicitationError {
					lastError = error
				}
				guard Date() < deadline else {
					if let lastError, steps == 0 { throw lastError }
					throw ElicitationError.stuck(lastError.map(Self.describe) ?? "could not \(what)", at: at)
				}
				Thread.sleep(forTimeInterval: driver.poll)
			}
		}

		static func describe(_ error: ElicitationError) -> String {
			switch error {
			case .gone: return "the form left the screen"
			case .changed: return "a different form is on screen"
			case .invalidAnswer(let message): return message
			case .stuck(let reason, _): return reason
			}
		}

		/// Moves the cursor to `target` one ↑/↓ at a time, confirming each move.
		mutating func go(to target: ElicitationForm.Focus) throws {
			if form.expanded != nil { try collapse() }
			for _ in 0..<(form.fields.count + 4) {
				let state = try read()
				guard let focus = state.focus else { throw ElicitationError.stuck("the cursor is not on the form", at: place(nil)) }
				if focus == target { return }
				let down = target.position(fields: form.fields.count) > focus.position(fields: form.fields.count)
				try send([down ? "down" : "up"])
				try waitFor("move toward \(place(target))", at: place(focus)) { $0.focus != focus }
			}
			throw ElicitationError.stuck("could not reach \(place(target))", at: place(form.focus))
		}

		mutating func expand(_ index: Int) throws {
			try send(["right"])
			try waitFor("open the list", at: place(.field(index))) { $0.expanded == index }
		}

		mutating func collapse() throws {
			guard let index = form.expanded else { return }
			try send(["left"])
			try waitFor("close the list", at: place(.field(index))) { $0.expanded == nil }
		}

		mutating func set(_ index: Int, _ value: ElicitationForm.Value) throws {
			try go(to: .field(index))
			let at = place(.field(index))
			let field = form.fields[index]
			if field.value == value { return }
			switch (field.kind, value) {
			case (.boolean, .bool(let want)):
				// Space cycles unset → ☒ → ☐ (set false) → ☒.
				for _ in 0..<3 {
					if form.fields[index].value == .bool(want) { return }
					let before = form.fields[index].value
					try send(["space"])
					try waitFor("toggle \(field.label)", at: at) { $0.fields[index].value != before }
				}
				if form.fields[index].value != .bool(want) { throw ElicitationError.stuck("\(field.label) did not toggle to \(want)", at: at) }
			case (.text, .text(let text)):
				if case .text(let shown) = form.fields[index].value, !shown.isEmpty {
					try send(["ctrl+u"])
					try waitFor("clear \(field.label)", at: at) { state in
						if case .text(let now) = state.fields[index].value { return now.isEmpty }
						return true
					}
				}
				guard !text.isEmpty else { return }
				try terminal.type(text)
				steps += 1
				keys += text.count
				try waitFor("type \(field.label)", at: at) { state in
					if case .text(let now) = state.fields[index].value { return AgentAskDriver.matches(now, text) }
					return false
				}
			case (.choice, .text(let label)):
				try expand(index)
				guard let row = form.fields[index].options.firstIndex(of: label) else {
					throw ElicitationError.stuck("\(field.label) has no option \u{201C}\(label)\u{201D} on screen", at: at)
				}
				guard let current = form.optionCursor else { throw ElicitationError.stuck("the list has no cursor", at: at) }
				if current != row {
					let delta = row - current
					try send(Array(repeating: delta > 0 ? "down" : "up", count: abs(delta)))
					try waitFor("move to \(label)", at: at) { $0.optionCursor == row }
				}
				try send(["space"])
				try waitFor("choose \(label)", at: at) { $0.expanded == nil && $0.fields[index].value == .text(label) }
			default:
				throw ElicitationError.invalidAnswer("\(field.label) cannot take that value")
			}
		}

		/// Enter on the focused button once the form has settled, and the form leaving the
		/// screen. An Enter that left the form exactly as it was (same cursor, values, no
		/// message) was dropped and is pressed once more; any change stops it.
		mutating func press(at: String) throws {
			Thread.sleep(forTimeInterval: driver.settle)
			let before = try read()
			try send(["enter"])
			do {
				try awaitGone(at: at)
			} catch ElicitationError.stuck(let reason, let stoppedAt) {
				guard let now = try? readOnce(), now == before else { throw ElicitationError.stuck(reason, at: stoppedAt) }
				try send(["enter"])
				try awaitGone(at: at)
			}
		}

		/// Waits until the form leaves the screen. A form still up after Enter shows why
		/// (Claude Code's validation message under a field).
		mutating func awaitGone(at: String) throws {
			let deadline = Date().addingTimeInterval(driver.timeout)
			while Date() < deadline {
				Thread.sleep(forTimeInterval: driver.poll)
				guard let screen = ElicitationFormParser.parse(try terminal.read().text), screen.id == form.id else { return }
				var merged = form
				_ = merged.merge(screen)
				form = merged
			}
			if let field = form.fields.first(where: { $0.error != nil }), let error = field.error {
				throw ElicitationError.stuck("Claude Code did not take the form: \(field.label): \(error)", at: at)
			}
			throw ElicitationError.stuck("the form is still on screen", at: at)
		}
	}
}
