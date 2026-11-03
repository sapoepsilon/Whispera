import Foundation

/// The account-pairing messages devices send each other through the relay, as the
/// plaintext of a `SealedEnvelope`. Flat JSON with a `type` tag and `v: 1`:
///
/// ```
/// {"type":"link_offer","v":1,"helper_device_id":"dev_…","base_urls":["http://…:7443"],
///  "daemon_pubkey":"<x963 b64>","daemon_fp":"<64 hex>","stt_key":"…","mac_name":"…",
///  "approve_confirmed":false}
/// {"type":"approve_confirmed","v":1,"device_id":"dev_…"}
/// {"type":"unpaired","v":1,"device_id":"dev_…"}
/// {"type":"api_request","v":1,"id":"rq_…","method":"GET","target":"/v1/agents","headers":{…},"body":"","stream":false}
/// {"type":"api_response","v":1,"id":"rq_…","part":0,"status":200,"headers":{…},"body":"…","final":true}
/// {"type":"api_cancel","v":1,"id":"rq_…"}
/// {"type":"sas_commit","v":1,"attempt":"sas_…","commitment":"…"}
/// {"type":"sas_nonce","v":1,"attempt":"sas_…","mac_link":"…","mac_nonce":"…"}
/// {"type":"sas_reveal","v":1,"attempt":"sas_…","phone_link":"…","phone_approve":"…","phone_nonce":"…"}
/// ```
///
/// The `api_*` messages carry the LinkAPI over the relay — see `RelayAPI`. The `sas_*` ones fix
/// the safety number — see `SafetyNumber`.
///
/// Receivers accept a message only from a verified peer of their own account
/// (`RelayClient.openLinkMessage`).
public enum LinkMessage: Equatable, Sendable {
	/// Mac → phone: everything the phone needs to talk to the Mac's daemon, no code.
	case linkOffer(LinkOffer)
	/// Mac → phone: the Mac's owner confirmed this phone's approve key (Touch ID).
	/// `deviceID` is the phone's account device id.
	case approveConfirmed(deviceID: String)
	/// Either way: `deviceID` stopped being paired (the sender's own id when it
	/// unpaired itself, the recipient's when the sender dropped it).
	case unpaired(deviceID: String)
	/// Phone → Mac: one WL1-signed LinkAPI request.
	case apiRequest(RelayAPIRequest)
	/// Mac → phone: one frame of the response to `apiRequest`.
	case apiResponse(RelayAPIResponse)
	/// Phone → Mac: stop that stream, or abandon that request.
	case apiCancel(id: String)
	/// Phone → Mac: the commitment that opens a safety-number attempt.
	case sasCommit(SASCommit)
	/// Mac → phone: the Mac's nonce, only after it recorded the commitment.
	case sasNonce(SASNonce)
	/// Phone → Mac: the keys and nonce behind the commitment.
	case sasReveal(SASReveal)

	public static let version = 1

	public var type: String {
		switch self {
		case .linkOffer: return "link_offer"
		case .approveConfirmed: return "approve_confirmed"
		case .unpaired: return "unpaired"
		case .apiRequest: return "api_request"
		case .apiResponse: return "api_response"
		case .apiCancel: return "api_cancel"
		case .sasCommit: return "sas_commit"
		case .sasNonce: return "sas_nonce"
		case .sasReveal: return "sas_reveal"
		}
	}

