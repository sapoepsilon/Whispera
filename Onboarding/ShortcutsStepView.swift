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
	
	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "keyboard")
					.font(.system(size: 48))
					.foregroundColor(.purple)
				
				Text("Set Your Shortcut")
					.font(.system(.title, design: .rounded, weight: .semibold))
				
				Text("Choose a keyboard shortcut to quickly start recording from anywhere.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			
			VStack(spacing: 16) {
				Text("Current shortcut:")
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
				
				Text("You can change this later in Settings")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}
	
	private func showShortcutOptions() {
		showingShortcutCapture.toggle()
	}
}
