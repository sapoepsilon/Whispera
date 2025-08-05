//
//  ShortcutsStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct ShortcutStepView: View {
	@Binding var customShortcut: String
	@Binding var showingShortcutCapture: Bool
	@State private var isCapturing = false
	@State private var fileSelectionShortcut = "⌃F"
	@State private var showingFileShortcutCapture = false
	
	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "keyboard")
					.font(.system(size: 48))
					.foregroundColor(.purple)
				
				Text("Set Your Shortcuts")
					.font(.system(.title, design: .rounded, weight: .semibold))
				
				Text("Choose keyboard shortcuts to quickly start recording or transcribe files from anywhere.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			
			VStack(spacing: 20) {
				// Recording shortcut
				VStack(spacing: 12) {
					Text("Recording shortcut:")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					HStack {
						Text(customShortcut)
							.font(.system(.title2, design: .monospaced, weight: .semibold))
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
						
						Button("Change") {
							showShortcutOptions()
						}
						.buttonStyle(SecondaryButtonStyle())
					}
					
					if showingShortcutCapture {
						ShortcutOptionsView(customShortcut: $customShortcut, showingOptions: $showingShortcutCapture)
					}
				}
				
				// File selection shortcut
				VStack(spacing: 12) {
					Text("File transcription shortcut:")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					HStack {
						Text(fileSelectionShortcut)
							.font(.system(.title2, design: .monospaced, weight: .semibold))
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
						
						Button("Change") {
							showFileShortcutOptions()
						}
						.buttonStyle(SecondaryButtonStyle())
					}
					
					if showingFileShortcutCapture {
						ShortcutOptionsView(customShortcut: $fileSelectionShortcut, showingOptions: $showingFileShortcutCapture)
					}
				}
				
				Text("You can change these later in Settings")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}
	
	private func showShortcutOptions() {
		showingShortcutCapture.toggle()
	}
	
	private func showFileShortcutOptions() {
		showingFileShortcutCapture.toggle()
	}
}

