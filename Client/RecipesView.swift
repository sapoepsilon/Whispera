// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

/// Settings tab for managing recipes ("Commands"). Create / edit / delete, and
/// load the starter set. See WHI-30.
struct RecipesView: View {
	@State private var store = RecipeStore.shared
	@State private var editing: Recipe?
	@State private var isCreating = false

	var body: some View {
		VStack(spacing: 0) {
			header

			if store.recipes.isEmpty {
				emptyState
			} else {
				List {
					ForEach(store.recipes) { recipe in
						Button {
							editing = recipe
						} label: {
							recipeRow(recipe)
						}
						.buttonStyle(.plain)
					}
					.onDelete { offsets in
						let targets = offsets.map { store.recipes[$0] }
						Task { for r in targets { await store.delete(r) } }
					}
				}
			}

			if let error = store.lastError {
				Text(error)
					.font(.caption)
					.foregroundColor(.red)
					.padding(.horizontal, 20)
					.padding(.bottom, 8)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.task { await store.sync() }
		.sheet(isPresented: $isCreating) {
			RecipeEditor(
				recipe: Recipe(name: "", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
			) { recipe in
				Task { await store.create(recipe) }
			}
		}
		.sheet(item: $editing) { recipe in
			RecipeEditor(recipe: recipe) { updated in
				Task { await store.update(updated) }
			}
		}
	}

	private var header: some View {
		HStack {
			Text("Commands")
				.font(.headline)
			if store.isSyncing { ProgressView().scaleEffect(0.6) }
			Spacer()
			Button("Load Starter Set") { Task { await store.loadDefaults() } }
			Button {
				isCreating = true
			} label: {
				Label("New", systemImage: "plus")
			}
		}
		.padding(20)
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "wand.and.stars")
				.font(.largeTitle)
				.foregroundColor(.secondary)
			Text("No commands yet")
				.font(.headline)
			Text("A command runs an AI step on your dictation when you say its trigger phrase.")
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(40)
	}

	private func recipeRow(_ recipe: Recipe) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(recipe.name.isEmpty ? "Untitled" : recipe.name)
				.font(.subheadline.weight(.medium))
			if let trigger = recipe.triggerPhrase, !trigger.isEmpty {
				Text("“\(trigger)”")
					.font(.caption)
					.foregroundColor(.secondary)
			} else {
				Text("Runs on every dictation")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
	}
}

/// Create/edit form for a single recipe. v1 edits one `llm` step's prompt + model.
private struct RecipeEditor: View {
	@Environment(\.dismiss) private var dismiss
	@State private var draft: Recipe
	private let onSave: (Recipe) -> Void

	init(recipe: Recipe, onSave: @escaping (Recipe) -> Void) {
		_draft = State(initialValue: recipe)
		self.onSave = onSave
	}

	private var promptBinding: Binding<String> {
		Binding(
			get: { draft.steps.first?.config.prompt ?? "" },
			set: { newValue in
				if draft.steps.isEmpty {
					draft.steps = [RecipeStep(config: LLMStepConfig(prompt: newValue))]
				} else {
					draft.steps[0].config.prompt = newValue
				}
			})
	}

	private var modelBinding: Binding<String> {
		Binding(
			get: { draft.steps.first?.config.model ?? "" },
			set: { draft.steps.indices.contains(0) ? (draft.steps[0].config.model = $0.isEmpty ? nil : $0) : () })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(draft.name.isEmpty ? "New Command" : "Edit Command")
				.font(.title3.weight(.semibold))

			Form {
				TextField("Name", text: $draft.name)
				TextField("Trigger phrase (optional)", text: triggerBinding)
				TextField("Model (optional, e.g. gpt-5.4-mini)", text: modelBinding)
				VStack(alignment: .leading) {
					Text("Prompt").font(.caption).foregroundColor(.secondary)
					TextEditor(text: promptBinding)
						.frame(minHeight: 120)
						.font(.body.monospaced())
						.border(.quaternary)
					Text("Use {{input}} where the dictated text should go.")
						.font(.caption2)
						.foregroundColor(.secondary)
				}
			}
			.formStyle(.grouped)

			HStack {
				Spacer()
				Button("Cancel") { dismiss() }
				Button("Save") {
					onSave(draft)
					dismiss()
				}
				.buttonStyle(.borderedProminent)
				.disabled(
					draft.name.trimmingCharacters(in: .whitespaces).isEmpty
						|| promptBinding.wrappedValue.isEmpty)
			}
		}
		.padding(20)
		.frame(width: 460, height: 460)
	}

	private var triggerBinding: Binding<String> {
		Binding(
			get: { draft.triggerPhrase ?? "" },
			set: { draft.triggerPhrase = $0.isEmpty ? nil : $0 })
	}
}
