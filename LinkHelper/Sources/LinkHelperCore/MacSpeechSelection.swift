import Foundation
import Security

/// Where the Mac voice server sends a phone's audio: whatever engine is selected in Whispera on
/// this Mac. The phone never names a model; it gets the Mac's engine.
public enum MacSpeechRoute: Equatable, Sendable {
	/// The Mac's own on-device model (`LocalSpeechEngine`).
	case onDevice
	/// The OpenAI-compatible speech server Whispera is set up to use (speaches, OpenAI, Groq, …).
	case remote(RemoteSpeechServer)
	/// The selected engine cannot serve yet; the message says what to fix on the Mac.
	case unavailable(String)
}

/// A speech server as Whispera's settings name it.
public struct RemoteSpeechServer: Equatable, Sendable {
	/// Normalised base URL ending in `/v1`, no trailing slash.
	public var baseURL: String
	/// The model the Mac uses on that server; empty when none is set.
	public var model: String

	public init(baseURL: String, model: String) {
		var base = baseURL
		while base.hasSuffix("/") { base.removeLast() }
		self.baseURL = base
		self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Short, human name for the phone: "OpenAI", "Groq" or the host.
	public var label: String {
		let host = URL(string: baseURL)?.host ?? baseURL
		switch host.lowercased() {
		case "api.openai.com": return "OpenAI"
		case "api.groq.com": return "Groq"
		default: return host
		}
	}
}

/// Answers which engine the Mac has selected right now. Read on every request, so a change in
/// Whispera's settings reaches the phone's next request without restarting the helper.
public protocol MacSpeechSelecting: Sendable {
	func route() -> MacSpeechRoute
}

/// Whispera's own settings, read from the app's preferences domain: the engine picker
/// (`whisperaTranscriptionEngine`) and the speech server entry (`whisperaTranscriptionDirectURL`,
/// `whisperaTranscriptionDirectModel`). Works while Whispera is quit; the key never lives here
/// (see `SpeechKeyStoring`).
public struct AppSpeechSelection: MacSpeechSelecting {
	public static let engineKey = "whisperaTranscriptionEngine"
	public static let speechURLKey = "whisperaTranscriptionDirectURL"
	public static let speechModelKey = "whisperaTranscriptionDirectModel"

	public static let notSetUp =
		"The Mac's speech server isn't set up. Open Whispera ▸ Settings ▸ Servers on the Mac and add one."

	public let domain: String

	public init(domain: String) {
		self.domain = domain
	}

	/// The app's preferences domain from the helper's bundle id: the helper is
	/// `<app id>.LinkHelper` (`com.macwhisper.app.LinkHelper`, or `.debug.LinkHelper` in debug).
	public static func appDomain(helperBundleIdentifier: String?) -> String {
		let suffix = ".LinkHelper"
		guard let id = helperBundleIdentifier, id.hasSuffix(suffix), id.count > suffix.count else {
			return "com.macwhisper.app"
		}
		return String(id.dropLast(suffix.count))
	}

	private func string(_ key: String) -> String? {
		CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
	}

	public func route() -> MacSpeechRoute {
		// Another process writes this domain; synchronise so the read is not a stale cache.
		CFPreferencesAppSynchronize(domain as CFString)
		return Self.route(
			engine: string(Self.engineKey), speechURL: string(Self.speechURLKey) ?? "",
			speechModel: string(Self.speechModelKey) ?? "")
	}

	/// The mapping from Whispera's `TranscriptionEngine` raw values, pure for tests.
	///
	/// - `whisperKit` (and an absent or unknown value, which the app also reads as WhisperKit):
	///   the on-device model.
	/// - `whisperViaBYOK`, `realtimeDirect`: the speech server entry, with the Mac's model and key.
	/// - `auto`, `whisperaStreaming`: the speech server when one is set up, else on-device. A
	///   phone upload is one batch request, so the streaming backend itself is not involved.
	public static func route(engine: String?, speechURL: String, speechModel: String) -> MacSpeechRoute {
		let server = normalize(speechURL).map { RemoteSpeechServer(baseURL: $0, model: speechModel) }
		switch engine ?? "" {
		case "whisperViaBYOK", "realtimeDirect":
			return server.map(MacSpeechRoute.remote) ?? .unavailable(notSetUp)
		case "auto", "whisperaStreaming":
			return server.map(MacSpeechRoute.remote) ?? .onDevice
		default:
			return .onDevice
		}
	}

