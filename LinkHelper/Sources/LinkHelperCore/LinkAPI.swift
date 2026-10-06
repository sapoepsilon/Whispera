import Foundation
import WhisperaLink
import WhisperaLinkServer

/// The HTTP API (PROTOCOL §5): routing, the §4.3 authentication order, limits and the §13
/// error envelope. Components arrive through `LinkDaemon`; nothing here owns state.
final class LinkAPI: @unchecked Sendable {
	enum Auth { case none, signed, speech }
	enum BodyKind { case json, audio }

	struct Route {
		let name: String
		let auth: Auth
		let body: BodyKind
		var agentID: String?
		var requestID: String?
	}

	static let agentStatuses: Set<String> = ["idle", "working", "blocked", "done", "unknown"]
	static let interruptKeys: Set<String> = ["esc", "ctrl+c"]

	private unowned let daemon: LinkDaemon
	private let verifier: RequestVerifier
	private let rateLimiter = RateLimiter()

	init(daemon: LinkDaemon) {
		self.daemon = daemon
		let devices = daemon.devices
		verifier = RequestVerifier(
			skew: Int64(daemon.config.clockSkew),
			replayCache: ReplayCache(ttl: Int64(2 * daemon.config.clockSkew))
		) {
			devices.lookup($0)
		}
	}

	static func match(_ method: String, _ path: String) -> Route? {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard parts.count >= 3, parts[0].isEmpty, parts[1] == "v1" else { return nil }
		let rest = Array(parts.dropFirst(2))
		switch (method, rest.count, rest[0]) {
		case ("GET", 1, "health"): return Route(name: "health", auth: .none, body: .json)
		case ("POST", 1, "pair"): return Route(name: "pair", auth: .none, body: .json)
		case ("GET", 2, "devices") where rest[1] == "me":
			return Route(name: "devices.me", auth: .signed, body: .json)
		case ("DELETE", 2, "devices") where rest[1] == "me":
			return Route(name: "devices.delete", auth: .signed, body: .json)
		case ("PUT", 3, "devices") where rest[1] == "me" && rest[2] == "apns":
			return Route(name: "devices.apns", auth: .signed, body: .json)
		case ("GET", 1, "agents"): return Route(name: "agents.list", auth: .signed, body: .json)
		case ("POST", 1, "agents"): return Route(name: "agents.start", auth: .signed, body: .json)
		case ("GET", 2, "agents") where !rest[1].isEmpty:
			return Route(name: "agents.get", auth: .signed, body: .json, agentID: rest[1])
		case (_, 3, "agents") where !rest[1].isEmpty:
			let route: String
			switch (method, rest[2]) {
			case ("GET", "output"): route = "agents.output"
			case ("POST", "prompt"): route = "agents.prompt"
			case ("POST", "keys"): route = "agents.keys"
			case ("POST", "interrupt"): route = "agents.interrupt"
			default: return nil
			}
			return Route(name: route, auth: .signed, body: .json, agentID: rest[1])
		case ("GET", 1, "events"): return Route(name: "events", auth: .signed, body: .json)
		case ("GET", 2, "approvals") where rest[1] == "pending":
			return Route(name: "approvals.pending", auth: .signed, body: .json)
		case ("GET", 2, "approvals") where !rest[1].isEmpty:
			return Route(name: "approvals.get", auth: .signed, body: .json, requestID: rest[1])
		case ("POST", 3, "approvals") where !rest[1].isEmpty && rest[2] == "decision":
			return Route(name: "approvals.decision", auth: .signed, body: .json, requestID: rest[1])
		case ("POST", 2, "audio") where rest[1] == "transcriptions":
			return Route(name: "stt.transcriptions", auth: .speech, body: .audio)
		case ("GET", 1, "models"): return Route(name: "stt.models", auth: .speech, body: .json)
		default: return nil
		}
	}

	// MARK: Dispatch

