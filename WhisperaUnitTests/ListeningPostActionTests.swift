import Foundation
import Testing

@testable import Whispera

struct ListeningPostActionTests {

	private func recipe(_ id: String, _ name: String, description: String? = nil) -> Recipe {
		Recipe(
			id: id,
			name: name,
			description: description,
			steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
	}

	@Test func emptyIdIsNoAction() {
		#expect(ListeningPostAction.label(defaultCommandId: "", recipes: []) == "No action")
	}

	@Test func validIdResolvesToName() {
		let recipes = [recipe("a", "Polish"), recipe("b", "Summarize")]
		#expect(ListeningPostAction.label(defaultCommandId: "b", recipes: recipes) == "Summarize")
	}

	@Test func staleIdFallsBackToNoAction() {
		let recipes = [recipe("a", "Polish")]
		#expect(ListeningPostAction.label(defaultCommandId: "missing", recipes: recipes) == "No action")
	}

	@Test func emptyNameShowsUntitled() {
		let recipes = [recipe("a", "")]
		#expect(ListeningPostAction.label(defaultCommandId: "a", recipes: recipes) == "Untitled")
	}

	@Test func nothingArmedWhenUnset() {
		#expect(!ListeningPostAction.isArmed(defaultCommandId: "", recipes: [recipe("a", "Polish")]))
	}

	@Test func nothingArmedWhenTheCommandIsGone() {
		#expect(
			!ListeningPostAction.isArmed(defaultCommandId: "gone", recipes: [recipe("a", "Polish")]))
	}

	@Test func armedWhenTheCommandResolves() {
		#expect(ListeningPostAction.isArmed(defaultCommandId: "a", recipes: [recipe("a", "Polish")]))
	}

	@Test func noActionUsesTheNeutralGlyph() {
		#expect(
			ListeningPostAction.glyph(defaultCommandId: "", recipes: [])
				== ListeningPostAction.noActionGlyph)
	}

	@Test func staleIdFallsBackToTheNeutralGlyph() {
		let recipes = [recipe("a", "Polish")]
		#expect(
			ListeningPostAction.glyph(defaultCommandId: "missing", recipes: recipes)
				== ListeningPostAction.noActionGlyph)
	}

	@Test func unmatchedNameUsesTheGenericGlyph() {
		let recipes = [recipe("a", "Zork")]
		#expect(
			ListeningPostAction.glyph(defaultCommandId: "a", recipes: recipes)
				== ListeningPostAction.genericGlyph)
	}

	@Test(
		arguments: [
			("Translate to Spanish", "globe"),
			("Summarize", "text.alignleft"),
			("Proofread", "wand.and.stars"),
			("Fix my grammar", "wand.and.stars"),
			("Polish it up", "wand.and.stars"),
			("Draft an email", "envelope"),
			("Code review", "chevron.left.forwardslash.chevron.right"),
			("Todo list", "checklist"),
			("Quick note", "note.text"),
			("Meeting notes", "person.2"),
		])
	func nameKeywordPicksAGlyph(name: String, expected: String) {
		let recipes = [recipe("a", name)]
		#expect(ListeningPostAction.glyph(defaultCommandId: "a", recipes: recipes) == expected)
	}

	@Test func glyphMatchingIsCaseInsensitive() {
		let recipes = [recipe("a", "TRANSLATE")]
		#expect(ListeningPostAction.glyph(defaultCommandId: "a", recipes: recipes) == "globe")
	}

	@Test func descriptionCanCarryTheKeyword() {
		let recipes = [recipe("a", "Zork", description: "Turns speech into an email")]
		#expect(ListeningPostAction.glyph(defaultCommandId: "a", recipes: recipes) == "envelope")
	}

	// The neutral glyph must never be reachable from an armed command, or the
	// pill would tint while still showing "no action".
	@Test func armedCommandNeverShowsTheNeutralGlyph() {
		let recipes = [recipe("a", "")]
		#expect(
			ListeningPostAction.glyph(defaultCommandId: "a", recipes: recipes)
				!= ListeningPostAction.noActionGlyph)
	}
}
