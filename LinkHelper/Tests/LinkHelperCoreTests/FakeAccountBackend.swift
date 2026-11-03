import CryptoKit
import Foundation
import WhisperaLink

@testable import LinkHelperCore

/// The account backend's device registry and relay, in memory, behind `LinkTransport` — the
/// same routes and JSON as the Rust server, scoped per account like it: a device only ever
/// sees its own account's devices and can only relay to them.
final class FakeAccountBackend: LinkTransport, @unchecked Sendable {
	struct Stored {
		var account: String
		var device: PublicDevice
	}

	private let lock = NSLock()
	private var bearers: [String: String] = [:]
	private var devices: [String: Stored] = [:]
	private var order: [String] = []
	private var queues: [String: [RelayMessage]] = [:]
	private var seq: Int64 = 0
	private(set) var sendCount = 0
	/// The largest ciphertext accepted by `POST /v1/relay/send`, bytes.
	private(set) var largestCiphertext = 0
	static let maxCiphertextBytes = 64 * 1024
	private(set) var registerCount = 0
	private var notifies: [NotifyRequest] = []
	/// What `POST /v1/notify` answers per device id (default `sent`).
	var notifyResults: [String: String] = [:]

	let baseURL = URL(string: "http://127.0.0.1:18080")!

	func addAccount(_ account: String, bearer: String) {
		lock.lock()
		bearers[bearer] = account
		lock.unlock()
	}

	func revoke(_ deviceID: String) {
		lock.lock()
		devices[deviceID]?.device.revoked_at = Int64(Date().timeIntervalSince1970)
		lock.unlock()
	}

	func remove(_ deviceID: String) {
		lock.lock()
		devices[deviceID] = nil
		order.removeAll { $0 == deviceID }
		lock.unlock()
	}

	/// Gives the listed device `id` all the keys (and KEM record) of the device `donor`
	/// registered with, and drops `donor`: a reinstall, or a backend substituting keys.
	func substituteKeys(of id: String, from donor: String) {
		lock.lock()
		defer { lock.unlock() }
		guard var target = devices[id], let source = devices[donor]?.device else { return }
		target.device.link_pubkey = source.link_pubkey
		target.device.link_fp = source.link_fp
		target.device.approve_pubkey = source.approve_pubkey
		target.device.approve_fp = source.approve_fp
		target.device.kem_pubkey = source.kem_pubkey
		devices[id] = target
		devices[donor] = nil
		order.removeAll { $0 == donor }
	}

	/// Replaces only the device's KEM record (`KEMKeyRecord.base64`).
	func setKEMRecord(of id: String, _ record: String) {
		lock.lock()
		devices[id]?.device.kem_pubkey = record
		lock.unlock()
	}

	/// Every accepted `POST /v1/notify` body, in order.
	var notifyCalls: [NotifyRequest] {
		lock.lock()
		defer { lock.unlock() }
		return notifies
	}

	func setNotifyResult(_ deviceID: String, _ result: String) {
		lock.lock()
		notifyResults[deviceID] = result
		lock.unlock()
	}

	func device(_ id: String) -> PublicDevice? {
		lock.lock()
		defer { lock.unlock() }
		return devices[id]?.device
	}

	func devices(ofAccount account: String) -> [PublicDevice] {
		lock.lock()
		defer { lock.unlock() }
		return order.compactMap { devices[$0] }.filter { $0.account == account }.map(\.device)
	}

	/// Puts a message in `to`'s queue as if `from` had sent it, bypassing the account check —
	/// what a malicious or buggy relay could do.
	func inject(from: String, to: String, ciphertext: String) {
		lock.lock()
		seq += 1
		let now = Int64(Date().timeIntervalSince1970)
		queues[to, default: []].append(
			RelayMessage(seq: seq, from: from, ciphertext: ciphertext, expires_at: now + 3600, created_at: now))
		lock.unlock()
	}

	// MARK: LinkTransport

