import AppKit
import SwiftUI

struct CustomModelsSettingsView: View {
	@State var whisperKit: WhisperKitTranscriber
	@State private var store = CustomModelStore.shared
	@State private var showingHuggingFaceSheet = false
	@State private var isImporting = false
	@State private var errorMessage: String?
	@State private var pendingRemoval: CustomWhisperModel?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("Custom Models")
					.font(.subheadline)
				Spacer()
				if isImporting {
					ProgressView()
						.scaleEffect(0.5)
				}
				Button("Add from Hugging Face…") {
					showingHuggingFaceSheet = true
				}
				.disabled(whisperKit.isDownloadingModel || isImporting)
				.accessibilityIdentifier("addHuggingFaceModelButton")
				Button("Import Folder…") {
					chooseFolder()
				}
				.disabled(whisperKit.isDownloadingModel || isImporting)
				.accessibilityIdentifier("importModelFolderButton")
			}

			if store.models.isEmpty {
				Text(
					"Add a WhisperKit CoreML model from a Hugging Face repo, or import a local folder containing MelSpectrogram, AudioEncoder and TextDecoder."
				)
				.font(.caption)
				.foregroundColor(.secondary)
			} else {
				ForEach(store.models) { model in
					row(for: model)
				}
			}
		}
		.sheet(isPresented: $showingHuggingFaceSheet) {
			HuggingFaceModelSheet(whisperKit: whisperKit) { error in
				errorMessage = error
			}
		}
		.alert(
			"Custom model",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
		.alert(
			"Remove custom model?",
			isPresented: Binding(
				get: { pendingRemoval != nil },
				set: { if !$0 { pendingRemoval = nil } }
			),
			presenting: pendingRemoval
		) { model in
			Button("Remove", role: .destructive) { remove(model) }
			Button("Cancel", role: .cancel) {}
		} message: { model in
			Text("\(model.displayName) and its downloaded files will be deleted.")
		}
	}

	private func row(for model: CustomWhisperModel) -> some View {
		let available = store.isAvailable(id: model.id)
		return HStack(alignment: .top) {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(model.displayName)
						.font(.caption)
					if whisperKit.currentModel == model.id {
						Text("Loaded")
							.font(.caption2)
							.foregroundColor(.green)
					}
					if !available {
						Text("Files missing")
							.font(.caption2)
							.foregroundColor(.orange)
					}
				}
				Text(model.sourceDescription)
					.font(.caption2)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer()
			Button {
				pendingRemoval = model
			} label: {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.disabled(whisperKit.currentModel == model.id)
			.help(
				whisperKit.currentModel == model.id
					? "Switch to another model before removing this one" : "Remove")
		}
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = String(localized: "Import")
		panel.message = String(localized: "Choose a WhisperKit CoreML model folder")
		guard panel.runModal() == .OK, let url = panel.url else { return }

		isImporting = true
		Task { @MainActor in
			defer { isImporting = false }
			do {
				_ = try await whisperKit.importCustomModel(from: url)
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func remove(_ model: CustomWhisperModel) {
		Task { @MainActor in
			do {
				try await whisperKit.removeCustomModel(id: model.id)
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}

private struct HuggingFaceModelSheet: View {
	@State var whisperKit: WhisperKitTranscriber
	let onError: (String) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var repo = ""
	@State private var variant = ""
	@State private var isDownloading = false

	private var reference: HuggingFaceModelReference? {
		HuggingFaceModelReference.parse(repoInput: repo, variant: variant)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Add model from Hugging Face")
				.font(.headline)
			Text(
				"The repo must contain WhisperKit CoreML model folders. Enter the repo and the folder name, or paste a link to the folder."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			TextField("owner/repo or huggingface.co link", text: $repo)
				.textFieldStyle(.roundedBorder)
				.accessibilityIdentifier("huggingFaceRepoField")
			TextField("Model folder, e.g. openai_whisper-large-v3-v20240930_626MB", text: $variant)
				.textFieldStyle(.roundedBorder)
				.accessibilityIdentifier("huggingFaceVariantField")

			if isDownloading {
				HStack {
					ProgressView(value: whisperKit.downloadProgress)
					Text("\(Int(whisperKit.downloadProgress * 100))%")
						.font(.caption)
						.monospacedDigit()
				}
			}

			HStack {
				Spacer()
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(isDownloading)
				Button("Download") { download() }
					.keyboardShortcut(.defaultAction)
					.disabled(reference == nil || isDownloading)
			}
		}
		.padding(20)
		.frame(width: 460)
	}

	private func download() {
		isDownloading = true
		Task { @MainActor in
			defer { isDownloading = false }
			do {
				_ = try await whisperKit.addCustomModel(fromHuggingFace: repo, variant: variant)
				dismiss()
			} catch {
				dismiss()
				onError(error.localizedDescription)
			}
		}
	}
}
