// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI
import WhisperaRecipes

/// Single source of truth for the user's recipes ("Commands").
///
/// The model, the JSON persistence, the trigger matcher and the bundled starter
/// set are all `WhisperaRecipes` now; what is left here is the `@Observable`
/// shell SwiftUI binds to and the async signatures the existing call sites use.
/// The backend CRUD arms went with the extraction — they were guarded by a
/// `usesBackend` that returned `false` unconditionally while the app ships
/// without accounts, so every branch already ran on the local cache. Restoring
/// backend sync means calling `WhisperaBackend`'s client from here, not
/// reinstating a second store. See WHI-30 / WHI-41 / WHI-94.
@MainActor
@Observable
final class RecipeStore {
	static let shared = RecipeStore()

	private(set) var recipes: [Recipe] = []
	private(set) var isSyncing = false
	var lastError: String?

	@ObservationIgnored private let store: WhisperaRecipes.RecipeStore

	init(fileURL: URL? = nil) {
		self.store = WhisperaRecipes.RecipeStore(fileURL: fileURL)
		mirror()
	}

	/// The package store owns the array; this copies it out so `@Observable`
	/// sees a change. One line per mutation is cheaper than making the package
	/// type depend on Observation for the sake of one host.
	private func mirror() {
		recipes = store.recipes
		lastError = store.lastError
	}

	func create(_ recipe: Recipe) async {
		store.create(recipe)
		mirror()
	}

	func update(_ recipe: Recipe) async {
		store.update(recipe)
		mirror()
	}

	func delete(_ recipe: Recipe) async {
		store.delete(recipe)
		mirror()
	}

	func loadDefaults() async {
		store.loadDefaults()
		mirror()
	}

	/// Re-reads the on-disk cache. Named `reload`, not `sync`: there is no
	/// backend to synchronise with while the app ships without accounts, and
	/// calling it `sync` is what made a purely local read look like a network
	/// round trip.
	func reload() async {
		store.reload()
		mirror()
	}

	func match(_ text: String) -> RecipeMatch? { store.match(text) }
}