	func handle(_ exchange: HTTPExchange) {
		let requestID = LinkCrypto.hex(LinkCrypto.randomBytes(8))
		let started = Date()
		var deviceID = "-"
		let matched = Self.match(exchange.method, exchange.path)
		let route = matched ?? Route(name: "unknown", auth: .signed, body: .json)
		defer {
			daemon.log(
				"http",
				[
					"device": deviceID, "route": route.name, "status": exchange.status,
					"ms": Int(Date().timeIntervalSince(started) * 1000), "request_id": requestID,
				])
		}
		do {
			let limit = route.body == .audio ? daemon.config.sttMaxUploadBytes : daemon.config.maxJSONBytes
			if route.auth == .none {
				let body = try readBody(exchange, limit: limit)
				if route.name == "health" {
					return send(exchange, 200, health(), requestID: requestID)
				}
				let (out, signature) = try daemon.pairing.handlePair(body)
				return exchange.respond(
					201,
					headers: [
						("X-WL-Request-Id", requestID), (SignedHeaders.serverSignatureHeader, signature),
					], body: out)
			}
			if rateLimiter.isBlocked(exchange.remoteHost) {
				throw APIError(429, "rate_limited", "too many failed authentications; retry in 60 s")
			}
			var body: Data?
			let device: DeviceRecord
			do {
				if route.auth == .speech, exchange.header(SignedHeaders.deviceHeader) == nil,
					let bearer = Self.bearer(exchange)
				{
					guard let found = daemon.devices.matchSTTKey(bearer) else {
						throw APIError(401, "auth_unknown_device", "STT key does not match a paired device")
					}
					device = found
				} else {
					try precheck(exchange)
					body = try readBody(exchange, limit: limit)
					device = try verify(exchange, body: body ?? Data())
				}
			} catch let error as APIError where error.status == 401 {
				rateLimiter.fail(exchange.remoteHost)
				throw error
			}
			deviceID = device.deviceID
			daemon.lastDevice.record(device.deviceID)
			guard matched != nil else { throw APIError(404, "not_found", "no such route") }
			if body == nil { body = try readBody(exchange, limit: limit) }
			try serve(route, exchange: exchange, device: device, body: body ?? Data(), requestID: requestID)
		} catch let error as APIError {
			exchange.respond(error.status, headers: [("X-WL-Request-Id", requestID)], body: error.envelope)
		} catch is HTTPExchange.ConnectionGone {
			exchange.close()
		} catch is HTTPExchange.ReadTimeout {
			exchange.close()
		} catch {
			daemon.log(
				"http.internal",
				[
					"request_id": requestID, "route": route.name,
					"detail": String("\(type(of: error)): \(error)".prefix(160)),
				])
			let failure = APIError(500, "internal", "internal error (request id \(requestID))")
			exchange.respond(500, headers: [("X-WL-Request-Id", requestID)], body: failure.envelope)
		}
	}

	private func send(_ exchange: HTTPExchange, _ status: Int, _ object: [String: Any], requestID: String) {
		exchange.respond(status, headers: [("X-WL-Request-Id", requestID)], body: WireJSON.encode(object))
	}

	static func bearer(_ exchange: HTTPExchange) -> String? {
		guard let value = exchange.header("Authorization"), value.count > 7,
			value.prefix(7).lowercased() == "bearer "
		else {
			return nil
		}
		return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
	}

	/// §5.0 body rules: no chunked bodies, `Content-Length` required on POST/PUT, route limits.
	private func readBody(_ exchange: HTTPExchange, limit: Int) throws -> Data {
		if let encoding = exchange.header("Transfer-Encoding"), encoding.lowercased() != "identity" {
			throw APIError(411, "length_required", "chunked bodies are not accepted; send Content-Length")
		}
		guard let raw = exchange.header("Content-Length") else {
			if exchange.method == "POST" || exchange.method == "PUT" {
				throw APIError(411, "length_required", "Content-Length is required")
			}
			return Data()
		}
		guard !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let length = Int(raw) else {
			throw APIError(400, "bad_request", "bad Content-Length")
		}
		if length > limit { throw APIError(413, "payload_too_large", "body exceeds \(limit) bytes") }
		if length == 0 { return Data() }
		exchange.sendContinueIfExpected()
		do {
			return try exchange.readBody(length)
		} catch is HTTPExchange.ConnectionGone {
			throw APIError(400, "bad_request", "body shorter than Content-Length")
		}
	}

	/// §4.3 steps 1–3, before any body byte is read.
	private func precheck(_ exchange: HTTPExchange) throws {
		let names = [
			SignedHeaders.deviceHeader, SignedHeaders.timestampHeader, SignedHeaders.nonceHeader,
			SignedHeaders.signatureHeader,
		]
		let values = names.map { exchange.header($0) ?? "" }
		guard !values.contains(where: \.isEmpty) else {
			throw APIError(401, "auth_missing", "missing X-WL-* authentication headers")
		}
		switch daemon.devices.lookup(values[0]) {
		case .unknown: throw APIError(401, "auth_unknown_device", "unknown device")
		case .revoked: throw APIError(401, "auth_revoked", "device has been revoked")
		case .active: break
		}
		let now = daemon.now()
		guard let ts = LinkCrypto.parseTimestamp(values[1]) else {
			throw APIError(401, "auth_clock_skew", "timestamp is not an integer", extra: ["server_time": now])
		}
		let offset = ts - Int64(now)
		if offset.magnitude > UInt64(daemon.config.clockSkew) {
			throw APIError(
				401, "auth_clock_skew", "timestamp \(offset.magnitude) s off server time",
				extra: ["server_time": now])
		}
	}

