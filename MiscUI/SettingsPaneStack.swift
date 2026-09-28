import SwiftUI

private struct SettingsPaneIsActiveKey: EnvironmentKey {
	static let defaultValue = true
}

extension EnvironmentValues {
	/// False while a Settings pane is kept mounted behind the selected one. Panes that start work
	/// when they appear (log tailing, history playback) use it in place of onAppear/onDisappear,
	/// which do not fire when a mounted pane is only hidden.
	var settingsPaneIsActive: Bool {
		get { self[SettingsPaneIsActiveKey.self] }
		set { self[SettingsPaneIsActiveKey.self] = newValue }
	}
}

/// Shows the selected Settings pane while keeping every pane opened so far mounted behind it, so
/// its @State and @StateObject survive switching rows.
struct SettingsPaneStack<Content: View>: View {
	let visible: [SettingsPane]
	let current: SettingsPane
	@ViewBuilder let content: (SettingsPane) -> Content

	@State private var opened: Set<SettingsPane> = []

	var body: some View {
		ZStack {
			ForEach(SettingsPane.mounted(opened: opened, current: current, visible: visible)) { pane in
				let isActive = pane == current
				content(pane)
					.environment(\.settingsPaneIsActive, isActive)
					.opacity(isActive ? 1 : 0)
					.allowsHitTesting(isActive)
					.disabled(!isActive)
					.accessibilityHidden(!isActive)
					.zIndex(isActive ? 1 : 0)
			}
		}
		.onChange(of: current) { previous, pane in
			opened.insert(previous)
			opened.insert(pane)
		}
		.onChange(of: visible) { _, panes in opened.formIntersection(panes) }
	}
}
