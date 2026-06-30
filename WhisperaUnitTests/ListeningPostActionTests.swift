import Foundation
import Testing

@testable import Whispera

struct ListeningPostActionTests {

	private func recipe(_ id: String, _ name: String) -> Recipe {
		Recipe(id: id, name: name, steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
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
}
