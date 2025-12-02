//
//  SettingsRowView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct SettingRowView: View {
	let icon: String
	let title: String
	let description: String
	@Binding var isOn: Bool

	var body: some View {
		HStack(spacing: 16) {
			ZStack {
				Circle()
					.fill(.blue.opacity(0.2))
					.frame(width: 40, height: 40)

				Image(systemName: icon)
					.font(.system(size: 18))
					.foregroundColor(.blue)
			}

			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.system(.subheadline, design: .rounded, weight: .medium))
				Text(description)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()

			Toggle("", isOn: $isOn)
				.labelsHidden()
		}
		.padding()
		.background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
	}
}