	/// §4.3 steps 5–7.
	private func verify(_ exchange: HTTPExchange, body: Data) throws -> DeviceRecord {
		guard LinkCrypto.isValidNonce(exchange.header(SignedHeaders.nonceHeader) ?? "") else {
			throw APIError(401, "auth_bad_signature", "request signature does not verify")
		}
		let result = verifier.verify(
			method: exchange.method, target: exchange.target, headers: exchange.headerDictionary, body: body,
			now: Int64(daemon.now()))
		switch result {
		case .success(let verified):
			daemon.devices.touch(verified.deviceID)
			guard let device = daemon.devices.get(verified.deviceID) else {
				throw APIError(401, "auth_unknown_device", "unknown device")
			}
			return device
		case .failure(let failure):
			switch failure.code {
			case .authReplay: throw APIError(401, "auth_replay", "nonce already used")
			case .authClockSkew:
				throw APIError(401, "auth_clock_skew", failure.message, extra: ["server_time": daemon.now()])
			case .authRevoked: throw APIError(401, "auth_revoked", "device has been revoked")
			case .authUnknownDevice: throw APIError(401, "auth_unknown_device", "unknown device")
			case .authMissing: throw APIError(401, "auth_missing", "missing X-WL-* authentication headers")
			default: throw APIError(401, "auth_bad_signature", "request signature does not verify")
			}
		}
	}

	// MARK: Routes

	func health() -> [String: Any] {
		[
			"ok": true, "service": "whispera-link", "version": LinkDaemon.version,
			"protocol": LinkDaemon.protocolVersion,
			"daemon_fp": daemon.daemonFP, "server_time": daemon.now(), "herdr": daemon.herdrState(),
			"broker": daemon.approvals.isConnected ? "connected" : "idle",
			"apns": daemon.push.isConfigured ? "configured" : "unconfigured",
			"stt": daemon.speech.isConfigured ? "configured" : "unconfigured", "stt_mode": daemon.speech.mode,
		]
	}

