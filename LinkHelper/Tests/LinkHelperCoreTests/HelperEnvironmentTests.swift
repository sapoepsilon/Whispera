import XCTest

@testable import LinkHelperCore

final class HelperEnvironmentTests: XCTestCase {
	func testDropsEveryLinkOverrideAndKeepsTheRest() {
		let environment = [
			"PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "HERDR_CONFIG_PATH": "/tmp/herdr.toml",
			"WHISPERA_LINK_HOME": "/tmp/state", "WHISPERA_LINK_ACCOUNT_BEARER": "tok",
			"WHISPERA_LINK_ACCOUNT_BACKEND_URL": "http://127.0.0.1:1", "WHISPERA_LINK_APP_DEFAULTS": "x",
			"WHISPERA_LINK_STT_MODELS_BASE": "/tmp/models", "WHISPERA_LINK_ALLOW_LAN": "1",
		]
		let kept = HelperEnvironment.withoutOverrides(environment)
		XCTAssertEqual(
			kept, ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "HERDR_CONFIG_PATH": "/tmp/herdr.toml"])
	}

	func testStrippedEnvironmentLoadsTheDefaultConfig() {
		let environment = [
			"HOME": "/tmp/wl-home", "WHISPERA_LINK_CONFIG": "/nonexistent",
			"WHISPERA_LINK_RELAY_BASE_URL": "http://127.0.0.1:18080", "WHISPERA_LINK_ACCOUNT_BEARER": "tok",
			"WHISPERA_LINK_ALLOW_LAN": "1",
		]
		let config = HelperConfig.load(environment: HelperEnvironment.withoutOverrides(environment))
		XCTAssertEqual(config.relayBaseURL, "")
		XCTAssertEqual(config.accountBearer, "")
		XCTAssertFalse(config.allowUnencryptedLAN)
		XCTAssertEqual(config.paths.stateDir, "/tmp/wl-home/.whispera-link")
	}
}
