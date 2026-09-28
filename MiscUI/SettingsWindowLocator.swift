import AppKit

/// Finds the SwiftUI Settings window without relying on its title, which follows the selected
/// section and is translated once the app runs in Spanish, German or French.
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

/// Decides how a Settings request is served so it never ends with two Settings windows: an open
/// (even minimized) window is brought back, and the retained fallback only opens once the SwiftUI
/// scene has clearly not appeared.
enum SettingsWindowOpening {
	struct WindowState: Equatable {
		var isVisible: Bool
		var isMiniaturized: Bool

		var isOpen: Bool { isVisible || isMiniaturized }
	}

	enum Step: Equatable {
		case revealScene
		case revealRetained
		case requestScene
		case openRetained
		case wait
	}

	/// Checks happen this often after asking SwiftUI for the scene.
	static let checkInterval: TimeInterval = 0.2
	/// With no scene window at all after this many checks, the openSettings action no-oped.
	static let noSceneChecks = 2
	/// A scene window that exists but is still coming up gets this many checks.
	static let maxChecks = 12

	static func firstStep(scene: WindowState?, retained: WindowState?, canRequestScene: Bool) -> Step {
		if scene?.isOpen == true { return .revealScene }
		if retained?.isOpen == true { return .revealRetained }
		return canRequestScene ? .requestScene : .openRetained
	}

	static func stepAfterRequest(scene: WindowState?, check: Int) -> Step {
		if scene?.isOpen == true { return .revealScene }
		if scene == nil, check >= noSceneChecks { return .openRetained }
		return check >= maxChecks ? .openRetained : .wait
	}
}
