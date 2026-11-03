import CryptoKit
import Foundation
import WhisperaLink

// An account phone over the E2E relay, for the relay e2e (never the iPhone's keys or account):
//
//   link-soft-phone account-register --state DIR --backend URL --bearer TOKEN [--name N]
//       registers a software-key iOS device on the account; keys go to DIR/account.json.
//   link-soft-phone account-safety --state DIR
//       the account's Mac and the safety number to confirm this phone with on it.
//   link-soft-phone relay --state DIR [--timeout S] METHOD TARGET [JSON]
//       one WL1-signed request through the relay only; prints {"status","ms",…}.
//   link-soft-phone relay-upload --state DIR --path FILE [--image] [--name N]
//       a chunked POST /v1/files/{id} (or /v1/images/{id}) upload; prints the id and timings.
//   link-soft-phone relay-dictate --state DIR --audio FILE [--language L] [--translate]
//       the audio as a chunked file upload, then POST /v1/audio/transcriptions/file
//       (--multipart: the direct multipart body as one relayed request instead).
//   link-soft-phone relay-events --state DIR [--target /v1/events] [--seconds S]
//       an SSE route (events, terminal) as a relayed stream; prints the events that arrived.

struct AccountPhone {
	let backend: URL
	let deviceID: String
	let link: SoftwareSigningKey
	let approve: SoftwareSigningKey
	let agreement: SoftwareAgreementKey

	static func file(_ state: URL) -> URL { state.appendingPathComponent("account.json") }

	init(state: URL) throws {
		let saved = object(try Data(contentsOf: Self.file(state)))
		guard let backend = (saved["backend"] as? String).flatMap(URL.init(string:)), let id = saved["device_id"] as? String,
			let link = saved["link_key_pem"] as? String, let approve = saved["approve_key_pem"] as? String,
			let agreement = (saved["agreement_key"] as? String).flatMap({ Data(base64Encoded: $0) })
		else { throw Failure(description: "no account phone in \(state.path); run account-register") }
		self.backend = backend
		deviceID = id
		self.link = try SoftwareSigningKey(pkcs8PEM: link)
		self.approve = try SoftwareSigningKey(pkcs8PEM: approve)
		self.agreement = SoftwareAgreementKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement))
	}

	var relay: RelayClient { RelayClient(baseURL: backend, deviceID: deviceID, linkKey: link) }

	func devices() async throws -> AccountDevices {
		AccountDevices(classifying: try await relay.peers(), selfID: deviceID)
	}

	/// The account's Mac: `WLP_MAC` (a device id or a name) picks one when there are several.
	func mac() async throws -> TrustedDevice {
		let wanted = ProcessInfo.processInfo.environment["WLP_MAC"] ?? ""
		let macs = try await devices().macs
		guard let mac = macs.first(where: { wanted.isEmpty || $0.id == wanted || $0.name == wanted }) else {
			throw Failure(description: "no Mac \(wanted) on the account: \(macs.map(\.name))")
		}
		return mac
	}
}

func accountRegister(_ args: [String], state: URL) async throws {
	guard let backend = argument("--backend", args).flatMap(URL.init(string:)), let bearer = argument("--bearer", args) else {
		throw Failure(description: "account-register needs --backend URL --bearer TOKEN")
	}
	let link = SoftwareSigningKey(), approve = SoftwareSigningKey(), agreement = SoftwareAgreementKey()
	let device = try await AccountDeviceRegistration.register(
		baseURL: backend, accountToken: bearer, name: argument("--name", args) ?? "Relay Soft Phone", platform: .ios,
		linkKey: link, approveKey: approve.publicKey, agreementKey: agreement.publicKey)
	try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
	let saved: [String: Any] = [
		"backend": backend.absoluteString, "device_id": device.device_id, "link_key_pem": link.privateKey.pemRepresentation,
		"approve_key_pem": approve.privateKey.pemRepresentation,
		"agreement_key": agreement.privateKey.rawRepresentation.base64EncodedString(),
	]
	let file = AccountPhone.file(state)
	try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: file)
	chmod(file.path, 0o600)
	print(String(decoding: try JSONSerialization.data(withJSONObject: ["device_id": device.device_id]), as: UTF8.self))
}

