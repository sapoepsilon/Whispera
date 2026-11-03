import CryptoKit
import Foundation
import WhisperaLink

// A software-key phone for the e2e scripts (never the app's or the iPhone's keys):
//
//   link-soft-phone pair --state DIR (--qr PAYLOAD | --url URL --code CODE [--fp HEX] [--yes])
//       pairing v2: POST /v1/pair/commit with a commitment, check the daemon-signed ack, then
//       reveal the code in POST /v1/pair. Without --fp the daemon fingerprint comes from
//       /v1/health and is printed for the owner to compare with the Mac (confirm on stdin, or
//       --yes). Prints the pair response JSON; keys and the response go to DIR.
//   link-soft-phone call --state DIR METHOD TARGET [JSON]
//       one WL1-signed request; prints {"status":…,"json":…}.
//   link-soft-phone terminal-ws --state DIR AGENT [--keys N] [--cols C --rows R] [--mode mirror|fit]
//   link-soft-phone terminal-sse --state DIR AGENT [--keys N] [--cols C --rows R] [--mode mirror|fit]
//       opens the agent's terminal (Terminal beta) over a WebSocket, or over SSE with POSTed
//       input, prints the hello and the first frames, then types N `x` and N backspaces one at a
//       time and prints the echo (input → first output after it) and ack latencies.
//       `--stream CMD [--seconds S]` (WebSocket) then types CMD + Enter and, for S seconds
//       (default 5), prints how many output frames and bytes arrived and the gaps between them.
//   account-register / account-safety / relay / relay-upload / relay-dictate / relay-events:
//       an account phone over the E2E relay (Relay.swift).

struct Failure: Error, CustomStringConvertible {
	let description: String
}

func argument(_ name: String, _ args: [String]) -> String? {
	guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
	return args[index + 1]
}

func post(_ url: URL, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
	var request = URLRequest(url: url)
	request.httpMethod = "POST"
	request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
	let (data, response) = try await URLSession.shared.data(for: request)
	return (data, response as! HTTPURLResponse)
}

