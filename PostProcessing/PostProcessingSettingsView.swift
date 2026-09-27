import AppKit
import SwiftUI

struct PostProcessingSettingsView: View {
	private let settings = PostProcessingSettings()
	private let secrets: PostProcessingSecretStore = KeychainSecretStore()

	@AppStorage(PostProcessingSettings.Key.enabled) private var isEnabled = false
	@AppStorage(PostProcessingSettings.Key.applyToEveryDictation) private var applyToEveryDictation = false
	@AppStorage(PostProcessingSettings.Key.shortcut) private var shortcut = PostProcessingSettings.defaultShortcut
	@AppStorage(PostProcessingSettings.Key.providerID) private var providerID = PostProcessingSettings.defaultProviderID

	@State private var model = ""
	@State private var baseURL = ""
	@State private var apiKeyDraft = ""
	@State private var hasSavedKey = false
	@State private var fetchedModels: [String] = []
	@State private var isFetchingModels = false

	@State private var prompts: [PostProcessingPrompt] = []
	@State private var selectedPromptID = ""

	@State private var testInput = "um so i think we should uh meet at three thirty tomorrow period"
	@State private var testOutput = ""
	@State private var isTesting = false

	@State private var isRecordingShortcut = false
	@State private var shortcutMonitor: Any?
	@State private var recorderToken: UUID?
	@State private var alert: PostProcessingAlert?
	@Environment(\.settingsPaneIsActive) private var isActivePane

	private var provider: PostProcessingProvider {
		PostProcessingProvider.provider(withID: providerID) ?? PostProcessingProvider.all[0]
	}

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("Post-Processing") {
					SettingRow(
						"Enable post-processing",
						description: provider.consentText(baseURL: baseURL.isEmpty ? settings.baseURL(for: provider) : baseURL)
					) {
						Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
					}
					SettingRow("Shortcut", description: "Dictate, then post-process. Always uses text mode.") {
						Button(isRecordingShortcut ? String(localized: "Press keys...") : shortcut) {
							isRecordingShortcut ? stopRecordingShortcut() : startRecordingShortcut()
						}
						.disabled(!isEnabled)
					}
					SettingRow(
						"Post-process every dictation",
						description:
							"Also apply to the main shortcut. Live Transcription Mode types as you speak, so its sessions are never post-processed; use the shortcut above for those."
					) {
						Toggle("", isOn: $applyToEveryDictation).labelsHidden().toggleStyle(.switch)
							.disabled(!isEnabled)
					}
				}

				SettingsSection("Provider") {
					SettingRow("Provider") {
						Picker("", selection: $providerID) {
							ForEach(PostProcessingProvider.all) { provider in
								Text(provider.label).tag(provider.id)
							}
						}
						.labelsHidden()
						.frame(width: 240)
					}

					if provider.kind == .appleIntelligence {
						appleIntelligenceRows
					} else {
						openAICompatibleRows
					}
				}

