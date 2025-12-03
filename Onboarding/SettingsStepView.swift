//
//  SettingsStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//

import SwiftUI

struct SettingsStepView: View {
	@Binding var launchAtLogin: Bool

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "gear.circle.fill")
					.font(.system(size: 48))
					.foregroundColor(.blue)

				Text("App Settings")
					.font(.system(.title, design: .rounded, weight: .semibold))

				Text("Configure how Whispera behaves on your system.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}

			VStack(spacing: 16) {
				SettingRowView(
					icon: "power",
					title: "Launch at Login",
					description: "Start Whispera automatically when you log in",
					isOn: $launchAtLogin
				)
			}
		}
	}
}
