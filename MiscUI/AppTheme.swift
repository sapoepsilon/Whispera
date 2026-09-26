import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
	case system
	case light
	case dark

	static let defaultsKey = "appTheme"

	var id: String { rawValue }

	var displayName: LocalizedStringKey {
		switch self {
		case .system: return "System"
		case .light: return "Light"
		case .dark: return "Dark"
		}
	}

	var appearanceName: NSAppearance.Name? {
		switch self {
		case .system: return nil
		case .light: return .aqua
		case .dark: return .darkAqua
		}
	}

	static func stored(in defaults: UserDefaults = .standard) -> AppTheme {
		defaults.string(forKey: defaultsKey).flatMap(AppTheme.init(rawValue:)) ?? .system
	}
}

@MainActor
final class ThemeController {
	static let shared = ThemeController()

	private var defaultsObserver: DefaultsKeyObserver?
	private var lastApplied: AppTheme?

	private init() {}

	func start(defaults: UserDefaults = .standard) {
		apply(AppTheme.stored(in: defaults))
		guard defaultsObserver == nil else { return }
		defaultsObserver = DefaultsKeyObserver(defaults: defaults, keys: [AppTheme.defaultsKey]) {
			[weak self] in
			self?.apply(AppTheme.stored(in: defaults))
		}
	}

	func apply(_ theme: AppTheme) {
		guard theme != lastApplied else { return }
		lastApplied = theme
		NSApp.appearance = theme.appearanceName.flatMap(NSAppearance.init(named:))
		AppLogger.shared.ui.info("Applied app theme: \(theme.rawValue)")
	}
}

struct ThemeSettingRow: View {
	@AppStorage(AppTheme.defaultsKey) private var themeRaw = AppTheme.system.rawValue

	var body: some View {
		SettingRow("Appearance", description: "Override the system light or dark mode") {
			Picker(
				"",
				selection: Binding(
					get: { AppTheme(rawValue: themeRaw) ?? .system },
					set: { newValue in
						themeRaw = newValue.rawValue
						ThemeController.shared.apply(newValue)
					}
				)
			) {
				ForEach(AppTheme.allCases) { theme in
					Text(theme.displayName).tag(theme)
				}
			}
			.labelsHidden()
			.pickerStyle(.segmented)
			.frame(width: 200)
		}
	}
}
