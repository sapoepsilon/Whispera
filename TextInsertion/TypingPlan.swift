import Foundation

enum TypingStep: Equatable {
	case text([UniChar])
	case newline
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

		for character in text {
			if character.isNewline {
				flush()
				steps.append(.newline)
				continue
			}
			let units = Array(String(character).utf16)
			if buffer.count + units.count > maxUnitsPerEvent {
				flush()
			}
			buffer.append(contentsOf: units)
		}
		flush()
		return steps
	}
}
