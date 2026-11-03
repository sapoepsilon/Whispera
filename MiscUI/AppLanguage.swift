import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
	case system
	case english = "en"
	case spanish = "es"
	case german = "de"
	case french = "fr"

	static let defaultsKey = "appLanguage"
	static let appleLanguagesKey = "AppleLanguages"

	var id: String { rawValue }

	// Language names stay in their own language so a user can always find theirs.
	var displayName: String {
		switch self {
		case .system: return String(localized: "System Default")
		case .english: return "English"
		case .spanish: return "Español"
		case .german: return "Deutsch"
		case .french: return "Français"
		}
	}

	static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
		defaults.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
	}

	// AppleLanguages in the app's own domain is what Bundle consults at launch, so the
	// override takes effect on the next start without touching the system-wide list.
	static func store(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
		defaults.set(language.rawValue, forKey: defaultsKey)
		if language == .system {
			defaults.removeObject(forKey: appleLanguagesKey)
		} else {
			defaults.set([language.rawValue], forKey: appleLanguagesKey)
		}
	}

	/// Arguments for `/bin/sh` that start the app again once `pid` has exited. Waiting on the
	/// process instead of a fixed delay matters because a new copy launched while this one is
	/// still quitting hits the single-instance check and quits too, leaving nothing running.
	/// If this process is still alive after `timeoutTicks` tenths of a second (termination was
	/// cancelled), the app never quit, so nothing is opened.
	static func relaunchArguments(
		bundlePath: String, pid: Int32, opener: String = "/usr/bin/open", timeoutTicks: Int = 600
	) -> [String] {
		let script = """
			i=0
			while [ "$i" -lt "$3" ]; do
			  kill -0 "$1" 2>/dev/null || exec "$2" "$0"
			  sleep 0.1
			  i=$((i + 1))
			done
			exit 1
			"""
		return ["-c", script, bundlePath, String(pid), opener, String(timeoutTicks)]
	}

	static func relaunch() {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = relaunchArguments(
			bundlePath: Bundle.main.bundleURL.path, pid: ProcessInfo.processInfo.processIdentifier)
		do {
			try process.run()
			AppLogger.shared.general.info("Relaunching to apply the app language")
			NSApp.terminate(nil)
		} catch {
			AppLogger.shared.general.error("Failed to relaunch for language change: \(error)")
		}
	}
}

struct AppLanguageSettingRow: View {
	@State private var language = AppLanguage.stored()
	@State private var pendingRelaunch = false

	var body: some View {
		SettingRow("App Language", description: "Language used for Whispera's menus and settings") {
			Picker("App Language", selection: $language) {
				ForEach(AppLanguage.allCases) { language in
					Text(verbatim: language.displayName).tag(language)
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)
			.frame(width: 180, alignment: .trailing)
			.onChange(of: language) { _, newValue in
				AppLanguage.store(newValue)
				pendingRelaunch = true
			}
		}
		.alert("Relaunch Whispera?", isPresented: $pendingRelaunch) {
			Button("Relaunch Now") {
				AppLanguage.relaunch()
			}
			Button("Later", role: .cancel) {}
		} message: {
			Text("The new language is used after Whispera restarts.")
		}
	}
}