	/// Sorted-keys JSON.
	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(Wire(self))
	}

	public init(decoding data: Data) throws {
		let head: Head
		do {
			head = try JSONDecoder().decode(Head.self, from: data)
		} catch {
			throw LinkMessageError.malformed("\(error)")
		}
		guard head.v == Self.version else { throw LinkMessageError.unsupportedVersion(head.v) }
		do {
			switch head.type {
			case "link_offer":
				self = .linkOffer(try JSONDecoder().decode(LinkOffer.self, from: data))
			case "approve_confirmed":
				self = .approveConfirmed(deviceID: try JSONDecoder().decode(DeviceIDBody.self, from: data).device_id)
			case "unpaired":
				self = .unpaired(deviceID: try JSONDecoder().decode(DeviceIDBody.self, from: data).device_id)
			case "api_request":
				self = .apiRequest(try JSONDecoder().decode(RelayAPIRequest.self, from: data))
			case "api_response":
				self = .apiResponse(try JSONDecoder().decode(RelayAPIResponse.self, from: data))
			case "api_cancel":
				let id = try JSONDecoder().decode(IDBody.self, from: data).id
				guard RelayAPI.isValidRequestID(id) else { throw LinkMessageError.malformed("api_cancel id") }
				self = .apiCancel(id: id)
			case "sas_commit":
				self = .sasCommit(try JSONDecoder().decode(SASCommit.self, from: data))
			case "sas_nonce":
				self = .sasNonce(try JSONDecoder().decode(SASNonce.self, from: data))
			case "sas_reveal":
				self = .sasReveal(try JSONDecoder().decode(SASReveal.self, from: data))
			default:
				throw LinkMessageError.unknownType(head.type)
			}
		} catch let error as LinkMessageError {
			throw error
		} catch {
			throw LinkMessageError.malformed("\(error)")
		}
	}

	private struct Head: Decodable {
		var type: String
		var v: Int
	}

	private struct DeviceIDBody: Codable {
		var device_id: String
	}

	private struct IDBody: Codable {
		var id: String
	}

	private struct Wire: Encodable {
		let message: LinkMessage
		init(_ message: LinkMessage) { self.message = message }

		enum Keys: String, CodingKey { case type, v, device_id, id }

		func encode(to encoder: Encoder) throws {
			switch message {
			case .linkOffer(let offer): try offer.encode(to: encoder)
			case .apiRequest(let request): try request.encode(to: encoder)
			case .apiResponse(let response): try response.encode(to: encoder)
			case .sasCommit(let commit): try commit.encode(to: encoder)
			case .sasNonce(let nonce): try nonce.encode(to: encoder)
			case .sasReveal(let reveal): try reveal.encode(to: encoder)
			default: break
			}
			var c = encoder.container(keyedBy: Keys.self)
			try c.encode(message.type, forKey: .type)
			try c.encode(LinkMessage.version, forKey: .v)
			switch message {
			case .linkOffer, .apiRequest, .apiResponse, .sasCommit, .sasNonce, .sasReveal: break
			case .approveConfirmed(let id), .unpaired(let id): try c.encode(id, forKey: .device_id)
			case .apiCancel(let id): try c.encode(id, forKey: .id)
			}
		}
	}
}

public enum LinkMessageError: Error, Equatable, Sendable {
	case malformed(String)
	case unsupportedVersion(Int)
	case unknownType(String)
	/// The offer's `daemon_pubkey` does not hash to `daemon_fp`, or is not a key.
	case daemonKeyMismatch
	/// `helper_device_id` is not the device that sent the offer.
	case offerSenderMismatch
	/// No usable `http(s)` base URL.
	case noBaseURL
}

