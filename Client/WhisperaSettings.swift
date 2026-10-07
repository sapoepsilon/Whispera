// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaRecipes

/// App-global client settings backed by UserDefaults. Secrets (auth token,
/// BYOK keys) never live here — they go in the Keychain. See WHI-24/40/45.
enum WhisperaSettings {
	private static let defaults = UserDefaults.standard
	private static let serverURLKey = "whisperaServerURL"

	static let defaultServerURL = "http://localhost:3000"

	static var serverURLString: String {
		get { defaults.string(forKey: serverURLKey) ?? defaultServerURL }
		set { defaults.set(newValue, forKey: serverURLKey) }
	}

	static var serverURL: URL? {
		URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	static let defaultCommandIdKey = "whisperaDefaultCommandId"

	/// Recipe id of the command that post-processes every dictation when no
	/// trigger phrase matches. Empty = no default (paste raw). See WHI-49.
	static var defaultCommandId: String {
		get { defaults.string(forKey: defaultCommandIdKey) ?? "" }
		set { defaults.set(newValue, forKey: defaultCommandIdKey) }
	}

	static let recipesEnabledKey = "whisperaRecipesEnabled"

	/// Master switch for recipes on dictation: neither the default command nor
	/// a trigger phrase runs while this is off. Off unless the user turns it on
	/// (or picks a default command, which is the same explicit choice). Never
	/// registered as a default: `RecipeEnablementMigration` relies on telling
	/// "never decided" apart from "off".
	static var recipesEnabled: Bool {
		get { defaults.bool(forKey: recipesEnabledKey) }
		set { defaults.set(newValue, forKey: recipesEnabledKey) }
	}

	/// The user picked a default command in the Recipes tab or the pill. A real
	/// pick is the explicit opt-in the master switch asks for; "None" leaves the
	/// switch alone, since trigger phrases may still be wanted.
	static func didPickDefaultCommand(_ id: String, in defaults: UserDefaults = .standard) {
		guard !id.isEmpty else { return }
		defaults.set(true, forKey: recipesEnabledKey)
	}
}

/// Decides `whisperaRecipesEnabled` once for installs that predate it.
///
/// Before the switch existed every recipe was live: the default command ran on
/// each dictation and any trigger phrase fired, so a starter set loaded once —
/// or a default left pointing at one of its recipes — sent dictations to an
/// LLM server the user may never have set up (and pasted a 503 at them every
/// time). Only a recipe the user actually wrote or edited, and wired up to run
/// (as the default, or with a trigger phrase), counts as having opted in.
/// Everything else starts off, and a default pointing at an untouched starter
/// recipe is cleared so the pickers show "None" instead of an action that no
/// longer runs.
enum RecipeEnablementMigration {
	static func migrateIfNeeded(in defaults: UserDefaults, recipes: [Recipe]) {
		guard defaults.object(forKey: WhisperaSettings.recipesEnabledKey) == nil else { return }

		let defaultId = defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) ?? ""
		let userRecipes = recipes.filter { !isUntouchedStarter($0) }
		let defaultIsUsers = !defaultId.isEmpty && userRecipes.contains { $0.id == defaultId }
		let userHasTrigger = userRecipes.contains {
			!($0.triggerPhrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}
		let enabled = defaultIsUsers || userHasTrigger

		if !enabled, !defaultId.isEmpty {
			defaults.set("", forKey: WhisperaSettings.defaultCommandIdKey)
		}
		defaults.set(enabled, forKey: WhisperaSettings.recipesEnabledKey)
	}

	/// A recipe exactly as "Load Starter Set" seeded it. Ids are minted per
	/// seed, so everything but the id is compared.
	static func isUntouchedStarter(_ recipe: Recipe) -> Bool {
		Recipe.localDefaults.contains {
			$0.name == recipe.name && $0.description == recipe.description
				&& $0.triggerPhrase == recipe.triggerPhrase && $0.steps == recipe.steps
				&& $0.outputFormat == recipe.outputFormat
		}
	}
}
