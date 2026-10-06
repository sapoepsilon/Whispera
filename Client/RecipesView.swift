// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import SwiftUI

/// Settings tab for managing recipes. Create / edit / delete, and
/// load the starter set. See WHI-30. The built-in Clean up recipe (what used
/// to be the Post-Processing pane) lives here too, with its shortcut.
struct RecipesView: View {
	@State private var store = RecipeStore.shared
	@State private var editing: Recipe?
	@State private var isCreating = false
	@State private var health = RecipeRunHealth.shared
	@AppStorage(WhisperaSettings.defaultCommandIdKey) private var defaultCommandId = ""
	@AppStorage(WhisperaSettings.recipesEnabledKey) private var recipesEnabled = false
	@AppStorage(CleanUpSettings.Key.onRequestEnabled) private var cleanUpOnRequest = false
	@AppStorage(CleanUpSettings.Key.shortcut) private var cleanUpShortcut = CleanUpSettings.defaultShortcut
	@State private var isRecordingShortcut = false
	@State private var shortcutMonitor: Any?
	@State private var recorderToken: UUID?
	@State private var alert: RecipesAlert?
	@Environment(\.settingsPaneIsActive) private var isActivePane

	var body: some View {
		VStack(spacing: 0) {
			header
			enableRow
			cleanUpShortcutRow
			if recipesEnabled || cleanUpOnRequest, let failure = health.lastFailure {
				failureRow(failure)
			}

			if store.recipes.isEmpty {
				emptyState
			} else {
				defaultPicker
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
						let targets = offsets.map { store.recipes[$0] }.filter { !CleanUpRecipe.isBuiltIn($0) }
						Task { for r in targets { await store.delete(r) } }
					}
				}
				.scrollContentBackground(.hidden)
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
		// Solid content background so the header isn't the window's gray material.
		.background(Color(nsColor: .textBackgroundColor))
		.task { await store.reload() }
		.onChange(of: defaultCommandId) { _, id in WhisperaSettings.didPickDefaultCommand(id) }
		.onChange(of: isActivePane) { _, isActive in
			if !isActive { stopRecordingShortcut() }
		}
		.onDisappear(perform: stopRecordingShortcut)
		.alert(
			alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
			presenting: alert
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { alert in
			Text(alert.message)
		}
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
			Text("Recipes")
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

	/// Recipes send dictation to an LLM server, so nothing runs until the user
	/// says so — the starter set included.
	private var enableRow: some View {
		VStack(alignment: .leading, spacing: 2) {
			Toggle("Run recipes on dictation", isOn: $recipesEnabled)
				.toggleStyle(.switch)
			Text("When off, dictation is pasted exactly as you said it.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.bottom, 10)
	}

	/// Clean up on request: the shortcut (and `toggle-post-process`) runs it on
	/// one dictation even while recipes are off for every other dictation.
	private var cleanUpShortcutRow: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Toggle("Clean up with a shortcut", isOn: $cleanUpOnRequest)
					.toggleStyle(.switch)
				Spacer()
				Button(isRecordingShortcut ? String(localized: "Press keys...") : cleanUpShortcut) {
					isRecordingShortcut ? stopRecordingShortcut() : startRecordingShortcut()
				}
				.disabled(!cleanUpOnRequest)
				.accessibilityIdentifier("cleanUpShortcutButton")
			}
			Text("Dictate with this shortcut to run Clean up on that dictation only. Always uses text mode.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.bottom, 10)
	}

	private func startRecordingShortcut() {
		isRecordingShortcut = true
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = ShortcutRecorderGate.shared.begin()
		shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
			guard isRecordingShortcut else { return event }
			let modifiers = event.modifierFlags.intersection(ShortcutCombo.relevantModifiers)
			guard !modifiers.isEmpty else { return nil }
			stopRecordingShortcut()
			guard let formatted = ShortcutDisplayFormatter.format(keyCode: event.keyCode, modifiers: modifiers)
			else {
				alert = RecipesAlert(
					title: String(localized: "Shortcut not available"),
					message: String(localized: "That key can't be used in a shortcut. Try a letter, number or F-key."))
				return nil
			}
			if let conflict = CleanUpShortcutMonitor.conflictingShortcut(for: formatted) {
				alert = RecipesAlert(
					title: String(localized: "Shortcut not available"),
					message: String(localized: "\(formatted) is already used by another Whispera shortcut (\(conflict))."))
				return nil
			}
			cleanUpShortcut = formatted
			return nil
		}
	}

	private func stopRecordingShortcut() {
		isRecordingShortcut = false
		ShortcutRecorderGate.shared.end(recorderToken)
		recorderToken = nil
		if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
		shortcutMonitor = nil
	}

	/// The one place a failed recipe run is reported: the dictation itself
	/// pasted the raw transcript without a word. Cleared by the next success.
	private func failureRow(_ failure: RecipeRunHealth.Failure) -> some View {
		Label {
			Text("Last recipe run failed: \(failure.reason) — used the raw transcript")
				.font(.caption)
				.fixedSize(horizontal: false, vertical: true)
				.textSelection(.enabled)
		} icon: {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(.orange)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.bottom, 10)
		.accessibilityIdentifier("recipeLastFailure")
	}

	private var defaultPicker: some View {
		HStack {
			Text("Runs on every dictation")
				.font(.subheadline)
			Spacer()
			Picker("", selection: $defaultCommandId) {
				Text("None").tag("")
				ForEach(store.recipes) { recipe in
					Text(recipe.name.isEmpty ? "Untitled" : recipe.name).tag(recipe.id)
				}
			}
			.labelsHidden()
			.frame(maxWidth: 220)
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 10)
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "wand.and.stars")
				.font(.largeTitle)
				.foregroundColor(.secondary)
			Text("No recipes yet")
				.font(.headline)
			Text("A recipe runs an AI step on your dictation when you say its trigger phrase.")
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(40)
	}

	private func recipeRow(_ recipe: Recipe) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				Text(recipe.name.isEmpty ? "Untitled" : recipe.name)
					.font(.subheadline.weight(.medium))
				if CleanUpRecipe.isBuiltIn(recipe) {
					Text("Built-in")
						.font(.caption2)
						.padding(.horizontal, 5)
						.padding(.vertical, 1)
						.background(Capsule().fill(Color.secondary.opacity(0.15)))
						.foregroundColor(.secondary)
				}
			}
			if recipe.id == defaultCommandId {
				Text("Default · runs on every dictation")
					.font(.caption)
					.foregroundColor(.blue)
			} else if let trigger = recipe.triggerPhrase, !trigger.isEmpty {
				Text("“\(trigger)”")
					.font(.caption)
					.foregroundColor(.secondary)
			} else {
				Text("No trigger — set as default to use")
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
			Text(draft.name.isEmpty ? "New Recipe" : "Edit Recipe")
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

private struct RecipesAlert: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}
