import Foundation

/// The local admin socket the `whispera-link` CLI talks to (PROTOCOL §3.1): one JSON line per
/// request, one per response, connection closed after. Wire-compatible with the Python daemon,
/// so `whispera-link pair`, `devices`, `revoke` and `status` drive the helper unchanged.
final class AdminServer: @unchecked Sendable {
	typealias Handler = ([String: Any]) throws -> [String: Any]

	private let listener: UnixListener
	private let handlers: [String: Handler]
	private let log: OpsLog

	init(socketPath: String, handlers: [String: Handler], log: OpsLog) {
		listener = UnixListener(path: socketPath)
		self.handlers = handlers
		self.log = log
	}

	func start() throws {
		try listener.start(
			name: "admin-accept",
			onForeignPeer: { connection in
				try? connection.sendLine([
					"ok": false, "error": ["code": "forbidden", "message": "peer uid mismatch"],
				])
				connection.close()
			},
			handle: { [weak self] connection in self?.handle(connection) })
	}

	func stop() { listener.stop() }

	private func handle(_ connection: UnixConnection) {
		defer { connection.close() }
		var request: [String: Any]?
		if case .line(let line)? = try? connection.readLine(timeout: 10) { request = WireJSON.decodeObject(line) }
		let response: [String: Any]
		if let request, let op = request["op"] as? String {
			if let handler = handlers[op] {
				do {
					response = try handler(request)
				} catch let error as APIError {
					response = error.adminObject
				} catch {
					log("admin.error", ["detail": "\(type(of: error))"])
					response = ["ok": false, "error": ["code": "internal", "message": "internal error"]]
				}
			} else {
				response = [
					"ok": false, "error": ["code": "bad_request", "message": "unknown op \(op.prefix(40))"],
				]
			}
		} else {
			response = [
				"ok": false,
				"error": ["code": "bad_request", "message": "one JSON object with an op per line"],
			]
		}
		try? connection.sendLine(response, timeout: 10)
	}
}
