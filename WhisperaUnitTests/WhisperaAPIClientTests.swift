import Foundation
import Testing

@testable import Whispera

/// Intercepts URLSession traffic so client tests never hit the network.
final class MockURLProtocol: URLProtocol {
	nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
	nonisolated(unsafe) static var lastRequest: URLRequest?

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		MockURLProtocol.lastRequest = request
		guard let handler = MockURLProtocol.handler else {
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

@Suite(.serialized)
struct WhisperaAPIClientTests {

	private func makeClient(service: String) -> (WhisperaAPIClient, AuthTokenStore) {
		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: config)
		let store = AuthTokenStore(service: service)
		let client = WhisperaAPIClient(
			session: session,
			tokenStore: store,
			serverURLProvider: { URL(string: "http://localhost:3000") })
		return (client, store)
	}

	private func respond(_ status: Int, _ json: String) {
		MockURLProtocol.handler = { request in
			let response = HTTPURLResponse(
				url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
			return (response, Data(json.utf8))
		}
	}

	@Test func getMeSendsBearerAndDecodes() async throws {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (client, store) = makeClient(service: service)
		defer { try? store.delete() }
		try store.save("devtoken123")
		respond(200, #"{"id":"u1","clerkId":"devtoken123","email":"a@b.co","name":null}"#)

		let user = try await client.getMe()
		#expect(user.id == "u1")
		#expect(user.email == "a@b.co")
		#expect(MockURLProtocol.lastRequest?.url?.path == "/auth/me")
		#expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer devtoken123")
	}

	@Test func providerKeyHeaderIsSetWhenProvided() async throws {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (client, store) = makeClient(service: service)
		defer { try? store.delete() }
		try store.save("t")
		respond(200, #"{"ok":true}"#)

		let _: EmptyResponseProbe = try await client.get("/x", providerKey: "sk-byok-123")
		#expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Provider-Key") == "sk-byok-123")
	}

	@Test func missingTokenThrowsNotAuthenticated() async {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (client, store) = makeClient(service: service)
		try? store.delete()
		await #expect(throws: WhisperaAPIError.self) { _ = try await client.getMe() }
	}

	@Test func httpErrorIsMapped() async throws {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (client, store) = makeClient(service: service)
		defer { try? store.delete() }
		try store.save("t")
		respond(401, #"{"error":"Unauthorized"}"#)

		await #expect(throws: WhisperaAPIError.self) { _ = try await client.getMe() }
	}
}

private struct EmptyResponseProbe: Decodable {
	let ok: Bool
}

@MainActor
@Suite(.serialized)
struct AuthManagerTests {

	private func makeAuth(service: String) -> (AuthManager, AuthTokenStore) {
		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: config)
		let store = AuthTokenStore(service: service)
		let client = WhisperaAPIClient(
			session: session,
			tokenStore: store,
			serverURLProvider: { URL(string: "http://localhost:3000") })
		return (AuthManager(api: client, tokenStore: store), store)
	}

	@Test func signInSuccessStoresUser() async {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (auth, store) = makeAuth(service: service)
		defer { try? store.delete() }
		MockURLProtocol.handler = { request in
			let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (r, Data(#"{"id":"u1","clerkId":"tok","email":"x@y.z","name":null}"#.utf8))
		}

		await auth.signIn(token: "tok")
		#expect(auth.isSignedIn)
		#expect(auth.user?.email == "x@y.z")
		#expect((try? store.load()) == "tok")
	}

	@Test func signInFailureRevertsToken() async {
		let service = "com.whispera.clerk.test.\(UUID().uuidString)"
		let (auth, store) = makeAuth(service: service)
		defer { try? store.delete() }
		MockURLProtocol.handler = { request in
			let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
			return (r, Data(#"{"error":"Unauthorized"}"#.utf8))
		}

		await auth.signIn(token: "bad")
		#expect(!auth.isSignedIn)
		#expect((try? store.load()) == nil)
		#expect(auth.lastError != nil)
	}
}
