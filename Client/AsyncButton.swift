// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

/// Button for async work: runs the action off the UI, shows the standard
/// spinner while pending, disables itself, and cancels if the view goes away.
/// Use for anything awaiting a network or device operation so the main UI
/// never waits on it. WHI-54.
struct AsyncButton<Label: View>: View {
	private let action: () async -> Void
	private let label: () -> Label
	@State private var task: Task<Void, Never>?

	init(action: @escaping () async -> Void, @ViewBuilder label: @escaping () -> Label) {
		self.action = action
		self.label = label
	}

	private var isRunning: Bool { task != nil }

	var body: some View {
		Button {
			guard task == nil else { return }
			task = Task {
				await action()
				task = nil
			}
		} label: {
			HStack(spacing: 6) {
				if isRunning {
					ProgressView()
						.scaleEffect(0.6)
				}
				label()
			}
		}
		.disabled(isRunning)
		.onDisappear {
			task?.cancel()
			task = nil
		}
	}
}

extension AsyncButton where Label == Text {
	init(_ title: String, action: @escaping () async -> Void) {
		self.init(action: action) { Text(title) }
	}
}
