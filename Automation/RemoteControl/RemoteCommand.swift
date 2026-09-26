import Foundation
import Security

/// A dictation command that can arrive from outside the app: the whispera:// URL scheme,
/// App Intents (Shortcuts, Spotlight, Stream Deck), launchers, or the headless CLI.
enum RemoteCommand: Equatable, Sendable {
	case toggle
	/// Toggles dictation and runs the finished transcript through LLM post-processing.
	case togglePostProcess
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
		case "toggle-post-process": self = .togglePostProcess
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

	var url: URL { url(token: nil) }

	/// Commands that can open the microphone or change the loaded model. Over the URL scheme
	/// they need the per-install token, because any web page or app can open a whispera:// link.
	var requiresToken: Bool {
		switch self {
		case .toggle, .togglePostProcess, .start, .setModel: return true
		case .stop, .cancel, .setLanguage: return false
		}
	}

	/// Stop and cancel only act on a session the user already started, so any link may send them.
	var isAlwaysAllowedFromURL: Bool {
		switch self {
		case .stop, .cancel: return true
		default: return false
		}
	}

	static let tokenQueryName = "token"

	static func token(in url: URL) -> String? {
		URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
			.first { $0.name.lowercased() == tokenQueryName }?.value
	}

	func url(token: String?) -> URL {
		var components = URLComponents()
		components.scheme = Self.scheme
		switch self {
		case .toggle: components.host = "toggle"
		case .togglePostProcess: components.host = "toggle-post-process"
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
		if let token, requiresToken {
			components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: Self.tokenQueryName, value: token)]
		}
		return components.url!
	}

	var logDescription: String {
		switch self {
		case .toggle: return "toggle"
		case .togglePostProcess: return "toggle-post-process"
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

	static let urlSchemeEnabledDefault = false

	/// Off by default: a browser's "always allow" or any local app, sandboxed or not, can open a
	/// whispera:// link without a prompt, which would let it record through Whispera's mic grant.
	static func isURLSchemeEnabled(in defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: urlSchemeEnabledKey) as? Bool ?? urlSchemeEnabledDefault
	}
}

/// A random secret stored in a user-only file. Links that open the mic must carry it, so only
/// processes that can read the user's Application Support (the CLI, exported scripts, anything
/// the user pasted it into) can start dictation.
enum RemoteControlToken {
	static let fileName = "remote-control-token"

	static var defaultDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera", isDirectory: true)
	}

	static func fileURL(in directory: URL = defaultDirectory) -> URL {
		directory.appendingPathComponent(fileName)
	}

	/// Returns the stored token, creating one on first use when `createIfMissing` is set.
	static func load(in directory: URL = defaultDirectory, createIfMissing: Bool = true) -> String? {
		let url = fileURL(in: directory)
		if let data = try? Data(contentsOf: url),
			let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
			isWellFormed(token)
		{
			return token
		}
		guard createIfMissing else { return nil }
		return try? regenerate(in: directory)
	}

	@discardableResult
	static func regenerate(in directory: URL = defaultDirectory) throws -> String {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let token = makeToken()
		let destination = fileURL(in: directory)
		let staging = directory.appendingPathComponent(".\(fileName)-\(UUID().uuidString)")
		guard
			FileManager.default.createFile(
				atPath: staging.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
		else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
		}
		guard rename(staging.path, destination.path) == 0 else {
			try? FileManager.default.removeItem(at: staging)
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
		}
		return token
	}

	/// Constant-time comparison so response timing does not leak how much of a guess matched.
	static func matches(_ candidate: String?, expected: String?) -> Bool {
		guard let candidate, let expected, isWellFormed(expected) else { return false }
		let lhs = Array(candidate.utf8)
		let rhs = Array(expected.utf8)
		guard lhs.count == rhs.count else { return false }
		var difference: UInt8 = 0
		for index in lhs.indices {
			difference |= lhs[index] ^ rhs[index]
		}
		return difference == 0
	}

	static func isWellFormed(_ token: String) -> Bool {
		token.count == 64 && token.allSatisfy { $0.isHexDigit }
	}

	private static func makeToken() -> String {
		var bytes = [UInt8](repeating: 0, count: 32)
		if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
			var generator = SystemRandomNumberGenerator()
			bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
		}
		return bytes.map { String(format: "%02x", $0) }.joined()
	}
}
