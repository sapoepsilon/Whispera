import Foundation

/// Race-free URLProtocol mock. Each `make` call returns a session bound to a
/// unique base URL (host = a UUID), and the handler is keyed by that host, so
/// tests running in parallel never clobber each other's responses.
final class MockURLProtocol: URLProtocol {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> (HTTPURLResponse, Data)] = [:]
	nonisolated(unsafe) private static var lastRequests: [String: URLRequest] = [:]

	struct Mock {
		let session: URLSession
		let baseURL: URL
		let host: String
	}

	static func make(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> Mock {
		let host = "m\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).test"
		lock.lock()
		handlers[host] = handler
		lock.unlock()

		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: config)
		return Mock(session: session, baseURL: URL(string: "http://\(host)")!, host: host)
	}

	/// Convenience for a single status + JSON body response.
	static func make(status: Int, json: String) -> Mock {
		make { request in
			let response = HTTPURLResponse(
				url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
			return (response, Data(json.utf8))
		}
	}

	static func lastRequest(host: String) -> URLRequest? {
		lock.lock()
		defer { lock.unlock() }
		return lastRequests[host]
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let host = request.url?.host ?? ""
		Self.lock.lock()
		let handler = Self.handlers[host]
		Self.lastRequests[host] = request
		Self.lock.unlock()

		guard let handler else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		let (response, data) = handler(request)
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
