import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// The direct path is plain HTTP: only loopback and the tailnet get in unless the owner turns
/// on plain-LAN access, and nothing the helper would refuse is ever offered.
final class DirectAccessTests: XCTestCase {
	func testClassifiesLoopbackTailnetAndLocalNetwork() {
		let cases: [(String, DirectAccessPolicy.Kind)] = [
			("127.0.0.1", .loopback), ("127.8.9.10", .loopback), ("::1", .loopback), ("[::1]", .loopback),
			("::ffff:127.0.0.1", .loopback),
			("100.64.0.1", .tailnet), ("100.127.255.254", .tailnet), ("::ffff:100.100.1.2", .tailnet),
			("fd7a:115c:a1e0::1", .tailnet), ("fd7a:115c:a1e0:1:2:3:4:5", .tailnet),
			("[fd7a:115c:a1e0::5]", .tailnet),
			("10.0.0.57", .localNetwork), ("10.0.0.7", .localNetwork), ("172.16.0.1", .localNetwork),
			("172.31.255.1", .localNetwork), ("169.254.3.4", .localNetwork), ("::ffff:10.0.0.57", .localNetwork),
			("fe80::1%en0", .localNetwork), ("fe80::1c2b:3d4e", .localNetwork), ("fd00::1", .localNetwork), ("fd7a:115c:a1e1::1", .localNetwork),
			("100.63.255.255", .other), ("100.128.0.1", .other), ("172.32.0.1", .other), ("198.51.100.7", .other),
			("8.8.8.8", .other), ("2001:db8::1", .other), ("::ffff:198.51.100.7", .other),
			("mac.local", .other), ("localhost", .other), ("-", .other), ("", .other),
		]
		for (host, kind) in cases {
			XCTAssertEqual(DirectAccessPolicy.classify(host), kind, host)
		}
	}

	typealias Interface = DirectAccessPolicy.InterfaceAddress
	/// A Mac on Wi-Fi with a Tailscale address on utun4, and a carrier-NAT 100.x on en1.
	static let interfaces = [
		Interface(name: "en0", ip: "10.0.0.57"), Interface(name: "en0", ip: "fe80::1c2b:3d4e%en0"),
		Interface(name: "utun4", ip: "100.88.7.6"), Interface(name: "utun4", ip: "fd7a:115c:a1e0::77"),
		Interface(name: "en1", ip: "100.72.9.3"),
	]
	static let own = DirectAccessPolicy.ownTailnetAddresses(interfaces)

	func testOwnTailnetAddressesComeFromUtunOnly() {
		XCTAssertEqual(Self.own, ["100.88.7.6", "fd7a:115c:a1e0::77"])
		XCTAssertEqual(DirectAccessPolicy.normalize("::ffff:100.88.7.6"), "100.88.7.6")
		XCTAssertEqual(DirectAccessPolicy.normalize("[FD7A:115C:A1E0:0::77%utun4]"), "fd7a:115c:a1e0::77")
	}

