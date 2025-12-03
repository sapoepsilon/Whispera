//
//  CompleteStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//

import SwiftUI

struct CompleteStepView: View {
	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 64))
					.foregroundColor(.green)

				Text("You're All Set!")
					.font(.system(.largeTitle, design: .rounded, weight: .bold))

				Text("Whispera is now configured and ready to use.")
					.font(.title3)
					.foregroundColor(.secondary)
			}

			VStack(spacing: 16) {
				Text("Quick Tips:")
					.font(.headline)

				VStack(alignment: .leading, spacing: 8) {
					Text("• Press your shortcut from anywhere to start recording")
					Text("• Click the menu bar icon to see recent transcriptions")
					Text("• Visit Settings to customize models and shortcuts")
					Text("• Your voice data never leaves your Mac")
				}
				.font(.subheadline)
				.foregroundColor(.secondary)
			}
			.padding()
			.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
		}
	}
}
