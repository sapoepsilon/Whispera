import Foundation

/// A dictation command that can arrive from outside the app: the whispera:// URL scheme,
/// App Intents (Shortcuts, Spotlight, Stream Deck), launchers, or the headless CLI.
enum RemoteCommand: Equatable, Sendable {
	case toggle
	case start
	case stop
	case cancel
	case setLanguage(String)
	case setModel(String)

	static let scheme = "whispera"

	init?(url: URL) {
		guard url.scheme?.lowercased() == Self.scheme else { return nil }

		// whispera://toggle carries the verb in the host; whispera:toggle and
		// whispera:///toggle carry it in the path, so accept all three spellings.
		let hostVerb = url.host?.trimmingCharacters(in: .whitespaces) ?? ""
		let pathVerb = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let verb = (hostVerb.isEmpty ? pathVerb : hostVerb).lowercased()

		let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		func value(_ names: String...) -> String? {
			for name in names {
				if let raw = queryItems.first(where: { $0.name.lowercased() == name })?.value {
					let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
					if !trimmed.isEmpty { return trimmed }
				}
			}
			return nil
		}

		switch verb {
		case "toggle": self = .toggle
		case "start": self = .start
		case "stop": self = .stop
		case "cancel": self = .cancel
		case "language":
			guard let language = value("name", "code") else { return nil }
			self = .setLanguage(language)
		case "model":
			guard let model = value("name") else { return nil }
			self = .setModel(model)
		default:
			return nil
		}
	}

	var url: URL {
		var components = URLComponents()
		components.scheme = Self.scheme
		switch self {
		case .toggle: components.host = "toggle"
		case .start: components.host = "start"
		case .stop: components.host = "stop"
		case .cancel: components.host = "cancel"
		case .setLanguage(let language):
			components.host = "language"
			components.queryItems = [URLQueryItem(name: "name", value: language)]
		case .setModel(let model):
			components.host = "model"
			components.queryItems = [URLQueryItem(name: "name", value: model)]
		}
		return components.url!
	}

	var logDescription: String {
		switch self {
		case .toggle: return "toggle"
		case .start: return "start"
		case .stop: return "stop"
		case .cancel: return "cancel"
		case .setLanguage(let language): return "language(\(language))"
		case .setModel(let model): return "model(\(model))"
		}
	}

	/// Resolves a language given as a name ("German") or a Whisper code ("de") to the
	/// lowercase name stored under the `selectedLanguage` default.
	static func resolveLanguageName(_ input: String) -> String? {
		let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !normalized.isEmpty else { return nil }
		if Constants.languages[normalized] != nil {
			return normalized
		}
		return Constants.languages.first { $0.value == normalized }?.key
	}
}

enum RemoteCommandSource: String, Sendable {
	case url
	case intent
	case cli
}

enum RemoteControlSettings {
	static let urlSchemeEnabledKey = "remoteControlURLSchemeEnabled"

	/// URL control defaults to on: browsers already confirm before handing a custom
	/// scheme to an app, and dictation is always visible through the pill and sounds.
	static func isURLSchemeEnabled(in defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: urlSchemeEnabledKey) as? Bool ?? true
	}
}