	func testATailnetPeerCountsOnlyOnThisMacsTailscaleAddress() {
		func kind(_ peer: String, _ local: String?, _ interface: String? = nil) -> DirectAccessPolicy.Kind {
			let defaultInterface = local.map { Self.own.contains(DirectAccessPolicy.normalize($0)) ? "utun4" : "en0" }
			return DirectAccessPolicy.connectionKind(
				peer: peer, local: local, interface: interface ?? defaultInterface, ownTailnet: Self.own)
		}
		XCTAssertEqual(kind("100.101.102.103", "100.88.7.6"), .tailnet)
		XCTAssertEqual(kind("::ffff:100.101.102.103", "::ffff:100.88.7.6"), .tailnet)
		XCTAssertEqual(kind("fd7a:115c:a1e0::9", "fd7a:115c:a1e0::77%utun4"), .tailnet)
		// Carrier-grade NAT on hotel Wi-Fi, or a spoofed 100.x source on the LAN.
		XCTAssertEqual(kind("100.72.0.1", "100.72.9.3"), .other)
		XCTAssertEqual(kind("100.101.102.103", "10.0.0.57"), .other)
		XCTAssertEqual(kind("100.101.102.103", nil), .other, "unknown local address: not the tailnet")
		// A LAN host sending to the tailnet IP through Wi-Fi never went through WireGuard.
		XCTAssertEqual(kind("100.101.102.103", "100.88.7.6", "en0"), .other)
		XCTAssertEqual(kind("fd7a:115c:a1e0::9", "fd7a:115c:a1e0::77", "en0"), .other)
		XCTAssertEqual(
			DirectAccessPolicy.connectionKind(peer: "100.101.102.103", local: "100.88.7.6", interface: nil, ownTailnet: Self.own),
			.other, "unknown interface: not the tailnet")
		XCTAssertEqual(kind("127.0.0.1", "127.0.0.1"), .loopback)
		XCTAssertEqual(kind("::1", nil), .loopback)
		XCTAssertEqual(kind("127.0.0.1", "10.0.0.57"), .other)
		XCTAssertEqual(kind("10.0.0.23", "10.0.0.57"), .localNetwork)
		XCTAssertEqual(kind("fe80::9%en0", "fe80::1c2b:3d4e%en0"), .localNetwork)
		XCTAssertEqual(kind("198.51.100.7", "10.0.0.57"), .other)
	}

	func testOnlyLoopbackAndTailnetGetInByDefault() {
		let gate = DirectAccessGate(configured: false, interfaces: { Self.interfaces })
		XCTAssertTrue(gate.admits(peer: "127.0.0.1", local: "127.0.0.1", interface: "lo0"))
		XCTAssertTrue(gate.admits(peer: "100.101.102.103", local: "100.88.7.6", interface: "utun4"))
		XCTAssertTrue(gate.admits(peer: "fd7a:115c:a1e0::9", local: "fd7a:115c:a1e0::77", interface: "utun4"))
		for (peer, local) in [
			("10.0.0.23", "10.0.0.57"), ("fe80::9%en0", "fe80::1c2b:3d4e%en0"), ("100.72.0.1", "100.72.9.3"),
			("198.51.100.7", "10.0.0.57"),
		] {
			XCTAssertFalse(gate.admits(peer: peer, local: local, interface: "en0"), peer)
		}
	}

	func testOptInAdmitsTheLocalNetworkButNeverPublicOrSpoofedAddresses() {
		let gate = DirectAccessGate(configured: true, interfaces: { Self.interfaces })
		for peer in ["10.0.0.23", "172.20.0.4", "192.168.7.8", "fe80::9%en0", "fd12:3456::1", "::ffff:10.0.0.23"] {
			XCTAssertTrue(gate.admits(peer: peer, local: "10.0.0.57", interface: "en0"), peer)
		}
		for peer in ["198.51.100.7", "203.0.113.9", "2001:db8::1", "100.72.0.1", "100.101.102.103"] {
			XCTAssertFalse(gate.admits(peer: peer, local: "10.0.0.57", interface: "en0"), peer)
		}
	}

	func testTheGateFollowsTheAppSettingLive() {
		final class Flag: @unchecked Sendable { var on = false }
		let flag = Flag()
		let gate = DirectAccessGate(configured: false, preference: { flag.on }, interfaces: { Self.interfaces })
		XCTAssertFalse(gate.admits(peer: "10.0.0.23", local: "10.0.0.57", interface: "en0"))
		XCTAssertTrue(gate.admits(peer: "100.64.0.1", local: "100.88.7.6", interface: "utun4"))
		flag.on = true
		// Cached for a second at most.
		let deadline = Date().addingTimeInterval(3)
		while !gate.admits(peer: "10.0.0.23", local: "10.0.0.57", interface: "en0"), Date() < deadline { usleep(100_000) }
		XCTAssertTrue(gate.admits(peer: "10.0.0.23", local: "10.0.0.57", interface: "en0"))
	}