/// Runs the committed exchange with the Mac (commit, wait for its nonce, reveal) the way the
/// iPhone does, then prints the number both screens show.
func accountSafety(state: URL) async throws {
	let phone = try AccountPhone(state: state)
	let mac = try await phone.mac()
	let relay = phone.relay
	let account = try await phone.devices()
	var after = try await relay.messages(after: 0, limit: 100).map(\.seq).max() ?? 0
	var attempt = SASInitiator(
		phoneID: phone.deviceID, macID: mac.id, phoneLink: phone.link.publicKey, phoneApprove: phone.approve.publicKey)
	try await relay.send(.sasCommit(attempt.commit), to: mac)
	let deadline = Date().addingTimeInterval(60)
	var reveal: SASReveal?
	while reveal == nil, Date() < deadline {
		for relayed in try await relay.messages(after: after, limit: 100) {
			after = max(after, relayed.seq)
			guard relayed.from == mac.id,
				let opened = try? relay.openLinkMessage(relayed, devices: account, agreementKey: phone.agreement),
				case .sasNonce(let nonce) = opened.message, nonce.attempt == attempt.attempt
			else { continue }
			reveal = try attempt.receive(nonce, listedMacLink: mac.linkKey)
			break
		}
		if reveal == nil { try await Task.sleep(nanoseconds: 500_000_000) }
	}
	guard let reveal, let number = attempt.number else {
		throw Failure(description: "the Mac did not answer the safety-number commitment; update Whispera on it")
	}
	try await relay.send(.sasReveal(reveal), to: mac)
	print(String(decoding: try JSONSerialization.data(withJSONObject: [
		"device_id": phone.deviceID, "mac_id": mac.id, "safety_number": number,
	], options: [.sortedKeys]), as: UTF8.self))
}

/// A relay-only `LinkClient` with its mailbox running, for one command.
struct RelaySession {
	let phone: AccountPhone
	let mailbox: RelayMailbox
	let transport: RelayLinkTransport
	let client: LinkClient

	init(state: URL) async throws {
		phone = try AccountPhone(state: state)
		let mac = try await phone.mac()
		let relay = phone.relay
		let account = try await phone.devices()
		let cursor = Cursor()
		// Start after whatever is queued already: old responses are no one's.
		let queued = try await relay.messages(after: 0, limit: 100)
		await cursor.set(queued.map(\.seq).max() ?? 0)
		mailbox = RelayMailbox(
			client: relay, agreementKey: phone.agreement, devices: { _ in account }, wait: 10,
			loadCursor: { await cursor.get() })
		await mailbox.start()
		transport = RelayLinkTransport(mailbox: mailbox, mac: mac)
		client = LinkClient(
			baseURL: RelayAPI.placeholderBaseURL(macDeviceID: mac.id), deviceID: phone.deviceID, linkKey: phone.link,
			daemonPubkey: Data(), transport: transport)
	}

	actor Cursor {
		var value: Int64 = 0
		func set(_ new: Int64) { value = new }
		func get() -> Int64 { value }
	}

	/// One signed call; returns the status, body and milliseconds.
	func call(_ method: String, _ target: String, body: Data? = nil, timeout: TimeInterval = 60) async throws
		-> (status: Int, body: Data, contentType: String?, ms: Int)
	{
		let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
		let query: [(String, String)] = (parts.count > 1 ? parts[1] : "").split(separator: "&").map {
			let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
			return (pair[0], pair.count > 1 ? pair[1] : "")
		}
		let request = try client.signedRequest(method: method, path: parts[0], query: query, body: body, timeout: timeout)
		let started = Date()
		let (data, response) = try await transport.data(for: request)
		return (response.statusCode, data, response.value(forHTTPHeaderField: "Content-Type"), Int(Date().timeIntervalSince(started) * 1000))
	}

