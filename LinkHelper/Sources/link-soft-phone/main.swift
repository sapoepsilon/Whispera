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

let args = Array(CommandLine.arguments.dropFirst())
let state = URL(fileURLWithPath: argument("--state", args) ?? "./soft-phone")
do {
	switch args.first {
	case "pair": try await pair(args, state: state)
	case "call": try await call(Array(args.dropFirst()), state: state)
	default:
		FileHandle.standardError.write(Data("usage: link-soft-phone pair|call … (see the source header)\n".utf8))
		exit(2)
	}
} catch {
	FileHandle.standardError.write(Data("link-soft-phone: \(error)\n".utf8))
	exit(1)
}
