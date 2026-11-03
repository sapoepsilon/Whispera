import Foundation

public struct RecipeMatch: Equatable, Sendable {
	public let recipe: Recipe
	/// The transcript with the trigger phrase stripped from the front.
	public let remainder: String

	public init(recipe: Recipe, remainder: String) {
		self.recipe = recipe
		self.remainder = remainder
	}
}

/// Matches a transcript against recipe trigger phrases.
///
/// Word-by-word rather than by string prefix, which is what makes "summarizes
/// the report" not fire the "summarize" command — a prefix match would, and a
/// dictation that silently rewrites itself because of one shared stem is worse
/// than one that never fires. Case-insensitive, whitespace- and
/// punctuation-tolerant; the longest matching trigger wins.
public enum RecipeMatcher {
	public static func match(text: String, recipes: [Recipe]) -> RecipeMatch? {
		let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		guard !words.isEmpty else { return nil }
		let normalized = words.map(normalize)

		var best: (recipe: Recipe, count: Int)?
		for recipe in recipes {
			guard let trigger = recipe.triggerPhrase, !trigger.isEmpty else { continue }
			let triggerWords =
				trigger
				.split(whereSeparator: { $0.isWhitespace })
				.map { normalize(String($0)) }
				.filter { !$0.isEmpty }
			guard !triggerWords.isEmpty, triggerWords.count <= normalized.count else { continue }

			if Array(normalized.prefix(triggerWords.count)) == triggerWords {
				if best == nil || triggerWords.count > best!.count {
					best = (recipe, triggerWords.count)
				}
			}
		}

		guard let best else { return nil }
		let remainder = words.dropFirst(best.count).joined(separator: " ")
		return RecipeMatch(recipe: best.recipe, remainder: remainder)
	}

	/// Lowercases and strips leading/trailing punctuation, so "Professional,"
	/// matches "professional".
	private static func normalize(_ word: String) -> String {
		word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
	}
}
