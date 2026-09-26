import AppKit

/// Finds the SwiftUI Settings window without relying on its title, which follows the selected
/// tab and is translated once the app runs in Spanish, German or French.
enum SettingsWindowLocator {
	static let swiftUIIdentifier = "com_apple_SwiftUI_Settings_window"
	/// The fallback window AppDelegate hosts when the SwiftUI openSettings action no-ops.
	static let retainedIdentifier = "whispera.settings.retained"

	private static let englishTitles = [
		"Settings", "Preferences", "General", "Storage & Downloads", "File Transcription",
	]

	static func isSettingsWindow(identifier: String?, title: String, className: String) -> Bool {
		if identifier == swiftUIIdentifier || identifier == retainedIdentifier || className.contains("Settings") {
			return true
		}
		let localizedTitles = englishTitles.map { String(localized: String.LocalizationValue($0)) }
		return (englishTitles + localizedTitles).contains { title.localizedCaseInsensitiveContains($0) }
	}

	static func isSettingsWindow(_ window: NSWindow) -> Bool {
		isSettingsWindow(
			identifier: window.identifier?.rawValue, title: window.title,
			className: String(describing: type(of: window)))
	}

	static func find() -> NSWindow? {
		NSApp.windows.first(where: isSettingsWindow)
	}
}
