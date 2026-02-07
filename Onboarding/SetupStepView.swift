import SwiftUI

struct SetupStepView: View {
	@Binding var selectedModel: String
	@Binding var customShortcut: String
	@Binding var launchAtLogin: Bool
	@Bindable var audioManager: AudioManager

	@State private var availableModels: [String] = []
	@State private var isLoadingModels = false
	@State private var loadingError: String?
	@State private var errorMessage: String?
	@State private var showingError = false
	@State private var showingShortcutCapture = false
	@State private var fileSelectionShortcut = "⌃F"
	@State private var showingFileShortcutCapture = false
	@State private var showSections = [false, false, false]

	var body: some View {
		ScrollView {
			VStack(spacing: 16) {
				VStack(spacing: 8) {
					Text("Configure Whispera")
						.font(.system(.title2, design: .rounded, weight: .bold))

					Text("Set up your model, shortcuts, and preferences.")
						.font(.body)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
				}
				.padding(.bottom, 8)

				modelSection
					.opacity(showSections[0] ? 1 : 0)
					.offset(y: showSections[0] ? 0 : 10)

				shortcutsSection
					.opacity(showSections[1] ? 1 : 0)
					.offset(y: showSections[1] ? 0 : 10)

				preferencesSection
					.opacity(showSections[2] ? 1 : 0)
					.offset(y: showSections[2] ? 0 : 10)
			}
			.padding(.horizontal, 40)
			.padding(.vertical, 24)
		}
		.onAppear {
			loadAvailableModels()
			animateSectionsIn()
		}
		.onChange(of: selectedModel) { _, newModel in
			downloadModelIfNeeded(newModel)
		}
		.alert("Error", isPresented: $showingError) {
			Button("OK") {
				showingError = false
				errorMessage = nil
			}
		} message: {
			Text(errorMessage ?? "An unknown error occurred")
		}
	}

	// MARK: - Model Section

	private var modelSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeader(icon: "brain.head.profile", title: "AI Model")

			HStack {
				if isLoadingModels || audioManager.whisperKitTranscriber.isModelLoading {
					HStack(spacing: 8) {
						ProgressView()
							.scaleEffect(0.8)
						Text(modelStatusText)
							.font(.caption)
							.foregroundColor(.secondary)
					}
				} else {
					VStack(alignment: .leading, spacing: 4) {
						Picker("Model", selection: $selectedModel) {
							ForEach(modelOptions, id: \.0) { model in
								Text(model.1).tag(model.0)
							}
						}
						.frame(minWidth: 220)

						if needsModelLoad {
							Button("Load Model") {
								Task {
									do {
										try await audioManager.whisperKitTranscriber
											.switchModel(to: selectedModel)
									} catch {
										errorMessage =
											"Failed to load model: \(error.localizedDescription)"
										showingError = true
									}
								}
							}
							.buttonStyle(.borderedProminent)
							.controlSize(.small)
						}
					}
				}

				Spacer()
			}

			if let error = loadingError {
				Text("Error: \(error)")
					.font(.caption)
					.foregroundColor(.red)
			}

			if audioManager.whisperKitTranscriber.isDownloadingModel {
				VStack(spacing: 6) {
					HStack(spacing: 8) {
						ProgressView()
							.scaleEffect(0.7)
						Text(
							"Downloading \(audioManager.whisperKitTranscriber.downloadingModelName ?? "model")..."
						)
						.font(.caption)
						.foregroundColor(.blue)
					}
					ProgressView(value: audioManager.whisperKitTranscriber.downloadProgress)
						.frame(height: 4)
				}
				.padding(10)
				.background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
			}

