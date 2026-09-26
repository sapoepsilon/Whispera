import Foundation

enum TypingStep: Equatable {
	case text([UniChar])
}

enum TypingPlan {
	// CGEventKeyboardSetUnicodeString drops anything past 20 UTF-16 units per event
	static let maxUnitsPerEvent = 20

	static func steps(for text: String) -> [TypingStep] {
		var steps: [TypingStep] = []
		var buffer: [UniChar] = []

		func flush() {
			guard !buffer.isEmpty else { return }
			steps.append(.text(buffer))
			buffer.removeAll(keepingCapacity: true)
		}

		for character in flattenedLineBreaks(text) {
			let units = Array(String(character).utf16)
			if buffer.count + units.count > maxUnitsPerEvent {
				flush()
			}
			buffer.append(contentsOf: units)
		}
		flush()
		return steps
	}

	/// A typed newline is a Return press, which submits in chat apps and runs commands in a
	/// terminal, so each run of line breaks (including ones an LLM added) becomes one space.
	static func flattenedLineBreaks(_ text: String) -> String {
		var result = ""
		var previousWasNewline = false
		for character in text {
			if character.isNewline {
				if !previousWasNewline { result.append(" ") }
				previousWasNewline = true
			} else {
				result.append(character)
				previousWasNewline = false
			}
		}
		return result
	}
}