	/// Whispera's `ServerURLNormalizer.normalize`: a bare host gets `http://`, the path gets `/v1`.
	/// Nil when the field cannot address a server yet.
	public static func normalize(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
		guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty,
			!host.hasSuffix("."), host != "http", host != "https"
		else { return nil }
		var path = components.path
		while path.hasSuffix("/") { path.removeLast() }
		if !path.hasSuffix("/v1") { path += "/v1" }
		components.path = path
		components.query = nil
		components.fragment = nil
		return components.url?.absoluteString
	}
}

/// The speech server's API key as Whispera handed it over (XPC), bound to the base URL it was
/// saved for: a key is only ever sent to that server, and never to a phone.
public struct SpeechServerCredential: Equatable, Sendable {
	public var baseURL: String
	public var key: String

	public init(baseURL: String, key: String) {
		self.baseURL = AppSpeechSelection.normalize(baseURL) ?? baseURL
		self.key = key
	}
}

public protocol SpeechKeyStoring: Sendable {
	func credential() -> SpeechServerCredential?
	/// nil removes it.
	func setCredential(_ credential: SpeechServerCredential?) throws
}

extension SpeechKeyStoring {
	/// The key for `server`, or nil when none was handed over for that exact base URL.
	func key(for server: RemoteSpeechServer) -> String? {
		guard let credential = credential(), !credential.key.isEmpty, credential.baseURL == server.baseURL
		else { return nil }
		return credential.key
	}
}

/// The helper's own Keychain item (it created it, so it reads it without a prompt), this device
/// only and never synced.
public final class KeychainSpeechKeyStore: SpeechKeyStoring, @unchecked Sendable {
	private let service: String
	private let account = "speech-server"

	public init(service: String = "com.whispera.link.speech-server") {
		self.service = service
	}

	public func credential() -> SpeechServerCredential? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
			kSecAttrAccount as String: account, kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
			let object = WireJSON.decodeObject(data), let base = object["base_url"] as? String,
			let key = object["key"] as? String
		else { return nil }
		return SpeechServerCredential(baseURL: base, key: key)
	}

	public func setCredential(_ credential: SpeechServerCredential?) throws {
		let match: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		SecItemDelete(match as CFDictionary)
		guard let credential, !credential.key.isEmpty else { return }
		var add = match
		add[kSecValueData as String] = WireJSON.encode(["base_url": credential.baseURL, "key": credential.key])
		add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw APIError(500, "keychain_error", "could not store the speech server key (OSStatus \(status))")
		}
	}
}

/// In memory, for tests and for a helper run without a Keychain.
public final class MemorySpeechKeyStore: SpeechKeyStoring, @unchecked Sendable {
	private let lock = NSLock()
	private var stored: SpeechServerCredential?

	public init(_ credential: SpeechServerCredential? = nil) {
		stored = credential
	}

	public func credential() -> SpeechServerCredential? {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}

	public func setCredential(_ credential: SpeechServerCredential?) throws {
		lock.lock()
		stored = credential
		lock.unlock()
	}
}

extension LinkDaemon {
	/// Stores (or with an empty key, removes) the speech server key Whispera handed over (XPC).
	func setSpeechServerKey(baseURL: String, key: String) throws -> [String: Any] {
		guard let store = speech.keyStore else {
			throw APIError(503, "unsupported", "this helper keeps no speech server key")
		}
		let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty {
			try store.setCredential(nil)
			log("stt.key", ["detail": "cleared"])
			return ["ok": true]
		}
		guard let base = AppSpeechSelection.normalize(baseURL) else {
			throw APIError(400, "bad_request", "base_url is not a server address")
		}
		try store.setCredential(SpeechServerCredential(baseURL: base, key: trimmed))
		log("stt.key", ["detail": "set for \(URL(string: base)?.host ?? "?")"])
		return ["ok": true]
	}
}