	/// The chunked upload the iPhone uses: 24 KB per signed request, in order.
	func upload(_ data: Data, name: String, image: Bool) async throws -> (id: String, ms: Int, chunks: Int) {
		let id = UUID().uuidString.lowercased()
		let started = Date()
		var offset = 0, chunks = 0
		while offset < data.count {
			let chunk = data.subdata(in: offset..<min(offset + 24 * 1024, data.count))
			var fields: [String: Any] = ["total_bytes": data.count, "offset": offset, "data": chunk.base64EncodedString()]
			if image { fields["mime_type"] = name.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg" } else { fields["name"] = name }
			let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
			let answer = try await call("POST", (image ? "/v1/images/" : "/v1/files/") + id, body: body, timeout: 30)
			guard answer.status == 200 else {
				throw Failure(description: "chunk at \(offset): \(answer.status) \(String(decoding: answer.body, as: UTF8.self))")
			}
			offset += chunk.count
			chunks += 1
		}
		return (id, Int(Date().timeIntervalSince(started) * 1000), chunks)
	}

	func stop() async { await mailbox.stop() }
}

func printJSON(_ object: [String: Any]) {
	print(String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
}

func shown(_ data: Data, contentType: String?) -> Any {
	if contentType?.hasPrefix("application/json") == true, let json = try? JSONSerialization.jsonObject(with: data) { return json }
	if contentType?.hasPrefix("text/") == true { return String(decoding: data.prefix(2000), as: UTF8.self) }
	return "<\(data.count) bytes>"
}

func relayCall(_ args: [String], state: URL) async throws {
	let skip = Set(["--state", "--timeout"].compactMap { argument($0, args) })
	let positional = args.filter { !$0.hasPrefix("--") && !skip.contains($0) }
	guard positional.count >= 2 else { throw Failure(description: "relay needs METHOD TARGET [JSON]") }
	let session = try await RelaySession(state: state)
	defer { Task { await session.stop() } }
	let body = positional.count > 2 ? Data(positional[2].utf8) : (["POST", "PUT"].contains(positional[0]) ? Data("{}".utf8) : nil)
	let timeout = argument("--timeout", args).flatMap(Double.init) ?? 60
	do {
		let answer = try await session.call(positional[0], positional[1], body: body, timeout: timeout)
		printJSON([
			"status": answer.status, "ms": answer.ms, "bytes": answer.body.count, "content_type": answer.contentType ?? "",
			"json": shown(answer.body, contentType: answer.contentType),
		])
	} catch {
		printJSON(["status": 0, "error": "\(error)"])
	}
}

func relayUpload(_ args: [String], state: URL) async throws {
	guard let path = argument("--path", args) else { throw Failure(description: "relay-upload needs --path FILE") }
	let data = try Data(contentsOf: URL(fileURLWithPath: path))
	let session = try await RelaySession(state: state)
	defer { Task { await session.stop() } }
	let image = args.contains("--image")
	let done = try await session.upload(data, name: argument("--name", args) ?? (path as NSString).lastPathComponent, image: image)
	printJSON(["id": done.id, "bytes": data.count, "chunks": done.chunks, "ms": done.ms, "kind": image ? "image" : "file"])
}

func relayDictate(_ args: [String], state: URL) async throws {
	guard let path = argument("--audio", args) else { throw Failure(description: "relay-dictate needs --audio FILE") }
	let audio = try Data(contentsOf: URL(fileURLWithPath: path))
	let session = try await RelaySession(state: state)
	defer { Task { await session.stop() } }
	let health = try await session.call("GET", "/v1/health", timeout: 30)
	let capabilities = (try? JSONSerialization.jsonObject(with: health.body) as? [String: Any])?["capabilities"] as? [String] ?? []
	let route = args.contains("--translate") ? "/v1/audio/translations" : "/v1/audio/transcriptions"
	if args.contains("--multipart") {
		// The direct route's body, as one relayed request: only a clip that fits one envelope.
		let boundary = "wlsp" + UUID().uuidString.prefix(8)
		var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhispera-mac\r\n".utf8)
		body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
		body.append(audio)
		body.append(Data("\r\n--\(boundary)--\r\n".utf8))
		var request = try session.client.signedRequest(method: "POST", path: route, body: body, timeout: 125)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		let started = Date()
		do {
			let (data, response) = try await session.transport.data(for: request)
			printJSON(["status": response.statusCode, "ms": Int(Date().timeIntervalSince(started) * 1000), "audio_bytes": audio.count,
				"json": shown(data, contentType: response.value(forHTTPHeaderField: "Content-Type"))])
		} catch {
			printJSON(["status": 0, "audio_bytes": audio.count, "error": "\(error)"])
		}
		return
	}
	guard capabilities.contains("audio_by_file") else {
		printJSON(["status": 0, "error": "this Mac's helper has no audio_by_file; dictation over the relay needs a newer helper"])
		return
	}
	let upload = try await session.upload(audio, name: "dictation." + ((path as NSString).pathExtension.isEmpty ? "wav" : (path as NSString).pathExtension), image: false)
	var request: [String: Any] = ["file_id": upload.id, "response_format": "verbose_json"]
	if let language = argument("--language", args) { request["language"] = language }
	let answer = try await session.call("POST", route + "/file", body: try JSONSerialization.data(withJSONObject: request), timeout: 125)
	let json = (try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]) ?? [:]
	printJSON([
		"status": answer.status, "audio_bytes": audio.count, "chunks": upload.chunks, "upload_ms": upload.ms,
		"transcribe_ms": answer.ms, "text": json["text"] ?? String(decoding: answer.body, as: UTF8.self),
		"language": json["language"] ?? NSNull(),
	])
}

func relayEvents(_ args: [String], state: URL) async throws {
	let seconds = argument("--seconds", args).flatMap(Double.init) ?? 5
	let session = try await RelaySession(state: state)
	defer { Task { await session.stop() } }
	let target = argument("--target", args) ?? "/v1/events"
	let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
	let query: [(String, String)] = (parts.count > 1 ? parts[1] : "").split(separator: "&").map {
		let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
		return (pair[0], pair.count > 1 ? pair[1] : "")
	}
	let request = try session.client.signedRequest(method: "GET", path: parts[0], query: query, timeout: 7 * 24 * 3600)
	var accept = request
	accept.setValue("text/event-stream", forHTTPHeaderField: "Accept")
	let started = Date()
	let (bytes, response) = try await session.transport.stream(for: accept)
	let headMS = Int(Date().timeIntervalSince(started) * 1000)
	var text = Data()
	let reader = Task {
		for try await byte in bytes { text.append(byte) }
	}
	try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	reader.cancel()
	let body = String(decoding: text, as: UTF8.self)
	let events = body.components(separatedBy: "\n").filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) }
	printJSON(["status": response.statusCode, "head_ms": headMS, "events": events, "bytes": text.count])
}
