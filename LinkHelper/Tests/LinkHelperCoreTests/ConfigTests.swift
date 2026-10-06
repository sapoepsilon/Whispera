import XCTest

@testable import LinkHelperCore

final class ConfigTests: XCTestCase {
	func testEnvironmentOverridesWinOverDefaults() {
		let config = HelperConfig.load(environment: [
			"HOME": "/tmp/wl-home", "WHISPERA_LINK_PORT": "0", "WHISPERA_LINK_LISTEN_HOST": "127.0.0.1",
			"WHISPERA_LINK_CONFIG": "/nonexistent/config.json",
		])
		XCTAssertEqual(config.port, 0)
		XCTAssertEqual(config.listenHost, "127.0.0.1")
		XCTAssertEqual(config.paths.stateDir, "/tmp/wl-home/.whispera-link")
		XCTAssertEqual(config.paths.log, "/tmp/wl-home/Library/Logs/whispera-link.log")
		XCTAssertEqual(config.herdrSocket, "/tmp/wl-home/.config/herdr/herdr.sock")
		XCTAssertEqual(config.effectivePublicURL(boundPort: 4242).0, "http://127.0.0.1:4242")
	}
}
