//
//  TestingStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//

import SwiftUI

struct TestStepView: View {
	@Bindable var audioManager: AudioManager
	@Binding var enableTranslation: Bool
	@Binding var selectedLanguage: String
	@AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "mic.badge.plus")
					.font(.system(size: 48))
					.foregroundColor(.red)

				Text("Test Your Setup")
					.font(.system(.title, design: .rounded, weight: .semibold))

				Text("Configure your language settings and test voice transcription.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)

				Text(
					"The first transcription might take longer due to the model loading on your device. Especially if it is a larger model."
				)
				.font(.callout)
				.multilineTextAlignment(.center)
			}

			VStack(spacing: 16) {
				// Language and Translation Settings
				VStack(spacing: 12) {
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text("Translation Mode")
								.font(.headline)
							Text(
								enableTranslation
									? "Translate to English" : "Transcribe in original language"
							)
							.font(.caption)
							.foregroundColor(.secondary)
						}
						Spacer()
						Toggle("", isOn: $enableTranslation)
					}
					.padding()
					.background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))

					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text("Source Language")
								.font(.headline)
							Text(
								enableTranslation
									? "Language to translate from" : "Language to transcribe"
							)
							.font(.caption)
							.foregroundColor(.secondary)
						}
						Spacer()
						Picker("Language", selection: $selectedLanguage) {
							ForEach(Constants.sortedLanguageNames, id: \.self) { language in
								Text(language.capitalized).tag(language)
							}
						}
						.frame(minWidth: 120)
					}
					.padding()
					.background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
				}

				VStack(spacing: 12) {
					Text("Press your shortcut to start recording:")
						.font(.subheadline)
						.foregroundColor(.secondary)

					Text(globalShortcut)
						.font(.system(.title, design: .monospaced, weight: .bold))
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
						.foregroundColor(.blue)
				}

				if audioManager.isRecording {
					VStack(spacing: 8) {
						HStack(spacing: 8) {
							ProgressView()
								.scaleEffect(0.8)
							Text("Recording... (press shortcut again to stop)")
								.font(.caption)
								.foregroundColor(.red)
						}
					}
				}

				if audioManager.isTranscribing {
					VStack(spacing: 8) {
						HStack(spacing: 8) {
							ProgressView()
								.scaleEffect(0.8)
							Text("Transcribing...")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				}

				if let transcription = audioManager.lastTranscription, !transcription.isEmpty {
					VStack(spacing: 12) {
						HStack(spacing: 8) {
							Image(systemName: "checkmark.circle.fill")
								.foregroundColor(.green)
							Text("Transcription Complete!")
								.font(.subheadline)
								.foregroundColor(.green)
						}

						VStack(alignment: .leading, spacing: 8) {
							Text("Transcribed Text:")
								.font(.caption)
								.foregroundColor(.secondary)

							Text(transcription)
								.font(.system(.body, design: .default))
								.padding()
								.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
								.textSelection(.enabled)
						}

						Button("Copy to Clipboard") {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(transcription, forType: .string)
						}
						.buttonStyle(SecondaryButtonStyle())
						.font(.caption)
					}
					.padding()
					.background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
				}

				if !audioManager.whisperKitTranscriber.isInitialized {
					Text("Waiting for AI framework to initialize...")
						.font(.caption)
						.foregroundColor(.orange)
				} else if !audioManager.whisperKitTranscriber.hasAnyModel() {
					Text("Please download a model first to enable transcription.")
						.font(.caption)
						.foregroundColor(.orange)
						.multilineTextAlignment(.center)
				} else {
					Text("Ready for testing! Use your global shortcut to test.")
						.font(.caption)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
				}

				// Current mode indicator
				VStack(spacing: 8) {
					if enableTranslation {
						HStack(spacing: 8) {
							Image(systemName: "arrow.right.circle.fill")
								.foregroundColor(.green)
							Text(
								"Translation Mode: \(selectedLanguage.capitalized) -> English"
							)
							.font(.caption)
							.foregroundColor(.green)
						}
					} else {
						HStack(spacing: 8) {
							Image(systemName: "doc.text.fill")
								.foregroundColor(.blue)
							Text("Transcription Mode: \(selectedLanguage.capitalized)")
								.font(.caption)
								.foregroundColor(.blue)
						}
					}
				}
				.padding()
				.background(
					(enableTranslation ? Color.green : Color.blue).opacity(0.1),
					in: RoundedRectangle(cornerRadius: 8))
			}
		}
	}
}