/// `link_offer`: what a Mac sends each verified iPhone of its account.
public struct LinkOffer: Codable, Equatable, Sendable {
	/// The Mac's account device id (the relay sender).
	public var helper_device_id: String
	/// The daemon's reachable base URLs, best first (LAN, Tailscale, …).
	public var base_urls: [String]
	/// X9.63 base64 daemon key — what the phone pins.
	public var daemon_pubkey: String
	public var daemon_fp: String
	/// The STT key for the Mac's speech server, when it shares one.
	public var stt_key: String?
	/// Base URL for STT calls; when absent, the daemon base URL is used.
	public var stt_base_url: String?
	public var mac_name: String
	/// Whether the Mac's owner already confirmed this phone's approve key.
	public var approve_confirmed: Bool
	/// The Mac's owner turned on unencrypted local-network connections, so its plain
	/// `http://` LAN addresses may be used directly. Absent (older Macs) means no.
	public var allow_lan_http: Bool?
	/// When the Mac made this offer (Unix seconds, Mac clock), so a phone can refuse an older
	/// offer replayed after a newer one. Absent from older Macs.
	public var issued_at: Int64?
	/// The Mac signs every direct-path response and SSE event with its daemon key (WL1-RESP,
	/// docs/LINK_RESPONSE_SIGNATURES.md in the Mac app). Sealed in the offer, so a LAN party
	/// cannot strip it: a phone that saw `true` requires the signatures from this Mac. Absent
	/// (older Macs) means unknown, not "doesn't sign".
	public var signs_responses: Bool?

	public init(
		helper_device_id: String, base_urls: [String], daemon_pubkey: String, daemon_fp: String, stt_key: String? = nil,
		stt_base_url: String? = nil, mac_name: String, approve_confirmed: Bool, allow_lan_http: Bool? = nil,
		issued_at: Int64? = nil, signs_responses: Bool? = nil
	) {
		self.helper_device_id = helper_device_id
		self.base_urls = base_urls
		self.daemon_pubkey = daemon_pubkey
		self.daemon_fp = daemon_fp
		self.stt_key = stt_key
		self.stt_base_url = stt_base_url
		self.mac_name = mac_name
		self.approve_confirmed = approve_confirmed
		self.allow_lan_http = allow_lan_http
		self.issued_at = issued_at
		self.signs_responses = signs_responses
	}

	enum CodingKeys: String, CodingKey {
		case helper_device_id, base_urls, daemon_pubkey, daemon_fp, stt_key, stt_base_url, mac_name, approve_confirmed
		case allow_lan_http, issued_at, signs_responses
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(helper_device_id, forKey: .helper_device_id)
		try c.encode(base_urls, forKey: .base_urls)
		try c.encode(daemon_pubkey, forKey: .daemon_pubkey)
		try c.encode(daemon_fp, forKey: .daemon_fp)
		try c.encodeIfPresent(stt_key, forKey: .stt_key)
		try c.encodeIfPresent(stt_base_url, forKey: .stt_base_url)
		try c.encode(mac_name, forKey: .mac_name)
		try c.encode(approve_confirmed, forKey: .approve_confirmed)
		try c.encodeIfPresent(allow_lan_http, forKey: .allow_lan_http)
		try c.encodeIfPresent(issued_at, forKey: .issued_at)
		try c.encodeIfPresent(signs_responses, forKey: .signs_responses)
	}

	/// The `http`/`https` entries of `base_urls`, in order.
	public var baseURLs: [URL] {
		base_urls.compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
	}

	/// The daemon key, checked against `daemon_fp`.
	public func verifiedDaemonKey() throws -> LinkPublicKey {
		guard let key = try? LinkPublicKey(x963Base64: daemon_pubkey), key.fingerprint == daemon_fp.lowercased() else {
			throw LinkMessageError.daemonKeyMismatch
		}
		return key
	}

