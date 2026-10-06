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
	@State private var tryInput = ""
	@State private var tryOutput: String?
	@State private var isTrying = false

	var body: some View {
		Form {
			Section {
				Toggle(isOn: $recipesEnabled) {
					VStack(alignment: .leading, spacing: 2) {
						Text("Run recipes on dictation")
						Text("When off, dictation is pasted exactly as you said it.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.toggleStyle(.switch)
				Picker("Runs on every dictation", selection: $defaultCommandId) {
					Text("None").tag("")
					ForEach(store.recipes) { recipe in
						Text(verbatim: recipe.name.isEmpty ? String(localized: "Untitled") : recipe.name)
							.tag(recipe.id)
					}
				}
				.accessibilityIdentifier("recipeDefaultPicker")
				if recipesEnabled || cleanUpOnRequest, let failure = health.lastFailure {
					failureRow(failure)
				}
			}

			Section {
				Toggle(isOn: $cleanUpOnRequest) {
					VStack(alignment: .leading, spacing: 2) {
						Text("Clean up with a shortcut")
						Text("Dictate with this shortcut to run Clean up on that dictation only. Always uses text mode.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.toggleStyle(.switch)
				.accessibilityIdentifier("cleanUpShortcutToggle")
				LabeledContent("Shortcut") {
					Button(isRecordingShortcut ? String(localized: "Press keys...") : cleanUpShortcut) {
						isRecordingShortcut ? stopRecordingShortcut() : startRecordingShortcut()
					}
					.disabled(!cleanUpOnRequest)
					.accessibilityIdentifier("cleanUpShortcutButton")
				}
				tryCleanUpRows
			} header: {
				Text("Clean up")
			}

			Section {
				if store.recipes.isEmpty {
					Text("A recipe runs an AI step on your dictation when you say its trigger phrase.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				ForEach(store.recipes) { recipe in
					recipeRow(recipe)
				}
				if let error = store.lastError {
					Text(error)
						.font(.caption)
						.foregroundStyle(.red)
				}
			} header: {
				HStack {
					Text("Your recipes")
					Spacer()
					Button("Load Starter Set") { Task { await store.loadDefaults() } }
						.controlSize(.small)
					Button {
						isCreating = true
					} label: {
						Label("New", systemImage: "plus")
					}
					.controlSize(.small)
					.accessibilityIdentifier("recipeNewButton")
				}
			}
		}
		.formStyle(.grouped)
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

	/// Runs Clean up exactly as a dictation would — same pipeline, same quiet
	/// fallback to the input and the same failure report above.
	@ViewBuilder
	private var tryCleanUpRows: some View {
		TextField("Try it", text: $tryInput, prompt: Text("Paste a transcript"), axis: .vertical)
			.lineLimit(2...5)
			.accessibilityIdentifier("cleanUpTryInput")
		HStack {
			if let tryOutput {
				Text(verbatim: tryOutput)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.accessibilityIdentifier("cleanUpTryOutput")
			} else {
				Spacer()
			}
			if isTrying { ProgressView().controlSize(.small) }
			Button("Run Clean up") {
				let input = tryInput
				isTrying = true
				tryOutput = nil
				Task {
					tryOutput = await DictationCoordinator.shared.processDictation(input, cleanUp: true)?.text
					isTrying = false
				}
			}
			.disabled(isTrying || tryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			.accessibilityIdentifier("cleanUpTryButton")
		}
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
		.accessibilityIdentifier("recipeLastFailure")
	}

	private func recipeRow(_ recipe: Recipe) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(verbatim: recipe.name.isEmpty ? String(localized: "Untitled") : recipe.name)
					if CleanUpRecipe.isBuiltIn(recipe) {
						Text("Built-in")
							.font(.caption2)
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(Capsule().fill(Color.secondary.opacity(0.15)))
							.foregroundStyle(.secondary)
					}
				}
				Group {
					if recipe.id == defaultCommandId {
						Text("Runs on every dictation").foregroundStyle(.blue)
					} else if let trigger = recipe.triggerPhrase, !trigger.isEmpty {
						Text(verbatim: "“\(trigger)”")
					} else if CleanUpRecipe.isBuiltIn(recipe) {
						Text("Set it to run on every dictation, or use its shortcut")
					} else {
						Text("No trigger phrase")
					}
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			Spacer()
			Button("Edit") { editing = recipe }
				.controlSize(.small)
		}
		.contentShape(Rectangle())
		.contextMenu {
			Button("Edit") { editing = recipe }
			if !CleanUpRecipe.isBuiltIn(recipe) {
				Button("Delete", role: .destructive) { Task { await store.delete(recipe) } }
			}
		}
		.accessibilityIdentifier("recipeRow.\(recipe.name)")
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
