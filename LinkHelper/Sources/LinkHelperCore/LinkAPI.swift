import Foundation
import WhisperaHerdr
import WhisperaAgents
import WhisperaLink
import WhisperaLinkServer

/// The HTTP API (PROTOCOL §5): routing, the §4.3 authentication order, limits and the §13
/// error envelope. Components arrive through `LinkDaemon`; nothing here owns state.
final class LinkAPI: @unchecked Sendable {
	enum Auth { case none, signed }
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
	/// Background traffic: these signed routes do not make their device the `last_device`.
	static let promptReadyWait: TimeInterval = 15
	static let backgroundRoutes: Set<String> = ["events", "devices.apns", "devices.push"]
	/// All an authenticated device the owner has not confirmed yet may do: read its own record
	/// (to learn it is unconfirmed) and unpair itself.
	static let unconfirmedRoutes: Set<String> = ["devices.me", "devices.delete"]
	/// Writes that finish once started, even when the phone stops waiting: a stop or interrupt
	/// cut halfway leaves the agent in between, and an answer or a decision is one keystroke the
	/// phone already committed to. Every other route stops when its phone goes away.
	static let uncancellableRoutes: Set<String> = [
		"agents.keys", "agents.interrupt", "agents.stop", "agents.remove", "agents.permission.answer",
		"agents.ask.answer", "approvals.decision", "devices.delete", "devices.apns", "devices.push",
		"notifications.prefs.put",
	]

	/// Weak: an HTTP or relay request can still be in flight when the helper goes away (a test
	/// stopping its daemon, a probe answered late). `handle` holds it for the whole request and
	/// drops a request that arrives after it is gone.
	private weak var owner: LinkDaemon?
	private var daemon: LinkDaemon {
		guard let owner else { preconditionFailure("LinkAPI used outside a request after its daemon went away") }
		return owner
	}
	private let verifier: RequestVerifier
	private let rateLimiter = RateLimiter()
	/// `/v1/link/peer` only: 12 hellos a minute per address.
	private let peerLimiter = RateLimiter(limit: 12, window: 60, blockFor: 60)
	private let submissions: AgentSubmissions
	private var recipes: MacRecipeService { daemon.recipes }