	/// The `PairingRecord` the phone stores in place of a code pairing.
	///
	/// - Parameters:
	///   - sender: the verified peer the offer came from (`ReceivedLinkMessage.sender`);
	///     it must be `helper_device_id`.
	///   - myDeviceID: this phone's account device id. The Mac pins the phone in its
	///     DeviceRegistry under that same id, so WL1 calls to the daemon sign as it.
	///   - myApproveKey: this phone's approve public key (the one it registered).
	///   - baseURL: which of `baseURLs` to use; Tailscale first when nil.
	public func pairingRecord(
		sender: TrustedDevice, myDeviceID: String, myApproveKey: LinkPublicKey, baseURL: URL? = nil, now: Date = Date()
	) throws -> PairingRecord {
		guard sender.device.device_id == helper_device_id else { throw LinkMessageError.offerSenderMismatch }
		let daemonKey = try verifiedDaemonKey()
		guard let base = baseURL ?? baseURLs.first(where: { Self.isTailscale($0) }) ?? baseURLs.first else { throw LinkMessageError.noBaseURL }
		return PairingRecord(
			deviceID: myDeviceID, baseURL: base, daemonPubkeyB64: daemonKey.x963Base64, daemonFP: daemonKey.fingerprint,
			approveFP: myApproveKey.fingerprint, sttKey: stt_key ?? "",
			sttBaseURL: Self.speechURL(base: base, advertised: stt_base_url), name: mac_name, pairedAt: now)
	}
	private static func isTailscale(_ url: URL) -> Bool {
		let host = url.host ?? ""
		let parts = host.split(separator: ".").compactMap { Int($0) }
		return host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:")
			|| (parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1]))
	}

	private static func speechURL(base: URL, advertised: String?) -> URL {
		// An offer often advertises STT on its first LAN address. Keep a custom speech
		// path, but use the selected Tailscale host/port when both refer to this helper.
		guard var speech = advertised.flatMap(URLComponents.init(string:)) else { return base.appendingPathComponent("v1") }
		if isTailscale(base), let origin = URLComponents(url: base, resolvingAgainstBaseURL: false) {
			speech.scheme = origin.scheme; speech.host = origin.host; speech.port = origin.port
		}
		return speech.url ?? base.appendingPathComponent("v1")
	}
}

/// A `LinkMessage` that opened and came from a verified peer.
public struct ReceivedLinkMessage: Equatable, Sendable {
	/// The relay sequence number — ack up to it once handled.
	public let seq: Int64
	public let sender: TrustedDevice
	public let message: LinkMessage
	/// The envelope's signed `message_id` and `created_at`, so a receiver can drop a message the
	/// relay delivers again under a new sequence number (the envelope stays valid for its max age).
	public let messageID: Data
	public let createdAt: Int64

	public init(seq: Int64, sender: TrustedDevice, message: LinkMessage, messageID: Data = Data(), createdAt: Int64 = 0) {
		self.seq = seq
		self.sender = sender
		self.message = message
		self.messageID = messageID
		self.createdAt = createdAt
	}
}

extension RelayClient {
	/// Seals `message` to a verified peer and sends it.
	@discardableResult
	public func send(_ message: LinkMessage, to recipient: TrustedDevice, ttl: UInt32? = nil) async throws -> RelaySendResponse {
		let envelope = try SealedEnvelope.seal(
			try message.encoded(), from: deviceID, signingKey: linkKey, to: recipient.device.device_id,
			recipientKey: recipient.agreementKey, now: serverNow)
		return try await send(RelaySendRequest(to: recipient.device.device_id, ciphertext: envelope.base64, ttl_s: ttl))
	}

	/// Opens a relayed `LinkMessage`. The sender must be a verified peer in `devices`
	/// (this device's own account, revoked and unverified devices excluded) and the
	/// envelope must be signed by that peer's link key; anything else throws.
	public func openLinkMessage(
		_ relayed: RelayMessage, devices: AccountDevices, agreementKey: LinkAgreementKey
	) throws -> ReceivedLinkMessage {
		guard let sender = devices.peer(relayed.from) else { throw RelayError.unknownSender(relayed.from) }
		let envelope = try SealedEnvelope(base64: relayed.ciphertext)
		guard envelope.senderID == relayed.from else { throw EnvelopeError.badSignature }
		let plaintext = try envelope.open(
			as: deviceID, agreementKey: agreementKey, senderKey: sender.linkKey, now: serverNow)
		return ReceivedLinkMessage(
			seq: relayed.seq, sender: sender, message: try LinkMessage(decoding: plaintext), messageID: envelope.messageID,
			createdAt: envelope.createdAt)
	}
}
