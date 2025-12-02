//
//  ListeningView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 10/18/25.
//

import SwiftUI

struct ListeningView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	@AppStorage("listeningViewCornerRadius") private var cornerRadius = 10.0
	private let audioManager: AudioManager

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
	}

	var body: some View {
		if #available(macOS 26.0, *) {
			HStack(spacing: 6) {
				if audioManager.isTranscribing {
					Text("Transcribing...")
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
				} else {
					AudioMeterView(levels: audioManager.audioLevels)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.frame(width: 100, height: 30)
			.glassEffect()
		} else {
			HStack(spacing: 6) {
				if audioManager.isTranscribing {
					Text("Transcribing...")
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
				} else {
					AudioMeterView(levels: audioManager.audioLevels)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.frame(width: 100, height: 50)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						LinearGradient(
							colors: [
								Color.blue.opacity(0.3),
								Color.blue.opacity(0.1),
							],
							startPoint: .topLeading,
							endPoint: .bottomTrailing
						),
						lineWidth: 1
					)
			)
			.shadow(color: Color.blue.opacity(0.1), radius: 8, x: 0, y: 2)
			.shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
		}

	}
}

#Preview {
	ListeningView(audioManager: AudioManager())
		.frame(width: 200, height: 60)
}