	private func serve(_ route: Route, exchange: HTTPExchange, device: DeviceRecord, body: Data, requestID: String)
		throws
	{
		let json = { (object: [String: Any]) in self.send(exchange, 200, object, requestID: requestID) }
		switch route.name {
		case "devices.me":
			json(["device": (daemon.devices.get(device.deviceID) ?? device).publicJSON])
		case "devices.apns":
			let request = try parseJSON(body)
			guard request.keys.contains("token") else {
				throw APIError(400, "bad_request", "token is required (null clears it)")
			}
			let record: DeviceRecord?
			if request["token"] is NSNull {
				record = try daemon.devices.setAPNs(device.deviceID, token: nil, env: nil)
			} else {
				guard let token = request["token"] as? String, DeviceRegistry.isValidAPNsToken(token) else {
					throw APIError(400, "bad_request", "token must be 64-200 hex chars")
				}
				let env = request["env"]
				if let env, !(env is NSNull), !((env as? String).map(DeviceRegistry.apnsEnvs.contains) ?? false)
				{
					throw APIError(400, "bad_request", "env must be sandbox or production")
				}
				record = try daemon.devices.setAPNs(
					device.deviceID, token: token.lowercased(), env: env as? String)
			}
			json(["device": (record ?? device).publicJSON])
		case "devices.delete":
			daemon.devices.revoke(device.deviceID)
			daemon.log("device.revoked", ["device": device.deviceID, "detail": "self"])
			json(["revoked": true])
		case "agents.list":
			json(try daemon.herdr.listAgents())
		case "agents.get":
			json(try daemon.herdr.getAgent(try agentID(route)))
		case "agents.output":
			let id = try agentID(route)
			let query = try Self.parseQuery(exchange.query)
			let source = query["source"] ?? "recent"
			guard HerdrClient.readSources.contains(source) else {
				throw APIError(
					400, "bad_request",
					"source must be one of \(HerdrClient.readSources.joined(separator: ", "))")
			}
			let linesText = query["lines"] ?? "200"
			guard linesText.allSatisfy(\.isASCII), linesText.allSatisfy(\.isNumber), let lines = Int(linesText),
				(1...2000).contains(lines)
			else { throw APIError(400, "bad_request", "lines must be 1-2000") }
			json(try daemon.herdr.read(id, source: source, lines: lines))
		case "agents.prompt":
			let id = try agentID(route)
			let request = try parseJSON(body)
			guard let text = request["text"] as? String, (1...8000).contains(text.unicodeScalars.count) else {
				throw APIError(400, "bad_request", "text must be 1-8000 characters")
			}
			var wait: (until: [String], timeoutMS: Int)?
			if let raw = request["wait"], !(raw is NSNull) {
				guard let object = raw as? [String: Any] else {
					throw APIError(400, "bad_request", "wait must be an object")
				}
				let until =
					object["until"] == nil
					? ["idle", "done", "blocked"] : (object["until"] as? [String] ?? [])
				guard !until.isEmpty, until.allSatisfy(Self.agentStatuses.contains) else {
					throw APIError(400, "bad_request", "wait.until must list agent statuses")
				}
				let timeout = object["timeout_ms"] == nil ? 30_000 : WireJSON.strictInt(object["timeout_ms"])
				guard let timeout, timeout >= 0 else {
					throw APIError(400, "bad_request", "wait.timeout_ms must be a non-negative integer")
				}
				wait = (until, min(timeout, 30_000))
			}
			daemon.log("agent.prompt", ["device": device.deviceID, "detail": "len=\(text.unicodeScalars.count)"])
			json(try daemon.herdr.prompt(id, text: text, wait: wait))
		case "agents.keys":
			let id = try agentID(route)
			let request = try parseJSON(body)
			guard let keys = request["keys"] as? [String], (1...32).contains(keys.count),
				keys.allSatisfy(Self.isValidKey)
			else {
				throw APIError(400, "bad_request", "keys must list 1-32 key names such as esc, enter or ctrl+c")
			}
			daemon.log("agent.keys", ["device": device.deviceID, "detail": "count=\(keys.count)"])
			json(try daemon.herdr.sendKeys(id, keys: keys))
		case "agents.interrupt":
			let id = try agentID(route)
			let request = body.isEmpty ? [:] : try parseJSON(body)
			let key = request["key"] as? String ?? "esc"
			guard Self.interruptKeys.contains(key) else {
				throw APIError(400, "bad_request", "key must be esc or ctrl+c")
			}
			daemon.log("agent.interrupt", ["device": device.deviceID, "detail": "key=\(key)"])
			json(try daemon.herdr.sendKeys(id, keys: [key]))
		case "agents.start":
			let request = try parseJSON(body)
			guard let name = request["name"] as? String, Self.isValidName(name) else {
				throw APIError(400, "bad_request", "name must be 1-64 letters, digits, '.', '_' or '-'")
			}
			guard let kind = request["kind"] as? String, (1...32).contains(kind.count),
				kind.unicodeScalars.allSatisfy({
					CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
						|| $0 == "-" || $0 == "_"
				})
			else { throw APIError(400, "bad_request", "kind must be a herdr agent kind such as claude or codex") }
			guard let pane = request["pane_id"] as? String, Self.isValidAgentID(pane) else {
				throw APIError(400, "bad_request", "pane_id must be a herdr pane id")
			}
			let args =
				request["args"] == nil || request["args"] is NSNull
				? [] : (request["args"] as? [String] ?? ["\u{0}"])
			guard args.count <= 32, args.allSatisfy({ $0.count <= 1000 && !$0.contains("\u{0}") }) else {
				throw APIError(400, "bad_request", "args must list at most 32 strings")
			}
			let timeout = request["timeout_ms"] == nil ? 30_000 : WireJSON.strictInt(request["timeout_ms"])
			guard let timeout else { throw APIError(400, "bad_request", "timeout_ms must be an integer") }
			daemon.log(
				"agent.start",
				["device": device.deviceID, "detail": "kind=\(kind) pane=\(pane) args=\(args.count)"])
			json(
				try daemon.herdr.start(
					name: name, kind: kind, paneID: pane, args: args,
					timeoutMS: min(max(timeout, 3001), 60_000)))
		case "events":
			try events(exchange, device: device, requestID: requestID)
		case "approvals.pending":
			json(["approvals": daemon.approvals.pending()])
		case "approvals.get":
			json(try daemon.approvals.get(try approvalID(route)))
		case "approvals.decision":
			let id = try approvalID(route)
			let request = try parseJSON(body)
			guard let decision = request["decision"] as? String, decision == "approve" || decision == "deny"
			else {
				throw APIError(400, "bad_request", "decision must be approve or deny")
			}
			json(
				try daemon.approvals.decide(
					id, device: device, decision: decision, signature: request["signature"]))
		case "stt.transcriptions":
			let reply = try daemon.speech.transcribe(
				body: body, contentType: exchange.header("Content-Type"), deviceID: device.deviceID)
			exchange.respond(
				reply.status, contentType: reply.contentType, headers: [("X-WL-Request-Id", requestID)],
				body: reply.body)
		case "stt.models":
			let reply = try daemon.speech.models(deviceID: device.deviceID)
			exchange.respond(
				reply.status, contentType: reply.contentType, headers: [("X-WL-Request-Id", requestID)],
				body: reply.body)
		default:
			throw APIError(404, "not_found", "no such route")
		}
	}