	func testConfigTurnsPlainLANAccessOnOnlyWhenAsked() throws {
		let base = ["HOME": "/tmp/wl-home", "WHISPERA_LINK_CONFIG": "/nonexistent"]
		XCTAssertFalse(HelperConfig.load(environment: base).allowUnencryptedLAN)
		XCTAssertEqual(HelperConfig.load(environment: base).listenHost, "0.0.0.0")
		XCTAssertTrue(
			HelperConfig.load(environment: base.merging(["WHISPERA_LINK_ALLOW_LAN": "1"]) { $1 }).allowUnencryptedLAN)

		let file = FileManager.default.temporaryDirectory.appendingPathComponent("wlc-\(UUID().uuidString).json")
		try Data(#"{"allow_unencrypted_lan": true}"#.utf8).write(to: file)
		defer { try? FileManager.default.removeItem(at: file) }
		XCTAssertTrue(
			HelperConfig.load(environment: ["HOME": "/tmp/wl-home", "WHISPERA_LINK_CONFIG": file.path])
				.allowUnencryptedLAN)
	}

	// MARK: Offers

	func testOffersLeaveOutLANAndCarrierNATAddressesByDefault() {
		var config = HelperConfig(paths: .init(config: "/x", stateDir: "/x", log: "/x"))
		config.listenHost = "0.0.0.0"
		let tailnet = ["http://[fd7a:115c:a1e0::77]:7000", "http://100.88.7.6:7000"]
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000, interfaces: Self.interfaces), tailnet)
		let withLAN = OfferAddresses.baseURLs(config: config, port: 7000, allowLAN: true, interfaces: Self.interfaces)
		XCTAssertEqual(Array(withLAN.prefix(3)), tailnet + ["http://10.0.0.57:7000"])
		XCTAssertTrue(withLAN.last?.hasSuffix(".local:7000") == true)
		XCTAssertFalse(withLAN.contains("http://100.72.9.3:7000"), "a carrier-NAT address is never offered")
	}

	func testASpecificListenAddressIsOfferedOnlyWhenItWouldBeAdmitted() {
		var config = HelperConfig(paths: .init(config: "/x", stateDir: "/x", log: "/x"))
		config.listenHost = "10.0.0.57"
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000, interfaces: Self.interfaces), [])
		XCTAssertEqual(
			OfferAddresses.baseURLs(config: config, port: 7000, allowLAN: true, interfaces: Self.interfaces),
			["http://10.0.0.57:7000"])
		config.listenHost = "100.88.7.6"
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000, interfaces: Self.interfaces), ["http://100.88.7.6:7000"])
		config.listenHost = "100.72.9.3"
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000, interfaces: Self.interfaces), [])
		// An explicit public_url is the owner's choice and is always offered.
		config.publicURL = "https://mac.example.ts.net/"
		XCTAssertEqual(OfferAddresses.baseURLs(config: config, port: 7000).first, "https://mac.example.ts.net")
	}

	func testPairingURLNeverPointsAtARefusedAddress() {
		var config = HelperConfig(paths: .init(config: "/x", stateDir: "/x", log: "/x"))
		config.listenHost = "0.0.0.0"
		XCTAssertEqual(
			LinkDaemon.pairingURL(config, port: 7000, allowLAN: false, interfaces: Self.interfaces),
			"http://[fd7a:115c:a1e0::77]:7000")
		// Without a tailnet only the Bonjour name is left; the QR still names the Mac.
		let noTailnet = [Interface(name: "en0", ip: "10.0.0.57"), Interface(name: "en1", ip: "100.72.9.3")]
		XCTAssertTrue(LinkDaemon.pairingURL(config, port: 7000, allowLAN: false, interfaces: noTailnet).hasSuffix(".local:7000"))
		config.listenHost = "127.0.0.1"
		XCTAssertEqual(LinkDaemon.pairingURL(config, port: 7000, allowLAN: false), "http://127.0.0.1:7000")
	}

	static var lanAddress: String? {
		DirectAccessPolicy.interfaceAddresses().first {
			!$0.name.hasPrefix("utun") && !$0.ip.contains(":") && DirectAccessPolicy.classify($0.ip) == .localNetwork
				&& !$0.ip.hasPrefix("169.254.")
		}?.ip
	}

	// MARK: Accept

	/// A connection from this Mac's own LAN address arrives with that address as its peer: it is
	/// closed at accept, before any request is parsed, until plain-LAN access is turned on.
	func testRefusesALANPeerAtAccept() async throws {
		guard let lan = Self.lanAddress else { throw XCTSkip("no private IPv4 address on this Mac") }
		let helper = try TestDaemon {
			$0.listenHost = "0.0.0.0"
			$0.bonjour = true
		}
		defer { helper.stop() }
		let loopback = try await SoftPhone.send(URLRequest(url: helper.baseURL.appendingPathComponent("v1/health")))
		XCTAssertEqual(loopback.status, 200)

		var request = URLRequest(url: URL(string: "http://\(lan):\(helper.port)/v1/health")!)
		request.timeoutInterval = 5
		do {
			let response = try await SoftPhone.send(request)
			XCTFail("a LAN peer got an answer: \(response.status)")
		} catch {
			// Closed without a response.
		}
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("http.refused"), "the refusal is logged")
		XCTAssertFalse(helper.daemon.shouldAdvertise, "no Bonjour without plain-LAN access")
	}

	/// With Tailscale up, a connection to this Mac's own tailnet address runs over utun and is
	/// admitted as tailnet; the stack reports the interface the check needs.
	func testATailnetConnectionIsAdmittedOverUtun() async throws {
		let own = DirectAccessPolicy.interfaceAddresses().first {
			$0.name.hasPrefix("utun") && !$0.ip.contains(":") && DirectAccessPolicy.classify($0.ip) == .tailnet
		}
		guard let tailnetIP = own?.ip else { throw XCTSkip("Tailscale is not up on this Mac") }
		let helper = try TestDaemon { $0.listenHost = "0.0.0.0" }
		defer { helper.stop() }
		var request = URLRequest(url: URL(string: "http://\(tailnetIP):\(helper.port)/v1/health")!)
		request.timeoutInterval = 5
		let response = try await SoftPhone.send(request)
		XCTAssertEqual(response.status, 200)
	}

	func testOptInLetsALANPeerIn() async throws {
		guard let lan = Self.lanAddress else { throw XCTSkip("no private IPv4 address on this Mac") }
		let helper = try TestDaemon {
			$0.listenHost = "0.0.0.0"
			$0.allowUnencryptedLAN = true
		}
		defer { helper.stop() }
		var request = URLRequest(url: URL(string: "http://\(lan):\(helper.port)/v1/health")!)
		request.timeoutInterval = 5
		let response = try await SoftPhone.send(request)
		XCTAssertEqual(response.status, 200)
	}

	/// Input frames on the WebSocket are trusted after the signed upgrade, so a plain local network
	/// peer never gets one, even opted in: it is told to use SSE, whose input is a signed POST.
	func testTheTerminalWebSocketIsRefusedOnThePlainLocalNetwork() async throws {
		guard let lan = Self.lanAddress else { throw XCTSkip("no private IPv4 address on this Mac") }
		let sockets = TerminalWebSocketTests()
		let (helper, _) = try sockets.helperWithFakePanes {
			$0.listenHost = "0.0.0.0"
			$0.allowUnencryptedLAN = true
		}
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let target = "/v1/agents/w1:p1/terminal/ws?cols=50&rows=20&mode=mirror"

		let overLAN = try RawClient(port: helper.port, host: lan)
		overLAN.send(sockets.handshake(target, headers: try phone.signed("GET", target).allHTTPHeaderFields ?? [:]))
		let refused = try XCTUnwrap(overLAN.readHead())
		XCTAssertTrue(refused.hasPrefix("HTTP/1.0 400 "), refused)

		var sseRequest = try phone.signed("GET", "/v1/agents/w1:p1/terminal?cols=50&rows=20")
		sseRequest.url = URL(string: "http://\(lan):\(helper.port)/v1/agents/w1:p1/terminal?cols=50&rows=20")
		sseRequest.timeoutInterval = 5
		let (_, response) = try await URLSession.shared.bytes(for: sseRequest)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the SSE fallback still works")

		let local = try RawClient(port: helper.port)
		local.send(sockets.handshake(target, headers: try phone.signed("GET", target).allHTTPHeaderFields ?? [:]))
		XCTAssertTrue(try XCTUnwrap(local.readHead()).hasPrefix("HTTP/1.1 101 "), "loopback keeps the WebSocket")
	}

	// MARK: Offer order and flags

	/// iOS lets an app reach `*.ts.net` and IPv6 over plain HTTP, not a 100.x literal, so the
	/// MagicDNS name leads, then the Tailscale IPv6 address, then the IPv4 one.
	func testOffersListTheMagicDNSNameThenIPv6ThenIPv4() {
		var config = HelperConfig(paths: .init(config: "/x", stateDir: "/x", log: "/x"))
		config.listenHost = "0.0.0.0"
		let urls = OfferAddresses.baseURLs(
			config: config, port: 7000, interfaces: Self.interfaces, tailnetName: "mac-a.example.ts.net")
		XCTAssertEqual(
			urls, ["http://mac-a.example.ts.net:7000", "http://[fd7a:115c:a1e0::77]:7000", "http://100.88.7.6:7000"])
		XCTAssertEqual(
			LinkDaemon.pairingURL(
				config, port: 7000, allowLAN: false, interfaces: Self.interfaces, tailnetName: "mac-a.example.ts.net"),
			"http://mac-a.example.ts.net:7000")
		let withLAN = OfferAddresses.baseURLs(
			config: config, port: 7000, allowLAN: true, interfaces: Self.interfaces, tailnetName: "mac-a.example.ts.net")
		XCTAssertEqual(Array(withLAN.prefix(4)), urls + ["http://10.0.0.57:7000"])
		// No Tailscale address up: the name is not offered either.
		let offline = [Interface(name: "en0", ip: "10.0.0.57")]
		XCTAssertEqual(
			OfferAddresses.baseURLs(config: config, port: 7000, interfaces: offline, tailnetName: "mac-a.example.ts.net"), [])
	}

	func testTheMagicDNSNameComesFromTailscaleStatus() {
		let status = Data(#"{"Self":{"DNSName":"Mac-A.example.ts.net.","UserID":7}}"#.utf8)
		XCTAssertEqual(TailscaleCLIIdentity.parseSelfDNSName(status), "mac-a.example.ts.net")
		XCTAssertNil(TailscaleCLIIdentity.parseSelfDNSName(Data(#"{"Self":{"DNSName":"mac-a.local."}}"#.utf8)))
		XCTAssertNil(TailscaleCLIIdentity.parseSelfDNSName(Data(#"{"Self":{"DNSName":"a b.example.ts.net."}}"#.utf8)))
		XCTAssertNil(TailscaleCLIIdentity.parseSelfDNSName(Data("{}".utf8)))
	}

	func testTheOfferAndBonjourCarryTheLANFlagOnlyWhenOn() throws {
		let context = { (lan: Bool) in
			AccountLink.OfferContext(
				baseURLs: ["http://mac-a.example.ts.net:7000"], daemonPubkeyB64: "k", daemonFP: "f", macName: "Mac",
				allowLANHTTP: lan)
		}
		XCTAssertNotEqual(
			AccountLink.offerDigest(context(true), approveConfirmed: true),
			AccountLink.offerDigest(context(false), approveConfirmed: true), "turning it on re-sends the offer")
		XCTAssertEqual(
			AccountLink.offerDigest(context(false), approveConfirmed: true),
			LinkCrypto.sha256Hex(
				Data(["http://mac-a.example.ts.net:7000", "f", "Mac", "true", "signs_responses"].joined(separator: "\n").utf8)),
			"off adds nothing beyond signs_responses, which every offer now carries")

		func encoded(_ flag: Bool?) throws -> [String: Any] {
			let offer = LinkOffer(
				helper_device_id: "m", base_urls: [], daemon_pubkey: "k", daemon_fp: "f", mac_name: "Mac",
				approve_confirmed: true, allow_lan_http: flag)
			return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
		}
		XCTAssertEqual(try encoded(true)["allow_lan_http"] as? Bool, true)
		XCTAssertNil(try encoded(nil)["allow_lan_http"])
		let stamped = LinkOffer(
			helper_device_id: "m", base_urls: [], daemon_pubkey: "k", daemon_fp: "f", mac_name: "Mac",
			approve_confirmed: true, issued_at: 1_800_000_000)
		let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stamped)) as? [String: Any])
		XCTAssertEqual(json["issued_at"] as? Int64, 1_800_000_000)
		XCTAssertEqual(try JSONDecoder().decode(LinkOffer.self, from: JSONEncoder().encode(stamped)).issued_at, 1_800_000_000)

		XCTAssertEqual(LinkDaemon.bonjourTXT(port: 7787, allowLAN: true)["lan"], "1")
		XCTAssertNil(LinkDaemon.bonjourTXT(port: 7787)["lan"])
	}

	/// iOS pairs by code with a plain `http://` LAN address only when the QR says `lan=1`.
	func testThePairingQRSaysLANOnlyWhenOn() throws {
		let off = try TestDaemon()
		defer { off.stop() }
		let plain = try XCTUnwrap(off.daemon.pairing.begin(ttl: 60)["qr_payload"] as? String)
		XCTAssertFalse(plain.contains("lan="), plain)

		let on = try TestDaemon { $0.allowUnencryptedLAN = true }
		defer { on.stop() }
		let qr = try XCTUnwrap(on.daemon.pairing.begin(ttl: 60)["qr_payload"] as? String)
		let items = URLComponents(string: qr)?.queryItems ?? []
		XCTAssertEqual(items.first { $0.name == "lan" }?.value, "1", qr)
		XCTAssertEqual(items.first { $0.name == "fp" }?.value, on.daemon.daemonFP)
	}

	/// The phone may address the Mac by its MagicDNS name; the helper serves any Host.
	func testAMagicDNSHostHeaderIsServed() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let headers = try phone.signed("GET", "/v1/devices/me").allHTTPHeaderFields ?? [:]
		var head = "GET /v1/devices/me HTTP/1.1\r\nHost: mac-a.example.ts.net:\(helper.port)\r\n"
		for (name, value) in headers { head += "\(name): \(value)\r\n" }
		let client = try RawClient(port: helper.port)
		client.send(Data((head + "\r\n").utf8))
		let response = try XCTUnwrap(client.readHead())
		XCTAssertTrue(response.hasPrefix("HTTP/1.0 200 "), response)
	}
}

/// What the helper says about itself without a signature.
final class PublicHealthTests: XCTestCase {
	func testUnsignedHealthCarriesOnlyWhatPairingNeeds() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let unsigned = try await SoftPhone.send(URLRequest(url: helper.baseURL.appendingPathComponent("v1/health")))
		XCTAssertEqual(unsigned.status, 200)
		XCTAssertEqual(Set(unsigned.json.keys), ["ok", "protocol", "daemon_fp", "server_time"])
		XCTAssertEqual(unsigned.json["daemon_fp"] as? String, helper.daemon.daemonFP)

		let phone = try await helper.pairedPhone()
		let signed = try await phone.call("GET", "/v1/health")
		XCTAssertEqual(signed.status, 200)
		for key in ["version", "capabilities", "herdr", "hc", "broker", "apns", "stt", "stt_mode"] {
			XCTAssertNotNil(signed.json[key], key)
		}
	}

	func testABadSignatureOnHealthIsRefused() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		var request = try phone.signed("GET", "/v1/health")
		request.setValue(String(repeating: "A", count: 86), forHTTPHeaderField: "X-WL-Signature")
		let response = try await SoftPhone.send(request)
		XCTAssertEqual(response.status, 401)
	}

	func testTheAppSettingKeyMatchesWhispera() {
		// Whispera writes MacLinkHelper.allowUnencryptedLANKey; the helper reads this one.
		XCTAssertEqual(DirectAccessPolicy.allowLANKey, "whisperaLinkAllowUnencryptedLAN")
	}
}
