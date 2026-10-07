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

	func testStandaloneAccountEnvironmentForTheE2EHelper() {
		let config = HelperConfig.load(environment: [
			"HOME": "/tmp/wl-home", "WHISPERA_LINK_CONFIG": "/nonexistent/config.json",
			"WHISPERA_LINK_RELAY_BASE_URL": "http://127.0.0.1:18080",
			"WHISPERA_LINK_ACCOUNT_BACKEND_URL": "http://127.0.0.1:18080", "WHISPERA_LINK_ACCOUNT_BEARER": "tok",
			"WHISPERA_LINK_ACCOUNT_POLL_S": "99", "WHISPERA_LINK_OFFER_BASE_URLS": "http://a:1, http://b:2",
			"WHISPERA_LINK_MAC_NAME": "E2E Mac",
		])
		XCTAssertEqual(config.relayBaseURL, "http://127.0.0.1:18080")
		XCTAssertEqual(config.accountBackendURL, "http://127.0.0.1:18080")
		XCTAssertEqual(config.accountBearer, "tok")
		XCTAssertEqual(config.accountPollWait, 30)
		XCTAssertEqual(config.offerBaseURLs, ["http://a:1", "http://b:2"])
		XCTAssertEqual(config.macName, "E2E Mac")
		XCTAssertFalse(config.testAdminConfirm, "admin confirm is off unless asked for")
		XCTAssertEqual(config.paths.accountState, "/tmp/wl-home/.whispera-link/account.json")
	}

	func testOfferAddressesFollowTheListener() {
		var config = HelperConfig(paths: .init(config: "/x", stateDir: "/x", log: "/x"))
		config.listenHost = "127.0.0.1"
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000), ["http://127.0.0.1:7000"])
		config.listenHost = "0.0.0.0"
		config.publicURL = "https://mac.example.ts.net/"
		let urls = OfferAddresses.baseURLs(config: config, port: 7000)
		XCTAssertEqual(urls.first, "https://mac.example.ts.net")
		XCTAssertFalse(urls.contains { $0.contains("127.0.0.1") })
		XCTAssertTrue(OfferAddresses.isTailscale("100.64.253.2"))
		XCTAssertFalse(OfferAddresses.isTailscale("192.168.50.190"))
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000, override: ["http://x:1"]), ["http://x:1"])
	}
}