			Text(
				"Base is fast and accurate for most use cases, small provides better accuracy for complex speech."
			)
			.font(.caption)
			.foregroundColor(.secondary)
		}
		.sectionCard()
	}

	// MARK: - Shortcuts Section

	private var shortcutsSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeader(icon: "keyboard", title: "Keyboard Shortcuts")

			VStack(spacing: 12) {
				shortcutRow(
					label: "Recording",
					shortcut: $customShortcut,
					showingCapture: $showingShortcutCapture,
					tint: .purple
				)

				if showingShortcutCapture {
					ShortcutOptionsView(
						customShortcut: $customShortcut,
						showingOptions: $showingShortcutCapture
					)
				}

				Divider()

				shortcutRow(
					label: "File transcription",
					shortcut: $fileSelectionShortcut,
					showingCapture: $showingFileShortcutCapture,
					tint: .blue
				)

				if showingFileShortcutCapture {
					ShortcutOptionsView(
						customShortcut: $fileSelectionShortcut,
						showingOptions: $showingFileShortcutCapture
					)
				}
			}
		}
		.sectionCard()
	}

	// MARK: - Preferences Section

	private var preferencesSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeader(icon: "gear", title: "Preferences")

			SettingRowView(
				icon: "power",
				title: "Launch at Login",
				description: "Start Whispera automatically when you log in",
				isOn: $launchAtLogin
			)
		}
		.sectionCard()
	}

	// MARK: - Helpers

	private func sectionHeader(icon: String, title: String) -> some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
				.font(.system(size: 12, weight: .semibold))
				.foregroundColor(.blue)
			Text(title)
				.font(.system(.subheadline, design: .rounded, weight: .semibold))
		}
	}

	private func shortcutRow(
		label: String,
		shortcut: Binding<String>,
		showingCapture: Binding<Bool>,
		tint: Color
	) -> some View {
		HStack {
			Text(label)
				.font(.system(.subheadline, design: .rounded))
				.foregroundColor(.secondary)

			Spacer()

			Text(shortcut.wrappedValue)
				.font(.system(.body, design: .monospaced, weight: .semibold))
				.padding(.horizontal, 12)
				.padding(.vertical, 6)
				.background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

			Button("Change") {
				showingCapture.wrappedValue.toggle()
			}
			.buttonStyle(SecondaryButtonStyle())
			.controlSize(.small)
		}
	}

	private func animateSectionsIn() {
		for i in 0..<3 {
			withAnimation(.spring(duration: 0.4, bounce: 0.15).delay(Double(i) * 0.1)) {
				showSections[i] = true
			}
		}
	}

	// MARK: - Model Logic

	private var needsModelLoad: Bool {
		guard !selectedModel.isEmpty else { return false }
		guard audioManager.whisperKitTranscriber.isInitialized else { return false }
		guard
			!audioManager.whisperKitTranscriber.isDownloadingModel
				&& !audioManager.whisperKitTranscriber.isModelLoading
		else { return false }
		return selectedModel != audioManager.whisperKitTranscriber.currentModel
	}

	private var modelStatusText: String {
		if isLoadingModels { return "Loading models..." }
		if audioManager.whisperKitTranscriber.isModelLoading {
			return "Loading \(selectedModel)..."
		}
		return ""
	}

	private var modelOptions: [(String, String)] {
		if availableModels.isEmpty {
			return [("loading", "Loading models...")]
		}
		return availableModels.compactMap { model in
			(model, WhisperKitTranscriber.getModelDisplayName(for: model))
		}
	}

	private func loadAvailableModels() {
		isLoadingModels = true
		loadingError = nil

		Task {
			do {
				try await audioManager.whisperKitTranscriber.refreshAvailableModels()
				let fetchedModels = audioManager.whisperKitTranscriber.availableModels

				availableModels = fetchedModels.sorted { lhs, rhs in
					WhisperKitTranscriber.getModelPriority(for: lhs)
						< WhisperKitTranscriber.getModelPriority(for: rhs)
				}
				isLoadingModels = false

				if selectedModel.isEmpty || !fetchedModels.contains(selectedModel) {
					if let smallModel = fetchedModels.first(where: {
						$0.contains("small") && !$0.contains(".en")
					}) {
						selectedModel = smallModel
					} else if let firstModel = fetchedModels.first {
						selectedModel = firstModel
					} else {
						selectedModel = "openai_whisper-small"
					}
				}
			} catch {
				loadingError = error.localizedDescription
				errorMessage = "Failed to load available models: \(error.localizedDescription)"
				showingError = true
				isLoadingModels = false
				availableModels = [
					"openai_whisper-tiny.en",
					"openai_whisper-base.en",
					"openai_whisper-small.en",
				]
				if selectedModel.isEmpty {
					if let smallModel = availableModels.first(where: {
						$0.contains("small") && !$0.contains(".en")
					}) {
						selectedModel = smallModel
					} else if let firstModel = availableModels.first {
						selectedModel = firstModel
					} else {
						selectedModel = "openai_whisper-small"
					}
				}
			}
		}
	}

	private func downloadModelIfNeeded(_ modelId: String) {
		guard
			!audioManager.whisperKitTranscriber.downloadedModels.contains(modelId)
				&& !audioManager.whisperKitTranscriber.isDownloadingModel
		else { return }

		Task {
			do {
				try await audioManager.whisperKitTranscriber.downloadModel(modelId)
			} catch {
				loadingError = "Failed to download model: \(error.localizedDescription)"
				errorMessage = "Failed to download model: \(error.localizedDescription)"
				showingError = true
			}
		}
	}
}

private extension View {
	func sectionCard() -> some View {
		self
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
	}
}