				promptSection
				testSection
			}
			.padding(20)
		}
		.onAppear(perform: loadProviderState)
		.onChange(of: providerID) { _ in loadProviderState() }
		.onChange(of: prompts) { updated in settings.prompts = updated }
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
	}

	@ViewBuilder
	private var appleIntelligenceRows: some View {
		let availability = AppleIntelligenceProcessor.availability()
		SettingRow("Status", description: "Runs on this Mac. No API key and no network needed.") {
			Label(
				availability.summary,
				systemImage: availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
			)
			.foregroundColor(availability.isAvailable ? .green : .orange)
		}
	}

	@ViewBuilder
	private var openAICompatibleRows: some View {
		SettingRow("Base URL", description: provider.allowsBaseURLEdit ? "Any OpenAI-compatible endpoint." : nil) {
			TextField("https://...", text: $baseURL)
				.textFieldStyle(.roundedBorder)
				.frame(width: 260)
				.disabled(!provider.allowsBaseURLEdit)
				.onChange(of: baseURL) { url in
					if provider.allowsBaseURLEdit { settings.setBaseURL(url, for: provider.id) }
				}
		}
		if let warning = OpenAICompatibleClient.insecureKeyWarning(baseURL: baseURL, hasKey: hasSavedKey)
			?? OpenAICompatibleClient.insecureTranscriptWarning(baseURL: baseURL)
		{
			Label(warning, systemImage: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundColor(.orange)
				.fixedSize(horizontal: false, vertical: true)
		}

		SettingRow(
			"API key",
			description: hasSavedKey
				? "Saved in your Keychain."
				: (provider.requiresAPIKey ? "Required. Stored in your Keychain." : "Optional for local servers.")
		) {
			HStack {
				SecureField(hasSavedKey ? "Replace saved key" : "Paste key", text: $apiKeyDraft)
					.textFieldStyle(.roundedBorder)
					.frame(width: 160)
				Button("Save") { saveKey(apiKeyDraft) }
					.disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
				if hasSavedKey {
					Button("Remove") { saveKey(nil) }
				}
			}
		}

		SettingRow("Model") {
			HStack {
				TextField("model id", text: $model)
					.textFieldStyle(.roundedBorder)
					.frame(width: 180)
					.onChange(of: model) { id in
						if provider.kind == .openAICompatible { settings.setModel(id, for: provider.id) }
					}
				if !fetchedModels.isEmpty {
					Menu("Pick") {
						ForEach(fetchedModels, id: \.self) { id in
							Button(id) { model = id }
						}
					}
					.frame(width: 60)
				}
				Button {
					fetchModels()
				} label: {
					if isFetchingModels {
						ProgressView().controlSize(.small)
					} else {
						Text("Fetch")
					}
				}
				.disabled(isFetchingModels)
			}
		}
	}

	private var promptSection: some View {
		SettingsSection("Prompt") {
			SettingRow("Active prompt") {
				HStack {
					Picker("", selection: $selectedPromptID) {
						ForEach(prompts) { prompt in
							Text(prompt.name).tag(prompt.id)
						}
					}
					.labelsHidden()
					.frame(width: 200)
					.onChange(of: selectedPromptID) { id in settings.selectedPromptID = id }
					Button("Add") { addPrompt() }
					Button("Delete") { deletePrompt() }
						.disabled(prompts.count <= 1)
				}
			}
			if let index = prompts.firstIndex(where: { $0.id == selectedPromptID }) {
				TextField("Name", text: $prompts[index].name)
					.textFieldStyle(.roundedBorder)
				TextEditor(text: $prompts[index].template)
					.font(.system(.body, design: .monospaced))
					.frame(minHeight: 180)
					.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
				Text("${output} is replaced with the transcript. Without it, the prompt becomes the instructions.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}

	private var testSection: some View {
		SettingsSection("Try It") {
			TextField("Sample transcript", text: $testInput, axis: .vertical)
				.textFieldStyle(.roundedBorder)
				.lineLimit(2...4)
			HStack {
				Button("Run") { runTest() }
					.disabled(isTesting || testInput.isEmpty)
				if isTesting { ProgressView().controlSize(.small) }
				Spacer()
			}
			if !testOutput.isEmpty {
				Text(testOutput)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
					.background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
			}
		}
	}

	private func loadProviderState() {
		model = settings.model(for: provider.id)
		baseURL = settings.baseURL(for: provider)
		apiKeyDraft = ""
		fetchedModels = []
		hasSavedKey = provider.kind == .openAICompatible && ((try? secrets.hasAPIKey(for: provider.id)) ?? false)
		if prompts.isEmpty {
			prompts = settings.prompts
			selectedPromptID = settings.selectedPromptID
		}
	}

	private func saveKey(_ key: String?) {
		do {
			try secrets.setAPIKey(key, for: provider.id)
			apiKeyDraft = ""
			hasSavedKey = key != nil
			AppLogger.shared.general.info("Post-processing API key \(key == nil ? "removed" : "saved") for \(provider.id)")
		} catch {
			alert = PostProcessingAlert(
				title: String(localized: "Could not update the Keychain"), message: error.localizedDescription)
		}
	}

	private func fetchModels() {
		isFetchingModels = true
		let provider = self.provider
		let settings = self.settings
		let secrets = self.secrets
		Task { @MainActor in
			defer { isFetchingModels = false }
			do {
				let client = OpenAICompatibleClient(
					baseURL: settings.baseURL(for: provider), apiKey: try secrets.apiKey(for: provider.id), model: "",
					timeout: settings.timeoutSeconds)
				fetchedModels = try await client.listModels()
				if fetchedModels.isEmpty {
					alert = PostProcessingAlert(
						title: String(localized: "No models"),
						message: String(localized: "The provider returned an empty model list."))
				}
			} catch {
				alert = PostProcessingAlert(
					title: String(localized: "Could not fetch models"), message: error.localizedDescription)
			}
		}
	}

	private func runTest() {
		isTesting = true
		testOutput = ""
		let input = testInput
		Task { @MainActor in
			defer { isTesting = false }
			switch await PostProcessingService().process(input) {
			case .processed(let text):
				testOutput = text
			case .skipped:
				testOutput = ""
			case .failed(_, let error):
				alert = PostProcessingAlert(title: String(localized: "Post-processing failed"), message: error)
			}
		}
	}

	private func addPrompt() {
		let prompt = PostProcessingPrompt(
			id: UUID().uuidString, name: String(localized: "New prompt"),
			template: PostProcessingPrompt.defaultCleanup.template)
		prompts.append(prompt)
		selectedPromptID = prompt.id
		settings.prompts = prompts
	}

	private func deletePrompt() {
		guard prompts.count > 1 else { return }
		prompts.removeAll { $0.id == selectedPromptID }
		selectedPromptID = prompts[0].id
		settings.prompts = prompts
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
			guard let formatted = PostProcessingShortcutFormatter.format(keyCode: event.keyCode, modifiers: modifiers)
			else {
				alert = PostProcessingAlert(
					title: String(localized: "Shortcut not available"),
					message: String(localized: "That key can't be used in a shortcut. Try a letter, number or F-key."))
				return nil
			}
			if let conflict = PostProcessShortcutMonitor.conflictingShortcut(for: formatted) {
				alert = PostProcessingAlert(
					title: String(localized: "Shortcut not available"),
					message: String(localized: "\(formatted) is already used by another Whispera shortcut (\(conflict))."))
				return nil
			}
			shortcut = formatted
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
}

struct PostProcessingAlert: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}

enum PostProcessingShortcutFormatter {
	/// Produces the symbol string `ShortcutCombo` reads back to the same key code. The key is
	/// named from its key code, so Shift never turns "1" into "!" and F-keys keep their names.
	/// Nil when there are no modifiers or the key has no name.
	static func format(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
		let flags = modifiers.intersection(ShortcutCombo.relevantModifiers)
		guard !flags.isEmpty, let key = ShortcutKeyCodes.keyName(forKeyCode: keyCode) else { return nil }
		return format(modifiers: flags, key: key)
	}

	static func format(modifiers: NSEvent.ModifierFlags, key: String) -> String {
		var parts = ""
		if modifiers.contains(.command) { parts += "⌘" }
		if modifiers.contains(.option) { parts += "⌥" }
		if modifiers.contains(.control) { parts += "⌃" }
		if modifiers.contains(.shift) { parts += "⇧" }
		return parts + key
	}
}
