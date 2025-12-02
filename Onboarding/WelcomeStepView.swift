//
//  WelcomeStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct WelcomeStepView: View {
	var body: some View {
		VStack(spacing: 24) {
			// App icon and title
			VStack(spacing: 16) {
				Image(systemName: "waveform.circle.fill")
					.font(.system(size: 64))
					.foregroundColor(.blue)

				VStack(spacing: 8) {
					Text("Welcome to Whispera")
						.font(.system(.largeTitle, design: .rounded, weight: .bold))

					Text("Whisper-powered voice transcription for macOS")
						.font(.title3)
						.foregroundColor(.secondary)
				}
			}

			// Feature highlights
			VStack(spacing: 16) {
				FeatureRowView(
					icon: "mic.fill",
					title: "Global Voice Recording",
					description: "Record from anywhere with a keyboard shortcut"
				)

				FeatureRowView(
					icon: "brain.head.profile",
					title: "AI-Powered Transcription",
					description: "Local processing with OpenAI Whisper models"
				)

				FeatureRowView(
					icon: "lock.shield",
					title: "Privacy First",
					description: "Everything stays on your Mac - no cloud required"
				)

				FeatureRowView(
					icon: "speedometer",
					title: "Lightning Fast",
					description: "Optimized for Apple Silicon and Intel Macs"
				)
			}

			Text("Let's get you set up in just a few steps!")
				.font(.headline)
				.foregroundColor(.primary)
				.padding(.top, 8)
		}
	}
}