	init(daemon: LinkDaemon) {
		owner = daemon
		submissions = AgentSubmissions(stateDirectory: daemon.config.paths.stateDir)
		let log = daemon.log
		submissions.startSweeping { partials, expired in
			log("uploads.swept", ["detail": "partials=\(partials) expired=\(expired)"])
		}
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
		case ("POST", 2, "pair") where rest[1] == "commit":
			return Route(name: "pair.commit", auth: .none, body: .json)
		case ("GET", 2, "link") where rest[1] == "peer":
			return Route(name: "link.peer", auth: .none, body: .json)
		case ("GET", 2, "account") where rest[1] == "vouches":
			return Route(name: "account.vouches", auth: .signed, body: .json)
		case ("GET", 2, "devices") where rest[1] == "me":
			return Route(name: "devices.me", auth: .signed, body: .json)
		case ("DELETE", 2, "devices") where rest[1] == "me":
			return Route(name: "devices.delete", auth: .signed, body: .json)
		case ("PUT", 3, "devices") where rest[1] == "me" && rest[2] == "apns":
			return Route(name: "devices.apns", auth: .signed, body: .json)
		case ("PUT", 3, "devices") where rest[1] == "me" && rest[2] == "push":
			return Route(name: "devices.push", auth: .signed, body: .json)
		case ("GET", 2, "notifications") where rest[1] == "prefs":
			return Route(name: "notifications.prefs.get", auth: .signed, body: .json)
		case ("PUT", 2, "notifications") where rest[1] == "prefs":
			return Route(name: "notifications.prefs.put", auth: .signed, body: .json)
		case ("GET", 1, "recipes"): return Route(name: "recipes.list", auth: .signed, body: .json)
		case ("POST", 2, "text") where rest[1] == "translate":
			return Route(name: "text.translate", auth: .signed, body: .json)
		case ("POST", 3, "recipes") where rest[2] == "run":
			return Route(name: "recipes.run", auth: .signed, body: .json, requestID: rest[1])
		case ("GET", 1, "agents"): return Route(name: "agents.list", auth: .signed, body: .json)
		case ("POST", 1, "agents"): return Route(name: "agents.start", auth: .signed, body: .json)
		case ("GET", 2, "agents") where !rest[1].isEmpty:
			return Route(name: "agents.get", auth: .signed, body: .json, agentID: rest[1])
		case ("DELETE", 2, "agents") where !rest[1].isEmpty:
			return Route(name: "agents.remove", auth: .signed, body: .json, agentID: rest[1])
		case (_, 3, "agents") where !rest[1].isEmpty:
			let route: String
			switch (method, rest[2]) {
			case ("GET", "output"): route = "agents.output"
			case ("GET", "diff"): route = "agents.diff"
			case ("GET", "files"): route = "agents.files"
			case ("GET", "file"): route = "agents.file"
			case ("GET", "mac-file"): route = "agents.mac_file"
			case ("POST", "prompt"): route = "agents.prompt"
			case ("POST", "keys"): route = "agents.keys"
			case ("POST", "interrupt"): route = "agents.interrupt"
			case ("POST", "stop"): route = "agents.stop"
			case ("GET", "permission"): route = "agents.permission"
			case ("POST", "permission"): route = "agents.permission.answer"
			case ("GET", "ask"): route = "agents.ask"
			case ("POST", "ask"): route = "agents.ask.answer"
			case ("GET", "dialog"): route = "agents.dialog"
			case ("POST", "dialog"): route = "agents.dialog.answer"
			case ("GET", "transcript"): route = "agents.transcript"
			case ("GET", "terminal"): route = "agents.terminal"
			default: return nil
			}
			return Route(name: route, auth: .signed, body: .json, agentID: rest[1])
		case ("GET", 5, "agents") where !rest[1].isEmpty && rest[2] == "subagents" && !rest[3].isEmpty && rest[4] == "transcript":
			return Route(name: "agents.subagent.transcript", auth: .signed, body: .json, agentID: rest[1], requestID: rest[3])
		case ("GET", 4, "agents") where !rest[1].isEmpty && rest[2] == "terminal" && rest[3] == "ws":
			return Route(name: "agents.terminal.ws", auth: .signed, body: .json, agentID: rest[1])
		case ("POST", 4, "agents") where !rest[1].isEmpty && rest[2] == "terminal":
			switch rest[3] {
			case "input": return Route(name: "agents.terminal.input", auth: .signed, body: .json, agentID: rest[1])
			case "resize": return Route(name: "agents.terminal.resize", auth: .signed, body: .json, agentID: rest[1])
			default: return nil
			}
		case ("POST", 2, "images") where !rest[1].isEmpty:
			return Route(name: "images.upload", auth: .signed, body: .json, requestID: rest[1])
		case ("POST", 2, "files") where !rest[1].isEmpty:
			return Route(name: "files.upload", auth: .signed, body: .json, requestID: rest[1])
		case ("DELETE", 2, "images") where !rest[1].isEmpty:
			return Route(name: "images.abort", auth: .signed, body: .json, requestID: rest[1])
		case ("DELETE", 2, "files") where !rest[1].isEmpty:
			return Route(name: "files.abort", auth: .signed, body: .json, requestID: rest[1])
		case ("GET", 1, "permissions"): return Route(name: "permissions.list", auth: .signed, body: .json)
		case ("GET", 1, "asks"): return Route(name: "asks.list", auth: .signed, body: .json)
		case ("GET", 1, "events"): return Route(name: "events", auth: .signed, body: .json)
		case ("GET", 2, "approvals") where rest[1] == "pending":
			return Route(name: "approvals.pending", auth: .signed, body: .json)
		case ("GET", 2, "approvals") where !rest[1].isEmpty:
			return Route(name: "approvals.get", auth: .signed, body: .json, requestID: rest[1])
		case ("POST", 3, "approvals") where !rest[1].isEmpty && rest[2] == "decision":
			return Route(name: "approvals.decision", auth: .signed, body: .json, requestID: rest[1])
		case ("POST", 3, "audio") where rest[2] == "file" && ["transcriptions", "translations"].contains(rest[1]):
			return Route(name: "stt.file." + rest[1], auth: .signed, body: .json)
		case ("POST", 2, "audio") where rest[1] == "transcriptions":
			return Route(name: "stt.transcriptions", auth: .signed, body: .audio)
		case ("POST", 2, "audio") where rest[1] == "translations":
			return Route(name: "stt.translations", auth: .signed, body: .audio)
		case ("GET", 1, "models"): return Route(name: "stt.models", auth: .signed, body: .json)
		default: return nil
		}
	}

	// MARK: Dispatch

	func handle(_ exchange: LinkExchange) {
		guard let held = owner else {
			exchange.close()
			return
		}
		withExtendedLifetime(held) { handleHeld(exchange) }
	}

	private func handleHeld(_ exchange: LinkExchange) {
		let requestID = LinkCrypto.hex(LinkCrypto.randomBytes(8))
		let started = Date()
		var deviceID = "-"
		let matched = Self.match(exchange.method, exchange.path)
		let route = matched ?? Route(name: "unknown", auth: .signed, body: .json)
		let relaySender = exchange.relaySender
		defer {
			var fields: [String: Any?] = [
				"device": deviceID, "route": route.name, "status": exchange.status,
				"ms": Int(Date().timeIntervalSince(started) * 1000), "request_id": requestID,
			]
			if relaySender != nil { fields["via"] = "relay" }
			daemon.log("http", fields)
		}
		do {
			let limit = route.body == .audio ? daemon.config.sttMaxUploadBytes : daemon.config.maxJSONBytes
			// Over the relay only health and the signed routes exist: pairing needs the code
			// on a direct connection.
			if relaySender != nil, matched != nil, route.name != "health", route.auth == .none {
				throw APIError(404, "not_found", "not available over the relay")
			}
			if route.auth == .none {
				if route.name == "health" {
					return try serveHealth(exchange, limit: limit, requestID: requestID, deviceID: &deviceID)
				}
				if route.name == "link.peer" {
					return try peerHello(exchange, limit: limit, requestID: requestID)
				}
				if rateLimiter.isBlocked(exchange.remoteHost) {
					throw APIError(429, "rate_limited", "too many failed attempts; retry in 60 s")
				}
				let out: Data
				let signature: String
				do {
					let body = try readBody(exchange, limit: limit)
					if route.name == "pair.commit" {
						(out, signature) = try daemon.pairing.handleCommit(body, from: exchange.remoteHost)
					} else {
						(out, signature) = try daemon.pairing.handlePair(body, from: exchange.remoteHost)
					}
				} catch let error as APIError where (400..<500).contains(error.status) {
					rateLimiter.fail(exchange.remoteHost)
					throw error
				}
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
				// The envelope already proves who sent a relayed request; it must be the device
				// that signed it.
				if let relaySender, exchange.header(SignedHeaders.deviceHeader) != relaySender {
					throw APIError(401, "auth_unknown_device", "X-WL-Device is not the relay sender")
				}
				// Speech routes too: a bare STT bearer is a replayable secret over plain HTTP, so
				// only a signed request (fresh nonce, bound to this exact body) is served.
				try precheck(exchange)
				body = try readBody(exchange, limit: limit)
				device = try verify(exchange, body: body ?? Data())
			} catch let error as APIError where error.status == 401 {
				rateLimiter.fail(exchange.remoteHost)
				throw error
			}
			deviceID = device.deviceID
			guard matched != nil else { throw APIError(404, "not_found", "no such route") }
			// Re-read: a confirmation or a key change since the lookup counts.
			let current = daemon.devices.get(device.deviceID) ?? device
			if !current.approveConfirmed, !Self.unconfirmedRoutes.contains(route.name) {
				throw APIError(
					403, "device_unconfirmed",
					"confirm this device on the Mac (compare the safety number) before it can be used")
			}
			if current.approveConfirmed, !Self.backgroundRoutes.contains(route.name) {
				daemon.lastDevice.record(device.deviceID)
			}
			if body == nil { body = try readBody(exchange, limit: limit) }
			// The WebSocket reads the connection itself; every other request is read by now.
			if route.name != "agents.terminal.ws" { exchange.watchForDisconnect() }
			let served = body ?? Data()
			try CancelToken.with(exchange.cancelToken) {
				if Self.uncancellableRoutes.contains(route.name) {
					try CancelToken.withoutCancellation {
						try serve(route, exchange: exchange, device: current, body: served, requestID: requestID)
					}
				} else {
					try CancelToken.checkCurrent()
					try serve(route, exchange: exchange, device: current, body: served, requestID: requestID)
				}
			}
		} catch let cancelled as RequestCancelled {
			daemon.log("http.cancelled", ["device": deviceID, "route": route.name, "request_id": requestID, "detail": cancelled.reason])
			exchange.close()
		} catch let error as APIError {
			// A step that was stopped by the cancel may surface as its own error (a killed ssh
			// reads as an unreachable machine); no one waits for the answer either way.
			if exchange.status == 0, let reason = exchange.cancelToken.reason {
				daemon.log("http.cancelled", ["device": deviceID, "route": route.name, "request_id": requestID, "detail": reason])
				return exchange.close()
			}
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

	/// Unsigned, only what a phone needs before it is paired (that this is a helper, its protocol,
	/// the key it pins and the clock it signs against); a signed request gets the full status.
	private func serveHealth(_ exchange: LinkExchange, limit: Int, requestID: String, deviceID: inout String) throws {
		guard exchange.header(SignedHeaders.deviceHeader) != nil else {
			_ = try readBody(exchange, limit: limit)
			return send(exchange, 200, publicHealth(), requestID: requestID)
		}
		if rateLimiter.isBlocked(exchange.remoteHost) {
			throw APIError(429, "rate_limited", "too many failed authentications; retry in 60 s")
		}
		do {
			if let relaySender = exchange.relaySender, exchange.header(SignedHeaders.deviceHeader) != relaySender {
				throw APIError(401, "auth_unknown_device", "X-WL-Device is not the relay sender")
			}
			try precheck(exchange)
			let body = try readBody(exchange, limit: limit)
			deviceID = try verify(exchange, body: body).deviceID
		} catch let error as APIError where error.status == 401 {
			rateLimiter.fail(exchange.remoteHost)
			throw error
		}
		send(exchange, 200, health(), requestID: requestID)
	}

	func publicHealth() -> [String: Any] {
		// daemon_fp and server_time stay: the phone's pairing pins the key from here and learns
		// the clock offset before its first signed request.
		["ok": true, "protocol": LinkDaemon.protocolVersion, "daemon_fp": daemon.daemonFP, "server_time": daemon.now()]
	}

	/// Another helper of this account says hello (`AccountCircle.hello`). Anyone else gets a
	/// plain 404. Its own limiter: every hello counts (each may run `tailscale whois`), and it
	/// never touches the pairing limiter.
	private func peerHello(_ exchange: LinkExchange, limit: Int, requestID: String) throws {
		if peerLimiter.isBlocked(exchange.remoteHost) {
			throw APIError(429, "rate_limited", "too many hellos; retry in 60 s")
		}
		peerLimiter.fail(exchange.remoteHost)
		_ = try readBody(exchange, limit: limit)
		guard let proof = daemon.circle.hello(Self.queryItems(exchange.query), caller: exchange.remoteHost) else {
			throw APIError(404, "not_found", "no such route")
		}
		exchange.respond(200, headers: [("X-WL-Request-Id", requestID)], body: proof)
	}

	static func queryItems(_ query: String) -> [String: String] {
		var out: [String: String] = [:]
		for pair in query.split(separator: "&") {
			let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
			guard let name = parts.first?.removingPercentEncoding, out[name] == nil else { continue }
			out[name] = parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : ""
		}
		return out
	}

	private func send(_ exchange: LinkExchange, _ status: Int, _ object: [String: Any], requestID: String) {
		exchange.respond(status, headers: [("X-WL-Request-Id", requestID)], body: WireJSON.encode(object))
	}

	/// §5.0 body rules: no chunked bodies, `Content-Length` required on POST/PUT, route limits.
	private func readBody(_ exchange: LinkExchange, limit: Int) throws -> Data {
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
	private func precheck(_ exchange: LinkExchange) throws {
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
	private func verify(_ exchange: LinkExchange, body: Data) throws -> DeviceRecord {
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
			"protocol": LinkDaemon.protocolVersion, "capabilities": ["prompt_receipts", "image_uploads", "file_uploads", "recipes", "herdr_tui", "agent_permissions", "agent_asks", "code_reader", "agent_transcript", "agent_subagents", "notification_prefs", "terminal_beta", "device_vouches", "agents_remove", "audio_translations", "text_translate", "mac_files", "uploads_abort", "agent_dialogs", "audio_by_file", "herdr_core"],
			"daemon_fp": daemon.daemonFP, "server_time": daemon.now(), "herdr": daemon.herdrState(), "hc": daemon.hcState(),
			"broker": daemon.approvals.isConnected ? "connected" : "idle",
			"apns": daemon.push.isConfigured ? "configured" : "unconfigured",
			"stt": daemon.speech.isConfigured ? "configured" : "unconfigured", "stt_mode": daemon.speech.mode,
		]
	}

	private func serve(_ route: Route, exchange: LinkExchange, device: DeviceRecord, body: Data, requestID: String)
		throws
	{
		let json = { (object: [String: Any]) in self.send(exchange, 200, object, requestID: requestID) }
		switch route.name {
		case "account.vouches":
			let vouches = daemon.circle.publishedVouches().compactMap { vouch -> Any? in
				(try? JSONEncoder().encode(vouch)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
			}
			json(["vouches": vouches])
		case "images.upload":
			guard let id = route.requestID else { throw APIError(400, "bad_request", "missing image id") }
			json(try submissions.upload(id, device: device.deviceID, request: parseJSON(body)))
		case "files.upload":
			guard let id = route.requestID else { throw APIError(400, "bad_request", "missing file id") }
			json(try submissions.uploadFile(id, device: device.deviceID, request: parseJSON(body)))
		case "images.abort", "files.abort":
			guard let id = route.requestID else { throw APIError(400, "bad_request", "missing upload id") }
			let kind: AgentSubmissions.UploadKind = route.name == "images.abort" ? .image : .file
			let answer = try submissions.abort(id, kind: kind, device: device.deviceID)
			daemon.log("upload.aborted", ["device": device.deviceID, "detail": "kind=\(kind.rawValue) deleted=\(answer["deleted"] as? Bool ?? false)"])
			json(answer)
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
		case "devices.push":
			let request = try parseJSON(body)
			guard let text = request["text"] as? String, let mode = PushTextMode(rawValue: text) else {
				throw APIError(400, "bad_request", "text must be named or generic")
			}
			let record = try daemon.devices.setPushText(device.deviceID, mode)
			daemon.log("device.push_text", ["device": device.deviceID, "detail": "text=\(mode.rawValue)"])
			json(["device": (record ?? device).publicJSON, "push_text": mode.rawValue])
		case "notifications.prefs.get":
			json(["prefs": daemon.notificationPrefs.prefs(device.deviceID).json])
		case "notifications.prefs.put":
			let prefs = try NotificationPrefs.parse(try parseJSON(body))
			try daemon.notificationPrefs.set(prefs, for: device.deviceID)
			daemon.log(
				"device.notification_prefs",
				["device": device.deviceID, "detail": "muted=\(prefs.mutedAgents.count) quiet=\(prefs.quietHours != nil)"])
			json(["prefs": prefs.json])
		case "agents.list":
			var listed = try daemon.agents.list()
			listed["agents"] = (listed["agents"] as? [[String: Any]])?.map(daemon.startup.annotate).map(daemon.waits.annotate)
			// A dialog that was up before the helper started has no event behind it: read this
			// Mac's blocked agents once. Other machines' arrive through their status polls.
			for agent in listed["agents"] as? [[String: Any]] ?? [] {
				guard agent["status"] as? String == "blocked", let id = agent["id"] as? String,
					PermissionTracker.isSupported(id), case .local = AgentRef(id), daemon.permissions.entry(id) == nil
				else { continue }
				_ = try? daemon.permissions.current(id)
			}
			// tmux has no blocked status: a pane's ask is only known by reading it (no keys).
			for agent in (listed["agents"] as? [[String: Any]] ?? []).prefix(Self.maxPeekedTmux) {
				guard let id = agent["id"] as? String, id.hasPrefix("tmux:") else { continue }
				daemon.asks.peek(id)
			}
			listed["agents"] = (listed["agents"] as? [[String: Any]])?.map(daemon.permissions.annotate).map(daemon.asks.annotate)
			daemon.transcripts.note {
				let herdr = (try? daemon.herdr.rawAgentList()) ?? []
				return herdr + (daemon.agents.hc?.transcriptInfos() ?? [])
			}
			listed["agents"] = (listed["agents"] as? [[String: Any]])?.map(daemon.transcripts.annotate)
			json(listed)
		case "agents.get":
			let id = try agentID(route)
			var answer = try daemon.agents.get(id)
			if var agent = (answer["agent"] as? [String: Any]).map(daemon.startup.annotate).map(daemon.waits.annotate) {
				if agent["status"] as? String == "blocked", daemon.permissions.entry(id) == nil {
					_ = try? daemon.permissions.current(id)
				}
				agent = daemon.transcripts.annotate(daemon.asks.annotate(daemon.permissions.annotate(agent)))
				answer["agent"] = agent
			}
			json(answer)
		case "agents.permission":
			json(try daemon.permissions.current(try agentID(route)))
		case "agents.permission.answer":
			let id = try agentID(route)
			let (choice, promptID) = try Self.parsePermissionAnswer(try parseJSON(body))
			daemon.log("agent.permission", ["device": device.deviceID, "detail": "choice=\(choice)"])
			json(try daemon.permissions.answer(id, choice: choice, promptID: promptID))
		case "agents.ask":
			json(try daemon.asks.current(try agentID(route)))
		case "agents.ask.answer":
			let id = try agentID(route)
			let (promptID, answers) = try Self.parseAskAnswer(try parseJSON(body))
			daemon.log("agent.ask", ["device": device.deviceID, "detail": "answers=\(answers.count)"])
			json(try daemon.asks.answer(id, promptID: promptID, answers: answers))
		case "agents.dialog":
			json(try daemon.asks.dialog(try agentID(route)))
		case "agents.dialog.answer":
			let id = try agentID(route)
			let (action, promptID) = try Self.parseDialogAnswer(try parseJSON(body))
			daemon.log("agent.dialog", ["device": device.deviceID, "detail": "action=\(action.name)"])
			json(try daemon.asks.answerDialog(id, action: action, promptID: promptID))
		case "agents.transcript":
			let id = try agentID(route)
			let query = try Self.parseQuery(exchange.query)
			guard query.keys.allSatisfy(["since", "before", "limit"].contains), query["since"] == nil || query["before"] == nil
			else { throw APIError(400, "bad_request", "use since or before, and limit") }
			json(try daemon.transcripts.transcript(id, query: query))
		case "agents.subagent.transcript":
			let id = try agentID(route)
			guard let subagent = route.requestID?.removingPercentEncoding else { throw APIError(400, "bad_request", "missing subagent id") }
			let query = try Self.parseQuery(exchange.query)
			guard query.keys.allSatisfy(["since", "before", "limit"].contains), query["since"] == nil || query["before"] == nil
			else { throw APIError(400, "bad_request", "use since or before, and limit") }
			json(try daemon.transcripts.subagentTranscript(id, subagent: subagent, query: query))
		case "asks.list":
			json(["asks": daemon.asks.all()])
		case "permissions.list":
			json(["permissions": daemon.permissions.permissions().map(daemon.permissions.json)])
        case "agents.files":
            let (cwd, reader) = try daemon.agents.codeReader(try agentID(route))
            json(try reader.files(cwd: cwd))
        case "agents.file":
            let query = try Self.parseQuery(exchange.query)
            guard let path = query["path"] else { throw APIError(400, "bad_path", "path is required") }
            let id = try agentID(route)
            let (cwd, reader) = try daemon.agents.codeReader(id)
            do {
                json(try reader.file(cwd: cwd, path: path))
            } catch let error as APIError where error.code == "file_denied" {
                daemon.log("agent.file_denied", ["device": device.deviceID, "detail": "reason=\(error.extra["reason"] ?? "-")"])
                throw error
            }
        case "agents.mac_file":
            let query = try Self.parseQuery(exchange.query)
            guard let path = query["path"] else { throw APIError(400, "bad_path", "path is required") }
            let files = try daemon.agents.macFiles(try agentID(route))
            do {
                let served = try files.read(path)
                daemon.log("agent.mac_file", ["device": device.deviceID, "detail": "kind=\(served.kind.rawValue) bytes=\(served.size)"])
                exchange.respond(200, contentType: served.contentType,
                    headers: [("X-WL-Request-Id", requestID)] + MacFiles.headers(served), body: served.data)
            } catch let error as APIError where error.code == "file_denied" {
                daemon.log("agent.mac_file_denied", ["device": device.deviceID, "detail": "reason=\(error.extra["reason"] ?? "-")"])
                throw error
            }
        case "agents.diff":
            let query = try Self.parseQuery(exchange.query)
            guard query["staged"] == nil || ["0", "1"].contains(query["staged"]!) else { throw APIError(400, "bad_request", "staged must be 0 or 1") }
            // `scope` (all, unstaged, staged) wins over the older `staged` flag.
            let scope: RepositoryDiff.Scope
            if let raw = query["scope"] {
                guard let parsed = RepositoryDiff.Scope(rawValue: raw) else { throw APIError(400, "bad_request", "scope must be all, unstaged or staged") }
                scope = parsed
            } else { scope = query["staged"] == "1" ? .staged : .all }
            // `path` asks for one file's patch; `refresh=1` skips the short answer cache.
            if let path = query["path"] {
                json(try daemon.agents.diffFile(try agentID(route), scope: scope, path: path))
            } else {
                json(try daemon.agents.diff(try agentID(route), scope: scope, refresh: query["refresh"] == "1"))
            }
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
			let format = query["format"] ?? "text"
			guard ["text", "ansi"].contains(format) else {
				throw APIError(400, "bad_request", "format must be text or ansi")
			}
			let output = try daemon.agents.read(id, source: source, lines: lines, ansi: format == "ansi")
			// The subagent lines Claude Code draws under its prompt, for agents whose log can't say.
			if format == "text", let text = output["text"] as? String {
				daemon.transcripts.noteScreen(id, text: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n"))
			}
			json(output)
		case "agents.prompt":
			let id = try agentID(route)
			let request = try parseJSON(body)
			guard let text = request["text"] as? String, (1...AgentSubmissions.maxText).contains(text.unicodeScalars.count) else {
				throw APIError(400, "bad_request", "text must be 1-\(AgentSubmissions.maxText) characters")
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
			// herdr lets a prompt through to a question form it calls idle (a narrow pane): the
			// text would go into the form's free-text row and Enter would answer with it.
			if let ask = daemon.asks.blockingAsk(id) {
				daemon.log("agent.prompt_refused", ["device": device.deviceID, "detail": "id=\(id) reason=ask"])
				throw AskTracker.askingError(ask, "The agent is asking you a question. Answer it on its card; your message was not sent.")
			}
			// A just-started agent takes prompts once herdr's launch is over: wait for it (bounded)
			// rather than fail the first message. Still launching after that → `agent_not_ready`.
			daemon.startup.waitUntilReady(id, timeout: Self.promptReadyWait)
			if let submissionID = request["submission_id"] as? String {
				guard request["images"] == nil || request["images"] is [String] else { throw APIError(400, "bad_request", "images must list upload ids") }
				guard request["files"] == nil || request["files"] is [String] else { throw APIError(400, "bad_request", "files must list upload ids") }
				json(try submissions.submit(submissionID, device: device.deviceID, agent: id, text: text,
					images: request["images"] as? [String] ?? [], files: request["files"] as? [String] ?? [],
					prepare: { try daemon.agents.imagePaths(id, paths: $0, device: device.deviceID) }) { delivered in
						try daemon.agents.prompt(id, text: delivered, wait: nil)
					})
			} else { json(try daemon.agents.prompt(id, text: text, wait: wait)) }
		case "recipes.list":
			json(try recipes.catalog())
		case "recipes.run":
			let request = try parseJSON(body)
			guard let text = request["text"] as? String, let id = route.requestID else { throw APIError(400, "bad_request", "Recipe id and text are required") }
			json(["text": try recipes.run(id, text: text)])
		case "text.translate":
			let request = try parseJSON(body)
			guard let text = request["text"] as? String, let target = request["target_language"] as? String else {
				throw APIError(400, "bad_request", "text and target_language are required")
			}
			daemon.log("text.translate", ["device": device.deviceID, "detail": "len=\(text.unicodeScalars.count) to=\(target)"])
			json(["text": try recipes.translate(text, to: target), "language": target])
		case "agents.keys":
			let id = try agentID(route)
			let request = try parseJSON(body)
			guard let keys = request["keys"] as? [String], (1...32).contains(keys.count),
				keys.allSatisfy(Self.isValidKey)
			else {
				throw APIError(400, "bad_request", "keys must list 1-32 key names such as esc, enter or ctrl+c")
			}
			daemon.log("agent.keys", ["device": device.deviceID, "detail": "count=\(keys.count)"])
			json(try daemon.agents.sendKeys(id, keys: keys))
		case "agents.interrupt":
			let id = try agentID(route)
			let request = body.isEmpty ? [:] : try parseJSON(body)
			let key = request["key"] as? String ?? "esc"
			guard Self.interruptKeys.contains(key) else {
				throw APIError(400, "bad_request", "key must be esc or ctrl+c")
			}
			// Esc on a question form cancels it: only when the phone says that is what it wants.
			if request["cancel_ask"] as? Bool != true, let ask = daemon.asks.blockingAsk(id) {
				daemon.log("agent.interrupt_refused", ["device": device.deviceID, "detail": "id=\(id) reason=ask"])
				throw AskTracker.askingError(ask, "The agent is asking you a question; Stop would cancel it. Nothing was sent.")
			}
			daemon.log("agent.interrupt", ["device": device.deviceID, "detail": "key=\(key)"])
			json(try daemon.agents.interrupt(id, key: key))
		case "agents.stop":
			let id = try agentID(route)
			daemon.log("agent.stop", ["device": device.deviceID, "detail": "id=\(id)"])
			defer { daemon.hub.publish("agents.changed", [:]) }
			json(try daemon.agents.stop(id))
		case "agents.remove":
			let id = try agentID(route)
			daemon.log("agent.remove", ["device": device.deviceID, "detail": "id=\(id)"])
			defer { daemon.hub.publish("agents.changed", [:]) }
			json(try daemon.agents.remove(id))
		case "agents.start":
			let start = try Self.parseStart(try parseJSON(body))
			daemon.log(
				"agent.start",
				[
					"device": device.deviceID,
					"detail":
						"kind=\(start.kind) machine=\(start.machine ?? "local") pane=\(start.paneID ?? "new-tab") args=\(start.args.count)",
				])
			json(try daemon.agents.start(start))
		case "events":
			try events(exchange, device: device, requestID: requestID)
		case "agents.terminal":
			try terminalSSE(exchange, agentID: try agentID(route), device: device, requestID: requestID)
		case "agents.terminal.ws":
			try terminalWebSocket(exchange, agentID: try agentID(route), device: device, requestID: requestID)
		case "agents.terminal.input":
			let request = try parseJSON(body)
			guard let encoded = request["data"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty,
				data.count <= TerminalBridge.maxInputBytes + 5
			else { throw APIError(400, "bad_request", "data must be a base64 terminal frame") }
			let id = try agentID(route)
			if let sessionID = request["session"] as? String {
				let session = try daemon.terminals.session(agentID: id, deviceID: device.deviceID, id: sessionID)
				let frame = try TerminalFrame.decodeClient(data)
				let ack = try session.handle(frame)
				var answer: [String: Any] = ["ok": true]
				if let ack { answer["ack"] = ack } else if case .input = frame { answer["dropped"] = true }
				json(answer)
			} else {
				// The spike's body: raw input bytes for the device's session on this agent.
				guard data.count <= TerminalBridge.maxInputBytes else {
					throw APIError(400, "bad_request", "data must be 1-16384 base64 bytes")
				}
				try daemon.terminals.session(agentID: id, deviceID: device.deviceID).handle(.input(seq: 0, data))
				json(["ok": true])
			}
		case "agents.terminal.resize":
			let request = try parseJSON(body)
			guard let cols = WireJSON.strictInt(request["cols"]), let rows = WireJSON.strictInt(request["rows"]),
				TerminalBridge.sizeRange.contains(cols), TerminalBridge.sizeRange.contains(rows)
			else { throw APIError(400, "bad_request", "cols and rows must be 2-500") }
			try daemon.terminals.session(agentID: try agentID(route), deviceID: device.deviceID)
				.handle(.resize(TerminalSize(cols: cols, rows: rows)))
			json(["ok": true, "cols": cols, "rows": rows])
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
		case "stt.translations":
			let reply = try daemon.speech.transcribe(
				body: body, contentType: exchange.header("Content-Type"), deviceID: device.deviceID, task: .translate)
			exchange.respond(
				reply.status, contentType: reply.contentType, headers: [("X-WL-Request-Id", requestID)],
				body: reply.body)
		case "stt.file.transcriptions", "stt.file.translations":
			let (fileID, fields) = try Self.parseSpeechByFile(try parseJSON(body))
			let task: SpeechTask = route.name == "stt.file.translations" ? .translate : .transcribe
			let upload = try submissions.finishedFile(fileID, device: device.deviceID)
			let reply = try { () throws -> SpeechService.Reply in
				// The upload is this one request's: gone before the answer leaves, and when the
				// transcription fails or is cancelled.
				defer {
					let deleted = (try? submissions.abort(fileID, kind: .file, device: device.deviceID))?["deleted"] as? Bool ?? false
					daemon.log("stt.file_done", ["device": device.deviceID, "detail": "bytes=\(upload.size) deleted=\(deleted)"])
				}
				guard upload.size <= daemon.config.sttMaxUploadBytes else {
					throw APIError(413, "payload_too_large", "audio exceeds \(daemon.config.sttMaxUploadBytes) bytes")
				}
				guard let audio = FileManager.default.contents(atPath: upload.url.path) else {
					throw APIError(404, "file_not_found", "No uploaded file with that id. Upload the audio again.")
				}
				return try daemon.speech.transcribe(
					audio: audio, filename: upload.name, fields: fields, deviceID: device.deviceID, task: task)
			}()
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

	private func events(_ exchange: LinkExchange, device: DeviceRecord, requestID: String) throws {
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
		// A relayed stream can end without a write failing (api_cancel, its lifetime), and any
		// stream must end once its device loses the right to it (revoked, unconfirmed again, or
		// its keys changed behind its id): look every second.
		let relayed = exchange.relaySender != nil
		let devices = daemon.devices
		let entitled = { Self.mayKeepStreaming(devices.get(device.deviceID), opened: device) }
		while true {
			let wait = max(0, nextPing.timeIntervalSinceNow)
			let next = stream.next(timeout: min(wait, 1))
			guard entitled() else {
				daemon.log("events.closed", ["device": device.deviceID, "detail": "device no longer confirmed"])
				return
			}
			switch next {
			case .closed: return
			case .timeout:
				if relayed && !exchange.isAlive { return }
				guard nextPing.timeIntervalSinceNow <= 0 else { continue }
				try exchange.write(Data(": ping\n\n".utf8))
				nextPing = Date().addingTimeInterval(interval)
			case .frame(let frame):
				try exchange.write(frame)
			}
		}
	}

	/// `cols`, `rows`, `mode`, `resume`, `after` from a terminal open's query.
	static func parseTerminalOpen(_ query: [String: String]) throws -> (
		size: TerminalSize, mode: TerminalMode, resume: String?, after: UInt64?
	) {
		let cols = Int(query["cols"] ?? "80") ?? 0
		let rows = Int(query["rows"] ?? "24") ?? 0
		guard TerminalBridge.sizeRange.contains(cols), TerminalBridge.sizeRange.contains(rows) else {
			throw APIError(400, "bad_request", "cols and rows must be 2-500")
		}
		guard let mode = TerminalMode(rawValue: query["mode"] ?? "mirror") else {
			throw APIError(400, "bad_request", "mode must be mirror or fit")
		}
		let resume = query["resume"].flatMap { $0.isEmpty ? nil : $0 }
		if let resume,
			!(resume.hasPrefix("term_") && resume.count == 17 && resume.dropFirst(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase }))
		{
			throw APIError(400, "bad_request", "bad resume session")
		}
		var after: UInt64?
		if let raw = query["after"] {
			guard let value = UInt64(raw) else { throw APIError(400, "bad_request", "after must be an output seq") }
			after = value
		}
		return (TerminalSize(cols: cols, rows: rows), mode, resume, after)
	}

	/// The agent's terminal as SSE: `event: frame` with `id: SEQ` and the base64 of the same
	/// binary frames the WebSocket sends; input arrives as signed POSTs.
	private func terminalSSE(_ exchange: LinkExchange, agentID: String, device: DeviceRecord, requestID: String) throws {
		let open = try Self.parseTerminalOpen(try Self.parseQuery(exchange.query))
		let (session, generation) = try daemon.terminals.open(
			agentID: agentID, device: device, size: open.size, mode: open.mode, resume: open.resume, after: open.after)
		defer {
			session.detach(generation)
			exchange.close()
		}
		try exchange.beginStream(
			200,
			headers: [
				("Content-Type", "text/event-stream"), ("Cache-Control", "no-store"),
				("X-WL-Request-Id", requestID), ("X-Accel-Buffering", "no"),
			])
		let relayed = exchange.relaySender != nil
		var nextPing = Date().addingTimeInterval(daemon.config.ssePingInterval)
		while true {
			switch session.next(generation, timeout: 1) {
			case .superseded, .ended: return
			case .timeout:
				if relayed && !exchange.isAlive { return }
				guard nextPing.timeIntervalSinceNow <= 0 else { continue }
				try exchange.write(Data(": ping\n\n".utf8))
				nextPing = Date().addingTimeInterval(daemon.config.ssePingInterval)
			case .frames(let frames):
				var out = ""
				for (position, frame) in frames {
					// `id:` on output frames only, so the ids a client sees only ever grow.
					let id = frame.first == TerminalFrame.output ? "id: \(position)\n" : ""
					out += "event: frame\n" + id + "data: " + frame.base64EncodedString() + "\n\n"
				}
				try exchange.write(Data(out.utf8))
			}
		}
	}

	/// The agent's terminal over a WebSocket (direct connections only): binary frames both ways,
	/// a ping every 15 s, closed after the `exit` frame.
	private func terminalWebSocket(_ exchange: LinkExchange, agentID: String, device: DeviceRecord, requestID: String)
		throws
	{
		guard exchange.relaySender == nil, let http = exchange as? HTTPExchange else {
			throw APIError(400, "websocket_unavailable", "WebSockets are not available over the relay; use the SSE stream")
		}
		// Only the upgrade is signed; every input frame after it is trusted. On a plain local
		// network that stream is cleartext anyone there can rewrite, so it is refused even with
		// plain-LAN access on: the phone falls back to SSE with each input a signed POST.
		switch daemon.directAccess.kind(peer: http.remoteHost, local: http.localHost, interface: http.localInterface) {
		case .loopback, .tailnet: break
		case .localNetwork, .other:
			throw APIError(
				400, "websocket_unavailable",
				"WebSockets are only available over Tailscale or on this Mac; use the SSE stream")
		}
		if let problem = WebSocket.handshakeProblem(http.header) { throw APIError(400, "bad_request", problem) }
		let open = try Self.parseTerminalOpen(try Self.parseQuery(exchange.query))
		let (session, generation) = try daemon.terminals.open(
			agentID: agentID, device: device, size: open.size, mode: open.mode, resume: open.resume, after: open.after)
		let leftover: Data
		do {
			leftover = try http.upgradeToWebSocket(
				key: http.header("Sec-WebSocket-Key") ?? "", headers: [("X-WL-Request-Id", requestID)])
		} catch {
			session.detach(generation)
			throw error
		}
		let socket = WebSocketConnection(exchange: http, leftover: leftover)
		defer {
			session.detach(generation)
			socket.close()
		}
		let reader = Thread { [daemon] in
			// However the reader ends (close frame, dropped TCP, bad frame), the stream ends with it.
			defer { socket.close() }
			while true {
				guard let message = try? socket.receive() else { return }
				switch message {
				case .binary(let data):
					do {
						try session.handle(try TerminalFrame.decodeClient(data))
					} catch let error as APIError where error.status == 400 {
						daemon.log("terminal.bad_frame", ["device": device.deviceID, "detail": error.code])
					} catch {
						return socket.close(1011, "terminal ended")
					}
				case .close: return
				case .text: return socket.close(1003, "binary frames only")
				case .ping, .pong: continue
				}
			}
		}
		reader.name = "link.terminal.ws-read"
		reader.start()
		let interval = daemon.config.ssePingInterval
		var nextPing = Date().addingTimeInterval(interval)
		while socket.isOpen {
			switch session.next(generation, timeout: 1) {
			case .superseded: return socket.close(1000, "superseded")
			case .ended: return socket.close(1000, "ended")
			case .timeout:
				if socket.silence > max(3 * interval, 45) { return socket.close(1001, "no answer to pings") }
				guard nextPing.timeIntervalSinceNow <= 0 else { continue }
				try socket.send(.ping, Data())
				nextPing = Date().addingTimeInterval(interval)
			case .frames(let frames):
				try socket.sendBinary(batch: frames.map(\.1))
			}
		}
	}

	/// Whether an open event stream may go on: the device is still active and confirmed, with the
	/// keys it had when the stream opened.
	static func mayKeepStreaming(_ current: DeviceRecord?, opened: DeviceRecord) -> Bool {
		guard let current, !current.isRevoked, current.approveConfirmed else { return false }
		return current.linkPubkey == opened.linkPubkey && current.approvePubkey == opened.approvePubkey
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

	static let maxPeekedTmux = 8

	/// `POST /v1/audio/transcriptions/file`: `{"file_id":"<uuid>","language"?,"prompt"?,
	/// "response_format"?,"temperature"?,"model"?}`, the multipart route's fields as JSON.
	static func parseSpeechByFile(_ request: [String: Any]) throws -> (fileID: String, fields: [String: String]) {
		let allowed: Set<String> = ["file_id", "language", "prompt", "response_format", "temperature", "model"]
		guard request.keys.allSatisfy(allowed.contains) else {
			throw APIError(400, "bad_request", "unknown field; send file_id, language, prompt, response_format, temperature")
		}
		guard let fileID = request["file_id"] as? String, UUID(uuidString: fileID) != nil else {
			throw APIError(400, "bad_request", "file_id must be the id of a finished POST /v1/files upload")
		}
		var fields: [String: String] = [:]
		func text(_ key: String, max: Int) throws -> String? {
			guard let raw = request[key], !(raw is NSNull) else { return nil }
			guard let value = raw as? String, value.unicodeScalars.count <= max, !value.contains("\0") else {
				throw APIError(400, "bad_request", "\(key) must be a string of at most \(max) characters")
			}
			return value.isEmpty ? nil : value
		}
		if let language = try text("language", max: 32) {
			guard language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "_") }) else {
				throw APIError(400, "bad_request", "language must be a language code such as en")
			}
			fields["language"] = language
		}
		fields["prompt"] = try text("prompt", max: 4000)
		if let format = try text("response_format", max: 32) {
			guard SpeechService.responseFormats.contains(format) else {
				throw APIError(400, "bad_request", "response_format must be json, text or verbose_json")
			}
			fields["response_format"] = format
		}
		// The Mac's engine answers whatever model is named; passed on like the form's field.
		fields["model"] = try text("model", max: 128)
		if let raw = request["temperature"], !(raw is NSNull) {
			guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), (0...1).contains(number.doubleValue)
			else { throw APIError(400, "bad_request", "temperature must be a number from 0 to 1") }
			fields["temperature"] = String(number.doubleValue)
		}
		return (fileID.lowercased(), fields)
	}

	/// `POST /v1/agents/{id}/ask`: `{"prompt_id":"<16 hex>","answers":[{"question":0,"option_ids":["2"],"other":"…"}]}`.
	static func parseAskAnswer(_ request: [String: Any]) throws -> (promptID: String, answers: [AgentAskAnswer]) {
		guard let promptID = request["prompt_id"] as? String, promptID.count == 16,
			promptID.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
		else { throw APIError(400, "bad_request", "prompt_id must be the ask's 16-hex id") }
		guard let answers = AgentAskAnswer.parse(request["answers"]),
			answers.allSatisfy({ $0.optionIDs.allSatisfy { (1...64).contains($0.count) && !$0.contains("\0") } })
		else {
			throw APIError(400, "bad_request", "answers must be 1-8 objects with question, option_ids and optional other")
		}
		return (promptID, answers)
	}

	/// `POST /v1/agents/{id}/dialog`: `{"action":"accept"|"decline"|"cancel","prompt_id":"<16 hex>",
	/// "values":[{"field":0,"value":true|"text"}]}`. Cancel may leave out `prompt_id` (any dialog).
	static func parseDialogAnswer(_ request: [String: Any]) throws -> (action: ElicitationAction, promptID: String?) {
		var promptID: String?
		if let raw = request["prompt_id"], !(raw is NSNull) {
			guard let id = raw as? String, id.count == 16, id.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
			else { throw APIError(400, "bad_request", "prompt_id must be the form's 16-hex id") }
			promptID = id
		}
		switch request["action"] as? String {
		case "cancel": return (.cancel, promptID)
		case "decline": return (.decline, promptID)
		case "accept":
			let raw = request["values"] ?? []
			guard let list = raw as? [[String: Any]], list.count <= 32 else {
				throw APIError(400, "bad_request", "values must list at most 32 {field, value} objects")
			}
			let values = try list.map { entry -> ElicitationFieldValue in
				guard let field = WireJSON.strictInt(entry["field"]), (0..<64).contains(field) else {
					throw APIError(400, "bad_request", "each value needs a field index")
				}
				// JSONSerialization reads true/false as NSNumber; only a real boolean is a checkbox value.
				if let number = entry["value"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
					return ElicitationFieldValue(field: field, value: .bool(number.boolValue))
				}
				guard let text = entry["value"] as? String, text.unicodeScalars.count <= 2000, !text.contains("\0"),
					!text.contains(where: \.isNewline)
				else { throw APIError(400, "bad_request", "a value is a boolean or one line of text (2000 characters at most)") }
				return ElicitationFieldValue(field: field, value: .text(text))
			}
			return (.accept(values), promptID)
		default:
			throw APIError(400, "bad_request", "action must be accept, decline or cancel")
		}
	}

	/// `POST /v1/agents/{id}/permission`: `{"choice":"<option id>","prompt_id":"<16 hex>"}`.
	static func parsePermissionAnswer(_ request: [String: Any]) throws -> (choice: String, promptID: String) {
		guard let choice = request["choice"] as? String, (1...2).contains(choice.count),
			choice.allSatisfy({ $0.isASCII && $0.isNumber })
		else { throw APIError(400, "bad_request", "choice must be an option id such as \"1\"") }
		guard let promptID = request["prompt_id"] as? String, promptID.count == 16,
			promptID.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
		else { throw APIError(400, "bad_request", "prompt_id must be the prompt's 16-hex id") }
		return (choice, promptID)
	}

	/// `POST /v1/agents`: `{"name","kind","machine"?,"pane_id"?,"workspace_id"?,"cwd"?,"args"?,"timeout_ms"?}`.
	static func parseStart(_ request: [String: Any]) throws -> AgentStart {
		guard let name = request["name"] as? String, isValidName(name), !name.hasPrefix("-") else {
			throw APIError(400, "bad_request", "name must be 1-64 letters, digits, '.', '_' or '-'")
		}
		guard let kind = request["kind"] as? String, (1...32).contains(kind.count),
			kind.unicodeScalars.allSatisfy({
				CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
					|| $0 == "-" || $0 == "_"
			}), !kind.hasPrefix("-")
		else { throw APIError(400, "bad_request", "kind must be a herdr agent kind such as codex or pi") }
		func optionalString(_ key: String) throws -> String? {
			guard let raw = request[key], !(raw is NSNull) else { return nil }
			guard let text = raw as? String else { throw APIError(400, "bad_request", "\(key) must be a string") }
			return text
		}
		let pane = try optionalString("pane_id")
		if let pane, !isValidAgentID(pane) || pane.hasPrefix("-") {
			throw APIError(400, "bad_request", "pane_id must be a herdr pane id")
		}
		let machine = try optionalString("machine")
		if let machine, machine != AgentMachine.localID, !HerdrCLI.isValidMachineID(machine) {
			throw APIError(400, "bad_request", "machine must be local or a herdr machine id")
		}
		let workspace = try optionalString("workspace_id")
		if let workspace, !isValidAgentID(workspace) || workspace.hasPrefix("-") {
			throw APIError(400, "bad_request", "workspace_id must be a herdr workspace id")
		}
		let cwd = try optionalString("cwd")
		if let cwd {
			guard (1...1024).contains(cwd.utf8.count), cwd.hasPrefix("/") || cwd.hasPrefix("~"),
				!cwd.contains("\u{0}"), !cwd.contains("\n")
			else { throw APIError(400, "bad_request", "cwd must be an absolute path") }
		}
		let args =
			request["args"] == nil || request["args"] is NSNull
			? [] : (request["args"] as? [String] ?? ["\u{0}"])
		guard args.count <= 32, args.allSatisfy({ $0.count <= 1000 && !$0.contains("\u{0}") }) else {
			throw APIError(400, "bad_request", "args must list at most 32 strings")
		}
		let timeout = request["timeout_ms"] == nil ? 30_000 : WireJSON.strictInt(request["timeout_ms"])
		guard let timeout else { throw APIError(400, "bad_request", "timeout_ms must be an integer") }
		let provider = try optionalString("provider")
		if let provider, !["herdr", "hc"].contains(provider) {
			throw APIError(400, "bad_request", "provider must be herdr or hc")
		}
		if let machine, provider == "hc", machine != AgentMachine.localID, !HerdrCoreID.isValidMachine(machine) {
			throw APIError(400, "bad_request", "machine must be local or a herdr-core machine name")
		}
		return AgentStart(
			name: name, kind: kind, machine: machine, paneID: pane, workspaceID: workspace, cwd: cwd, args: args,
			timeoutMS: min(max(timeout, 3001), 60_000), provider: provider)
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