	func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
		throw URLError(.unsupportedURL)
	}

	func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let (status, body) = route(request)
		let response = HTTPURLResponse(
			url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
			headerFields: ["Content-Type": "application/json"])!
		return (body, response)
	}

	private func json<T: Encodable>(_ status: Int, _ value: T) -> (Int, Data) {
		(status, (try? JSONEncoder().encode(value)) ?? Data())
	}

	private func error(_ status: Int, _ code: String) -> (Int, Data) {
		(status, Data(#"{"error":{"code":"\#(code)","message":"\#(code)","type":"auth_error"}}"#.utf8))
	}

	private func route(_ request: URLRequest) -> (Int, Data) {
		lock.lock()
		defer { lock.unlock() }
		let method = request.httpMethod ?? "GET"
		let url = request.url!
		let path = url.path
		let query = Dictionary(
			uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
				($0.name, $0.value ?? "")
			})
		let body = request.httpBody ?? Data()

		if path == "/v1/devices" || path.hasPrefix("/v1/devices/") {
			let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(
				of: "Bearer ", with: "")
			guard let account = bearers[token] else { return error(401, "auth_invalid") }
			switch (method, path) {
			case ("POST", "/v1/devices"):
				guard let req = try? JSONDecoder().decode(RegisterDeviceRequest.self, from: body),
					let link = try? LinkPublicKey(x963Base64: req.link_pubkey)
				else { return error(400, "bad_request") }
				let approveFP = req.approve_pubkey.flatMap { try? LinkPublicKey(x963Base64: $0).fingerprint }
				let device = PublicDevice(
					device_id: LinkCrypto.newDeviceID(), name: req.name, platform: req.platform,
					link_pubkey: req.link_pubkey, approve_pubkey: req.approve_pubkey, kem_pubkey: req.kem_pubkey,
					link_fp: link.fingerprint, approve_fp: approveFP, created_at: Int64(Date().timeIntervalSince1970))
				devices[device.device_id] = Stored(account: account, device: device)
				order.append(device.device_id)
				registerCount += 1
				return json(201, device)
			case ("GET", "/v1/devices"):
				return json(
					200,
					DeviceList(devices: order.compactMap { devices[$0] }.filter { $0.account == account }.map(\.device)))
			case ("DELETE", _):
				let id = String(path.dropFirst("/v1/devices/".count))
				guard devices[id]?.account == account else { return error(404, "not_found") }
				devices[id]?.device.revoked_at = Int64(Date().timeIntervalSince1970)
				return (204, Data())
			default:
				return error(404, "not_found")
			}
		}

		// WL1 routes: the fake trusts X-WL-Device (signature checks are the real server's job and
		// are covered by whispera-backend's tests).
		guard let caller = request.value(forHTTPHeaderField: SignedHeaders.deviceHeader),
			let me = devices[caller]
		else { return error(401, "auth_unknown_device") }
		guard !me.device.isRevoked else { return error(401, "auth_revoked") }
		switch (method, path) {
		case ("GET", "/v1/device/peers"):
			return json(
				200,
				DeviceList(devices: order.compactMap { devices[$0] }.filter { $0.account == me.account }.map(\.device)))
		case ("POST", "/v1/relay/send"):
			guard let req = try? JSONDecoder().decode(RelaySendRequest.self, from: body) else {
				return error(400, "bad_request")
			}
			// The relay's RelayLimits.max_ciphertext_bytes.
			guard let blob = Data(base64Encoded: req.ciphertext), blob.count <= Self.maxCiphertextBytes else {
				return error(413, "too_large")
			}
			largestCiphertext = max(largestCiphertext, blob.count)
			guard let target = devices[req.to], target.account == me.account, !target.device.isRevoked else {
				return error(403, "forbidden")
			}
			seq += 1
			sendCount += 1
			let now = Int64(Date().timeIntervalSince1970)
			queues[req.to, default: []].append(
				RelayMessage(seq: seq, from: caller, ciphertext: req.ciphertext, expires_at: now + 3600, created_at: now))
			return json(201, RelaySendResponse(seq: seq, expires_at: now + 3600))
		case ("GET", "/v1/relay/messages"):
			let after = Int64(query["after"] ?? "0") ?? 0
			return json(200, RelayFetchResponse(messages: (queues[caller] ?? []).filter { $0.seq > after }))
		case ("POST", "/v1/relay/ack"):
			guard let req = try? JSONDecoder().decode(RelayAckRequest.self, from: body) else {
				return error(400, "bad_request")
			}
			let before = queues[caller]?.count ?? 0
			queues[caller]?.removeAll { $0.seq <= req.up_to_seq }
			return json(200, RelayAckResponse(deleted: UInt64(before - (queues[caller]?.count ?? 0))))
		case ("POST", "/v1/notify"):
			// The backend's rules: request_id with every kind, sealed only on approval, no
			// request_id or sealed without a kind.
			guard let req = try? JSONDecoder().decode(NotifyRequest.self, from: body),
				let target = devices[req.device_id], target.account == me.account
			else { return error(400, "bad_request") }
			if req.kind == nil {
				guard req.request_id == nil, req.sealed == nil else { return error(400, "bad_request") }
			} else {
				guard ["approval", "approval.resolved"].contains(req.kind!), let rid = req.request_id,
					LinkCrypto.isValidPrefixedID(rid, prefix: "apr")
				else { return error(400, "bad_request") }
				if req.sealed != nil, req.kind != "approval" { return error(400, "bad_request") }
				if let sealed = req.sealed, sealed.count > 2048 || Data(base64Encoded: sealed) == nil {
					return error(400, "bad_request")
				}
			}
			notifies.append(req)
			return json(200, NotifyResponse(push: notifyResults[req.device_id] ?? "sent"))
		default:
			return error(404, "not_found")
		}
	}
}

