import Foundation
import Network

/// A real loopback HTTP/1.1 server for exercising network clients end to end without reaching
/// the internet. Each request gets one response, then the connection closes.
final class MockHTTPServer: @unchecked Sendable {
	struct Request: Sendable {
		let method: String
		let path: String
		let headers: [String: String]
		let body: Data

		func header(_ name: String) -> String? {
			headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
		}

		var jsonBody: [String: Any]? {
			(try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
		}
	}

	struct Response: Sendable {
		var status: Int = 200
		var body: Data
		var contentType = "application/json"

		static func json(_ object: Any, status: Int = 200) -> Response {
			Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
		}
	}

	private let listener: NWListener
	private let queue = DispatchQueue(label: "MockHTTPServer")
	private let lock = NSLock()
	private let handler: @Sendable (Request) -> Response
	private var recorded: [Request] = []

	var requests: [Request] {
		lock.withLock { recorded }
	}

	private(set) var port: UInt16 = 0

	var baseURL: String { "http://127.0.0.1:\(port)/v1" }

	init(handler: @escaping @Sendable (Request) -> Response) throws {
		self.handler = handler
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: parameters)
	}

	func start() async throws {
		let ready = AsyncThrowingStream<UInt16, Error> { continuation in
			listener.stateUpdateHandler = { [weak self] state in
				switch state {
				case .ready:
					continuation.yield(self?.listener.port?.rawValue ?? 0)
					continuation.finish()
				case .failed(let error):
					continuation.finish(throwing: error)
				default:
					break
				}
			}
		}
		listener.newConnectionHandler = { [weak self] connection in
			self?.accept(connection)
		}
		listener.start(queue: queue)
		for try await port in ready {
			self.port = port
		}
	}

	func stop() {
		listener.cancel()
	}

	private func accept(_ connection: NWConnection) {
		connection.start(queue: queue)
		receive(on: connection, buffer: Data())
	}

	private func receive(on connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
			[weak self] data, _, isComplete, error in
			guard let self else { return }
			var buffer = buffer
			if let data { buffer.append(data) }
			if let request = Self.parse(buffer) {
				self.respond(to: request, on: connection)
			} else if isComplete || error != nil {
				connection.cancel()
			} else {
				self.receive(on: connection, buffer: buffer)
			}
		}
	}

	private func respond(to request: Request, on connection: NWConnection) {
		let response: Response = lock.withLock {
			recorded.append(request)
			return handler(request)
		}
		var head = "HTTP/1.1 \(response.status) Mock\r\n"
		head += "Content-Type: \(response.contentType)\r\n"
		head += "Content-Length: \(response.body.count)\r\n"
		head += "Connection: close\r\n\r\n"
		var payload = Data(head.utf8)
		payload.append(response.body)
		connection.send(
			content: payload,
			completion: .contentProcessed { _ in
				connection.cancel()
			})
	}

	private static func parse(_ buffer: Data) -> Request? {
		guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let headText = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
		var lines = headText.components(separatedBy: "\r\n")
		guard !lines.isEmpty else { return nil }
		let requestLine = lines.removeFirst().split(separator: " ")
		guard requestLine.count >= 2 else { return nil }

		var headers: [String: String] = [:]
		for line in lines {
			guard let colon = line.firstIndex(of: ":") else { continue }
			let name = String(line[..<colon])
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			headers[name] = value
		}
		let lengthHeader = headers.first { $0.key.lowercased() == "content-length" }?.value
		let length = Int(lengthHeader ?? "0") ?? 0
		let body = buffer[separator.upperBound...]
		guard body.count >= length else { return nil }
		return Request(
			method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
			body: Data(body.prefix(length)))
	}
}