	private func events(_ exchange: HTTPExchange, device: DeviceRecord, requestID: String) throws {
		let (stream, last) = daemon.hub.subscribe(
			deviceID: device.deviceID, lastEventID: exchange.header("Last-Event-ID"))
		defer {
			daemon.hub.unsubscribe(stream)
			exchange.close()
		}
		try exchange.beginStream(
			200,
			headers: [
				("Content-Type", "text/event-stream"), ("Cache-Control", "no-store"),
				("X-WL-Request-Id", requestID),
				("X-Accel-Buffering", "no"),
			])
		let hello: [String: Any] = [
			"v": 1, "server_time": daemon.now(), "device_id": device.deviceID, "last_seq": last,
		]
		try exchange.write(
			Data(("event: hello\ndata: " + String(decoding: WireJSON.encode(hello), as: UTF8.self) + "\n\n").utf8)
		)
		let interval = daemon.config.ssePingInterval
		var nextPing = Date().addingTimeInterval(interval)
		while true {
			switch stream.next(timeout: max(0, nextPing.timeIntervalSinceNow)) {
			case .closed: return
			case .timeout:
				try exchange.write(Data(": ping\n\n".utf8))
				nextPing = Date().addingTimeInterval(interval)
			case .frame(let frame):
				try exchange.write(frame)
			}
		}
	}

	private func parseJSON(_ body: Data) throws -> [String: Any] {
		guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
			throw APIError(400, "bad_request", "body is not valid JSON")
		}
		guard let dictionary = object as? [String: Any] else {
			throw APIError(400, "bad_request", "body must be a JSON object")
		}
		return dictionary
	}

	private func agentID(_ route: Route) throws -> String {
		let decoded = route.agentID?.removingPercentEncoding ?? ""
		guard Self.isValidAgentID(decoded) else { throw APIError(400, "bad_request", "bad agent id") }
		return decoded
	}

	private func approvalID(_ route: Route) throws -> String {
		let id = route.requestID ?? ""
		guard LinkCrypto.isValidPrefixedID(id, prefix: "apr") else {
			throw APIError(400, "bad_request", "bad request id")
		}
		return id
	}

	static func isValidAgentID(_ id: String) -> Bool {
		(1...64).contains(id.utf8.count)
			&& id.unicodeScalars.allSatisfy {
				$0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0))
			}
	}

	static func isValidName(_ name: String) -> Bool {
		(1...64).contains(name.utf8.count)
			&& name.unicodeScalars.allSatisfy {
				$0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
			}
	}

	static func isValidKey(_ key: String) -> Bool {
		(1...32).contains(key.utf8.count)
			&& key.unicodeScalars.allSatisfy {
				$0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+_-".unicodeScalars.contains($0))
			}
	}

	/// `parse_qs(strict_parsing=True, keep_blank_values=True)`, last value wins.
	static func parseQuery(_ query: String) throws -> [String: String] {
		var out: [String: String] = [:]
		guard !query.isEmpty else { return out }
		for piece in query.split(separator: "&", omittingEmptySubsequences: false) {
			let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard pair.count == 2 else { throw APIError(400, "bad_request", "bad query string") }
			func decode(_ part: Substring) -> String? {
				String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
			}
			guard let name = decode(pair[0]), let value = decode(pair[1]) else {
				throw APIError(400, "bad_request", "bad query string")
			}
			out[name] = value
		}
		return out
	}
}
