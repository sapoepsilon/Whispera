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

	@ViewBuilder
	private var contentView: some View {
		switch audioManager.currentState {
		case .idle:
			EmptyView()
		case .initializing:
			HStack(spacing: 6) {
				ProgressView()
					.scaleEffect(0.7)
				Text("Initializing...")
					.font(.system(.caption, design: .rounded))
					.foregroundColor(.secondary)
			}
		case .transcribing:
			if whisperKit.isWaitingForModel
				|| whisperKit.isInitializing
				|| whisperKit.isModelLoading
				|| !whisperKit.isCurrentModelLoaded()
			{
				HStack(spacing: 6) {
					ProgressView()
						.scaleEffect(0.7)
					Text(
						whisperKit.isWaitingForModel
							? whisperKit.waitingForModelStatusText
							: (whisperKit.isInitializing ? whisperKit.initializationStatus : "Loading model...")
					)
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
			} else {
				Text("Transcribing...")
					.font(.system(.caption, design: .rounded))
					.foregroundColor(.secondary)
			}
		case .recording:
			HStack(spacing: 8) {
				AudioMeterView(levels: audioManager.audioLevels)
				Button(action: {
					audioManager.toggleRecording()
				}) {
					Image(systemName: "stop.circle.fill")
						.font(.system(size: 16))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help("Stop recording")
			}
		}
	}

	var body: some View {
		if #available(macOS 26.0, *) {
			contentView
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.frame(height: 30)
				.fixedSize(horizontal: true, vertical: false)
				.glassEffect()
		} else {
			contentView
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.frame(height: 50)
				.fixedSize(horizontal: true, vertical: false)
				.background(
					RoundedRectangle(cornerRadius: cornerRadius)
						.fill(.ultraThinMaterial)
				)
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
