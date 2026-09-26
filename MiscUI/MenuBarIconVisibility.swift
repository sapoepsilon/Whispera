import SwiftUI

/// Whether the menu-bar icon shows. With it hidden, opening Whispera again (Finder,
/// Spotlight, `open -a Whispera`) brings it back until its menu closes, so Settings stays
/// reachable without the icon.
struct MenuBarIconVisibility: Equatable {
	static let defaultsKey = "showMenuBarIcon"
	static let defaultShown = true

	var settingShown: Bool
	private(set) var temporarilyRevealed = false

	init(settingShown: Bool) {
		self.settingShown = settingShown
	}

	init(defaults: UserDefaults) {
		self.init(settingShown: Self.isShown(in: defaults))
	}

	static func isShown(in defaults: UserDefaults) -> Bool {
		defaults.object(forKey: defaultsKey) as? Bool ?? defaultShown
	}

	var isVisible: Bool { settingShown || temporarilyRevealed }

	/// Called when the user reopens the app; returns true when the icon had to be revealed.
	@discardableResult
	mutating func revealForReopen() -> Bool {
		guard !isVisible else { return false }
		temporarilyRevealed = true
		return true
	}

	mutating func menuClosed() {
		temporarilyRevealed = false
	}

	mutating func updateSetting(_ shown: Bool) {
		settingShown = shown
		if shown { temporarilyRevealed = false }
	}
}

struct MenuBarIconSettingRow: View {
	@AppStorage(MenuBarIconVisibility.defaultsKey) private var showIcon = MenuBarIconVisibility.defaultShown
	@State private var confirmingHide = false

	var body: some View {
		SettingRow(
			"Show Menu Bar Icon",
			description: "When hidden, open Whispera again from Finder or Spotlight to show the icon and its menu"
		) {
			Toggle(
				"",
				isOn: Binding(
					get: { showIcon },
					set: { newValue in
						if newValue {
							showIcon = true
						} else {
							confirmingHide = true
						}
					})
			)
			.labelsHidden()
			.accessibilityIdentifier("showMenuBarIconToggle")
		}
		.alert("Hide the Menu Bar Icon?", isPresented: $confirmingHide) {
			Button("Hide Icon", role: .destructive) { showIcon = false }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text(
				"Shortcuts keep working. To get back to Settings, open Whispera again from Finder or Spotlight; the icon reappears with its menu until you close it."
			)
		}
	}
}