func object(_ data: Data) -> [String: Any] {
	(try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func pair(_ args: [String], state: URL) async throws {
	var base: URL
	var code: String
	var fingerprint: String?
	if let qr = argument("--qr", args) {
		guard let payload = PairingPayload.parse(qr: qr) else { throw Failure(description: "bad QR payload") }
		(base, code, fingerprint) = (payload.baseURL, payload.code, payload.fingerprint)
	} else {
		guard let url = argument("--url", args), let raw = argument("--code", args),
			let payload = PairingPayload.manual(url: url, code: raw)
		else { throw Failure(description: "pair needs --qr, or --url and --code") }
		(base, code, fingerprint) = (payload.baseURL, payload.code, argument("--fp", args)?.lowercased())
	}
	var text = base.absoluteString
	while text.hasSuffix("/") { text.removeLast() }
	base = URL(string: text)!
	let daemonFP: String
	if let fingerprint {
		daemonFP = fingerprint
	} else {
		daemonFP = try await LinkClient.health(baseURL: base).daemon_fp.lowercased()
	}

	let link = SoftwareSigningKey()
	let approve = SoftwareSigningKey()
	let nonce = LinkCrypto.randomBytes(32)
	let commitment = LinkCrypto.pairCommitment(
		code: code, daemonFP: daemonFP, linkX963: link.publicKey.x963, approveX963: approve.publicKey.x963,
		nonce: nonce)
	let (ackData, ackResponse) = try await post(
		base.appendingPathComponent("v1/pair/commit"), ["v": 2, "commitment": commitment])
	guard ackResponse.statusCode == 201 else {
		throw Failure(description: "commit refused: \(ackResponse.statusCode) \(String(decoding: ackData, as: UTF8.self))")
	}
	let ack = try JSONDecoder().decode(PairCommitAck.self, from: ackData)
	guard let daemonKey = Data(base64Encoded: ack.daemon_pubkey), LinkCrypto.fingerprint(x963: daemonKey) == daemonFP,
		let signature = Data(
			base64Encoded: ackResponse.value(forHTTPHeaderField: SignedHeaders.serverSignatureHeader) ?? ""),
		LinkCrypto.verify(x963: daemonKey, message: LinkCrypto.pairCommitAckMessage(body: ackData), derSignature: signature),
		ack.commitment == commitment
	else { throw Failure(description: "commit acknowledgement is not from the expected daemon key") }
	if fingerprint == nil {
		FileHandle.standardError.write(
			Data("Mac fingerprint: \(LinkCrypto.displayFingerprint(daemonFP)) (compare with the Mac)\n".utf8))
		if !args.contains("--yes") {
			FileHandle.standardError.write(Data("Does it match? [y/N] ".utf8))
			guard readLine()?.lowercased().hasPrefix("y") == true else {
				throw Failure(description: "fingerprint not confirmed; nothing revealed")
			}
		}
	}

	let proof = try link.sign(
		LinkCrypto.pairProofMessage(code: code, daemonFP: daemonFP, approveX963: approve.publicKey.x963))
	let approveProof = try approve.sign(LinkCrypto.pairApproveMessage(code: code, daemonFP: daemonFP))
	let (data, response) = try await post(
		base.appendingPathComponent("v1/pair"),
		[
			"v": 2, "pair_id": ack.pair_id, "nonce": nonce.base64EncodedString(), "code": code,
			"name": argument("--name", args) ?? "Soft Phone", "link_pubkey": link.publicKey.x963Base64,
			"approve_pubkey": approve.publicKey.x963Base64, "proof": proof.base64EncodedString(),
			"approve_proof": approveProof.base64EncodedString(), "apns": NSNull(),
		])
	guard response.statusCode == 201 else {
		throw Failure(description: "pair refused: \(response.statusCode) \(String(decoding: data, as: UTF8.self))")
	}
	guard let pairSignature = Data(
		base64Encoded: response.value(forHTTPHeaderField: SignedHeaders.serverSignatureHeader) ?? ""),
		LinkCrypto.verify(x963: daemonKey, message: LinkCrypto.pairResponseMessage(body: data), derSignature: pairSignature)
	else { throw Failure(description: "pair response is not signed by the daemon key") }
	try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
	var saved = object(data)
	saved["base_url"] = base.absoluteString
	saved["link_key_pem"] = link.privateKey.pemRepresentation
	saved["approve_key_pem"] = approve.privateKey.pemRepresentation
	let file = state.appendingPathComponent("phone.json")
	try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: file)
	chmod(file.path, 0o600)
	print(String(decoding: data, as: UTF8.self))
}

func call(_ args: [String], state: URL) async throws {
	let positional = args.filter { !$0.hasPrefix("--") && $0 != argument("--state", args) }
	guard positional.count >= 2 else { throw Failure(description: "call needs METHOD TARGET [JSON]") }
	let saved = object(try Data(contentsOf: state.appendingPathComponent("phone.json")))
	guard let base = saved["base_url"] as? String, let id = saved["device_id"] as? String,
		let pem = saved["link_key_pem"] as? String
	else { throw Failure(description: "no paired phone in \(state.path)") }
	let key = try SoftwareSigningKey(pkcs8PEM: pem)
	let (method, target) = (positional[0], positional[1])
	let body = positional.count > 2 ? Data(positional[2].utf8) : Data()
	var request = URLRequest(url: URL(string: base + target)!)
	request.httpMethod = method
	if !body.isEmpty || method == "POST" || method == "PUT" {
		request.httpBody = body
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	}
	try SignedHeaders.sign(
		key: key, deviceID: id, method: method, target: target, body: body,
		timestamp: Int64(Date().timeIntervalSince1970)
	).apply(to: &request)
	let (data, response) = try await URLSession.shared.data(for: request)
	let status = (response as! HTTPURLResponse).statusCode
	let json = (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
	print(String(decoding: try JSONSerialization.data(withJSONObject: ["status": status, "json": json]), as: UTF8.self))
}

// MARK: Terminal beta

struct Phone {
	let base: String
	let id: String
	let key: SoftwareSigningKey

	init(state: URL) throws {
		let saved = object(try Data(contentsOf: state.appendingPathComponent("phone.json")))
		guard let base = saved["base_url"] as? String, let id = saved["device_id"] as? String,
			let pem = saved["link_key_pem"] as? String
		else { throw Failure(description: "no paired phone in \(state.path)") }
		self.base = base
		self.id = id
		key = try SoftwareSigningKey(pkcs8PEM: pem)
	}

	func signed(_ method: String, _ target: String, body: Data = Data(), scheme: String? = nil) throws -> URLRequest {
		var url = base + target
		if let scheme, let colon = url.firstIndex(of: ":") { url = scheme + url[colon...] }
		var request = URLRequest(url: URL(string: url)!)
		request.httpMethod = method
		if !body.isEmpty || method == "POST" {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		try SignedHeaders.sign(
			key: key, deviceID: id, method: method, target: target, body: body,
			timestamp: Int64(Date().timeIntervalSince1970)
		).apply(to: &request)
		return request
	}
}

func inputFrame(_ seq: UInt32, _ bytes: Data) -> Data {
	var out = Data([0x10, UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)])
	out.append(bytes)
	return out
}

func describe(_ frame: Data) -> String {
	let bytes = [UInt8](frame)
	guard let type = bytes.first else { return "empty" }
	let rest = Data(bytes.dropFirst())
	switch type {
	case 0x01: return "hello " + String(decoding: rest, as: UTF8.self)
	case 0x02:
		let seq = bytes[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
		return "output seq=\(seq) bytes=\(bytes.count - 9)"
	case 0x03: return "reset " + String(decoding: rest, as: UTF8.self)
	case 0x04: return "size " + String(decoding: rest, as: UTF8.self)
	case 0x05: return "ack \(bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })"
	case 0x06: return "exit " + String(decoding: rest, as: UTF8.self)
	default: return "type \(type)"
	}
}

func percentile(_ values: [Double], _ p: Double) -> Double {
	guard !values.isEmpty else { return .nan }
	let sorted = values.sorted()
	return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

/// Received frames with their arrival time, for the latency loop.
final class FrameInbox: @unchecked Sendable {
	private let condition = NSCondition()
	private var frames: [(Date, Data)] = []
	private var closed = false

	func put(_ frame: Data) {
		condition.lock()
		frames.append((Date(), frame))
		condition.broadcast()
		condition.unlock()
	}

	func close() {
		condition.lock()
		closed = true
		condition.broadcast()
		condition.unlock()
	}

	func take(timeout: TimeInterval) -> (Date, Data)? {
		condition.lock()
		defer { condition.unlock() }
		let deadline = Date().addingTimeInterval(timeout)
		while frames.isEmpty, !closed {
			if !condition.wait(until: deadline) { break }
		}
		return frames.isEmpty ? nil : frames.removeFirst()
	}
}

/// Types `keys` x's then as many backspaces, one at a time: echo = send → first output after
/// it; ack = send → its ack (the WS ack frame, or the POST response).
func measure(_ inbox: FrameInbox, keys: Int, label: String, send: (UInt32, Data) async throws -> Date?) async throws {
	var echoes: [Double] = []
	var acks: [Double] = []
	let strokes = Array(repeating: Data("x".utf8), count: keys) + Array(repeating: Data([0x7F]), count: keys)
	for (index, stroke) in strokes.enumerated() {
		while inbox.take(timeout: 0) != nil {}
		let seq = UInt32(index + 1)
		let sent = Date()
		let acked = try await send(seq, inputFrame(seq, stroke))
		if let acked { acks.append(acked.timeIntervalSince(sent) * 1000) }
		var echoed: Date?
		var gotAck = false
		let deadline = Date().addingTimeInterval(3)
		while echoed == nil || !gotAck, Date() < deadline {
			guard let (at, frame) = inbox.take(timeout: deadline.timeIntervalSinceNow) else { break }
			if frame.first == 0x02, echoed == nil { echoed = at }
			if frame.first == 0x05, frame.count == 5,
				frame[frame.startIndex + 1..<frame.startIndex + 5].reduce(UInt32(0), { $0 << 8 | UInt32($1) }) == seq
			{
				// Over SSE the POST response already timed the ack.
				if acked == nil { acks.append(at.timeIntervalSince(sent) * 1000) }
				gotAck = true
			}
			if frame.first == 0x06 { throw Failure(description: describe(frame)) }
		}
		if let echoed { echoes.append(echoed.timeIntervalSince(sent) * 1000) }
		try await Task.sleep(nanoseconds: 30_000_000)
	}
	func line(_ name: String, _ values: [Double]) -> String {
		String(
			format: "%@ %@ n=%d median=%.1fms p95=%.1fms min=%.1fms max=%.1fms", label, name, values.count,
			percentile(values, 0.5), percentile(values, 0.95), values.min() ?? .nan, values.max() ?? .nan)
	}
	print(line("echo", echoes))
	print(line("ack", acks))
}

func terminalQuery(_ args: [String]) -> String {
	"cols=\(argument("--cols", args) ?? "120")&rows=\(argument("--rows", args) ?? "40")&mode=\(argument("--mode", args) ?? "mirror")"
}

func printOpening(_ inbox: FrameInbox) throws -> String? {
	var session: String?
	let deadline = Date().addingTimeInterval(5)
	var outputs = 0
	while Date() < deadline, outputs == 0 || session == nil {
		guard let (_, frame) = inbox.take(timeout: deadline.timeIntervalSinceNow) else { break }
		print(describe(frame))
		if frame.first == 0x01 {
			session = (try? JSONSerialization.jsonObject(with: frame.dropFirst()) as? [String: Any])?["session"] as? String
		}
		if frame.first == 0x02 { outputs += 1 }
		if frame.first == 0x06 { throw Failure(description: describe(frame)) }
	}
	while let (_, frame) = inbox.take(timeout: 0.5) { print(describe(frame)) }
	return session
}

/// The first argument after the subcommand that is neither a flag nor a flag's value.
func agentArgument(_ args: [String]) throws -> String {
	let valued: Set<String> = ["--state", "--keys", "--cols", "--rows", "--mode", "--stream", "--seconds"]
	var index = 1
	while index < args.count {
		if valued.contains(args[index]) {
			index += 2
		} else if args[index].hasPrefix("--") {
			index += 1
		} else {
			return args[index]
		}
	}
	throw Failure(description: "needs AGENT")
}

func terminalWS(_ args: [String], state: URL) async throws {
	let agent = try agentArgument(args)
	let phone = try Phone(state: state)
	let keys = Int(argument("--keys", args) ?? "50") ?? 50
	let target = "/v1/agents/\(agent)/terminal/ws?" + terminalQuery(args)
	let opened = Date()
	let task = URLSession.shared.webSocketTask(with: try phone.signed("GET", target, scheme: "ws"))
	let inbox = FrameInbox()
	task.resume()
	Task {
		while true {
			guard let message = try? await task.receive() else { return inbox.close() }
			if case .data(let data) = message { inbox.put(data) }
		}
	}
	guard try printOpening(inbox) != nil else { throw Failure(description: "no hello (\(String(describing: task.response)))") }
	print(String(format: "ws open→first frames %.0fms", Date().timeIntervalSince(opened) * 1000))
	try await measure(inbox, keys: keys, label: "ws") { _, frame in
		try await task.send(.data(frame))
		return nil
	}
	if let command = argument("--stream", args) {
		let seconds = Double(argument("--seconds", args) ?? "5") ?? 5
		while inbox.take(timeout: 0.3) != nil {}
		try await task.send(.data(inputFrame(UInt32(keys * 2 + 1), Data((command + "\r").utf8))))
		watch(inbox, seconds: seconds)
	}
	task.cancel(with: .normalClosure, reason: nil)
}

func terminalSSE(_ args: [String], state: URL) async throws {
	let agent = try agentArgument(args)
	let phone = try Phone(state: state)
	let keys = Int(argument("--keys", args) ?? "50") ?? 50
	let target = "/v1/agents/\(agent)/terminal?" + terminalQuery(args)
	let opened = Date()
	let (bytes, response) = try await URLSession.shared.bytes(for: try phone.signed("GET", target))
	guard (response as? HTTPURLResponse)?.statusCode == 200 else {
		throw Failure(description: "stream refused: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
	}
	let inbox = FrameInbox()
	let reader = Task {
		do {
			for try await line in bytes.lines where line.hasPrefix("data: ") {
				if let data = Data(base64Encoded: String(line.dropFirst(6))) { inbox.put(data) }
			}
		} catch {}
		inbox.close()
	}
	guard let session = try printOpening(inbox) else { throw Failure(description: "no hello") }
	print(String(format: "sse open→first frames %.0fms", Date().timeIntervalSince(opened) * 1000))
	let inputTarget = "/v1/agents/\(agent)/terminal/input"
	try await measure(inbox, keys: keys, label: "sse+post") { _, frame in
		let body = try JSONSerialization.data(withJSONObject: ["session": session, "data": frame.base64EncodedString()])
		let (data, response) = try await URLSession.shared.data(for: try phone.signed("POST", inputTarget, body: body))
		guard (response as? HTTPURLResponse)?.statusCode == 200 else {
			throw Failure(description: "input refused: \(String(decoding: data, as: UTF8.self))")
		}
		return Date()
	}
	reader.cancel()
}

/// Output frames for `seconds`: count, bytes, frames per second and the gaps between them.
func watch(_ inbox: FrameInbox, seconds: Double) {
	let start = Date()
	var frames = 0
	var bytes = 0
	var last: Date?
	var gaps: [Double] = []
	while Date().timeIntervalSince(start) < seconds {
		guard let (at, frame) = inbox.take(timeout: seconds - Date().timeIntervalSince(start)) else { break }
		guard frame.first == 0x02 else { continue }
		frames += 1
		bytes += frame.count - 9
		if let last { gaps.append(at.timeIntervalSince(last) * 1000) }
		last = at
	}
	print(
		String(
			format: "stream %.1fs frames=%d (%.1f/s) bytes=%d (%.0f KiB/s) gap median=%.1fms p95=%.1fms min=%.1fms",
			seconds, frames, Double(frames) / seconds, bytes, Double(bytes) / 1024 / seconds, percentile(gaps, 0.5),
			percentile(gaps, 0.95), gaps.min() ?? .nan))
}

let args = Array(CommandLine.arguments.dropFirst())
let state = URL(fileURLWithPath: argument("--state", args) ?? "./soft-phone")
do {
	switch args.first {
	case "pair": try await pair(args, state: state)
	case "call": try await call(Array(args.dropFirst()), state: state)
	case "terminal-ws": try await terminalWS(args, state: state)
	case "terminal-sse": try await terminalSSE(args, state: state)
	case "account-register": try await accountRegister(args, state: state)
	case "account-safety": try await accountSafety(state: state)
	case "relay": try await relayCall(Array(args.dropFirst()), state: state)
	case "relay-upload": try await relayUpload(args, state: state)
	case "relay-dictate": try await relayDictate(args, state: state)
	case "relay-events": try await relayEvents(args, state: state)
	default:
		FileHandle.standardError.write(Data("usage: link-soft-phone pair|call … (see the source header)\n".utf8))
		exit(2)
	}
} catch {
	FileHandle.standardError.write(Data("link-soft-phone: \(error)\n".utf8))
	exit(1)
}