/// An iPhone of an account: registers with link, approve and KEM keys and reads its relay queue
/// the way the iOS app does.
final class AccountPhone {
	let backend: FakeAccountBackend
	let linkKey = SoftwareSigningKey()
	let approveKey = SoftwareSigningKey()
	let agreementKey = SoftwareAgreementKey()
	var deviceID = ""
	private var cursor: Int64 = 0

	init(backend: FakeAccountBackend) {
		self.backend = backend
	}

	@discardableResult
	func register(bearer: String, name: String = "Test iPhone") async throws -> PublicDevice {
		let device = try await AccountDeviceRegistration.register(
			baseURL: backend.baseURL, accountToken: bearer, name: name, platform: .ios, linkKey: linkKey,
			approveKey: approveKey.publicKey, agreementKey: agreementKey.publicKey, transport: backend)
		deviceID = device.device_id
		return device
	}

	/// The safety number the iPhone shows for the Mac `macID`, from the keys the account lists.
	func safetyNumber(macID: String) throws -> String {
		guard let mac = backend.device(macID) else { throw RelayError.unknownSender(macID) }
		return SafetyNumber.compute(
			macLink: try LinkPublicKey(x963Base64: mac.link_pubkey), phoneLink: linkKey.publicKey,
			phoneApprove: approveKey.publicKey)
	}

	var relay: RelayClient {
		RelayClient(baseURL: backend.baseURL, deviceID: deviceID, linkKey: linkKey, transport: backend)
	}

	/// New messages, opened against this phone's own account's verified peers.
	func receive() async throws -> [LinkMessage] {
		let client = relay
		let peers = AccountDevices(classifying: try await client.peers(), selfID: deviceID)
		let messages = try await client.messages(after: cursor)
		var out: [LinkMessage] = []
		for message in messages {
			cursor = max(cursor, message.seq)
			out.append(try client.openLinkMessage(message, devices: peers, agreementKey: agreementKey).message)
		}
		return out
	}

	func send(_ message: LinkMessage, toDevice id: String) async throws {
		let client = relay
		let peers = AccountDevices(classifying: try await client.peers(), selfID: deviceID)
		guard let peer = peers.peer(id) else { throw RelayError.unknownSender(id) }
		try await client.send(message, to: peer)
	}
}
