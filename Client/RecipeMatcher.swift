// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

struct RecipeMatch: Equatable {
	let recipe: Recipe
	/// Transcribed text with the trigger phrase stripped from the front.
	let remainder: String
}

/// Matches transcribed text against recipe trigger phrases. Case-insensitive and
/// whitespace/punctuation tolerant; the longest matching trigger wins. See WHI-41.
enum RecipeMatcher {
	static func match(text: String, recipes: [Recipe]) -> RecipeMatch? {
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

	/// Lowercases and strips leading/trailing punctuation so "Professional," == "professional".
	private static func normalize(_ word: String) -> String {
		word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
	}
}
