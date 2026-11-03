import Foundation

/// The environment the shipped login-item helper runs with.
///
/// The `WHISPERA_LINK_*` overrides exist for the standalone `link-helper-serve` and the e2e
/// scripts: another state directory, another backend, relay or account bearer, another settings
/// domain or model folder. launchd never sets them for the login item, so a release build drops
/// them all and takes its configuration only from `config.json` and Whispera's own settings.
public enum HelperEnvironment {
	public static let overridePrefix = "WHISPERA_LINK_"

	/// `environment` without any `WHISPERA_LINK_*` override. PATH, HOME and the rest are kept:
	/// the helper still needs them to find herdr, tmux, ssh and the user's folders.
	public static func withoutOverrides(_ environment: [String: String]) -> [String: String] {
		environment.filter { !$0.key.hasPrefix(overridePrefix) }
	}
}
