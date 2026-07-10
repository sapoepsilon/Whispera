import Foundation
import Testing

@testable import Whispera

struct WhisperaAPIClientTests {

	private func makeClient(mock: MockURLProtocol.Mock) -> (WhisperaAPIClient, AuthTokenStore) {
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		let client = WhisperaAPIClient(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })
		return (client, store)
	}

	@Test func getMeSendsBearerAndDecodes() async throws {
		let mock = MockURLProtocol.make(
			status: 200, json: #"{"id":"u1","clerkId":"devtoken123","email":"a@b.co","name":null}"#)
		let (client, store) = makeClient(mock: mock)
		defer { try? store.delete() }
		try store.save("devtoken123")

		let user = try await client.getMe()
		#expect(user.id == "u1")
		#expect(user.email == "a@b.co")
		#expect(MockURLProtocol.lastRequest(host: mock.host)?.url?.path == "/auth/me")
		#expect(
			MockURLProtocol.lastRequest(host: mock.host)?.value(forHTTPHeaderField: "Authorization")
				== "Bearer devtoken123")
	}

	@Test func providerKeyHeaderIsSetWhenProvided() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"ok":true}"#)
		let (client, store) = makeClient(mock: mock)
		defer { try? store.delete() }
		try store.save("t")

		let _: EmptyResponseProbe = try await client.get("/x", providerKey: "sk-byok-123")
		#expect(
			MockURLProtocol.lastRequest(host: mock.host)?.value(forHTTPHeaderField: "X-Provider-Key")
				== "sk-byok-123")
	}

	@Test func queryStringIsPreservedNotPercentEncoded() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"ok":true}"#)
		let (client, store) = makeClient(mock: mock)
		defer { try? store.delete() }
		try store.save("t")

		let _: EmptyResponseProbe = try await client.get("/recipes?limit=100")
		#expect(MockURLProtocol.lastRequest(host: mock.host)?.url?.path == "/recipes")
		#expect(MockURLProtocol.lastRequest(host: mock.host)?.url?.query == "limit=100")
	}

	@Test func missingTokenThrowsNotAuthenticated() async {
		let mock = MockURLProtocol.make(status: 200, json: #"{"ok":true}"#)
		let (client, store) = makeClient(mock: mock)
		try? store.delete()
		await #expect(throws: WhisperaAPIError.self) { _ = try await client.getMe() }
	}

	@Test func httpErrorIsMapped() async throws {
		let mock = MockURLProtocol.make(status: 401, json: #"{"error":"Unauthorized"}"#)
		let (client, store) = makeClient(mock: mock)
		defer { try? store.delete() }
		try store.save("t")
		await #expect(throws: WhisperaAPIError.self) { _ = try await client.getMe() }
	}
}

struct EmptyResponseProbe: Decodable {
	let ok: Bool
}

@MainActor
private final class MockClerkProvider: ClerkSessionProviding {
	var userEmail: String? = "clerk@example.com"
	var userName: String? = nil
	var userId: String? = "clerk_user"
	var hasActiveSession = false
	var token: String?
	var signOutCalled = false

	func load() async throws {}
	func sessionToken() async throws -> String? { token }
	func signOut() async throws { signOutCalled = true }
}

@MainActor
struct AuthManagerTests {

	private func makeAuth(
		mock: MockURLProtocol.Mock,
		clerk: ClerkSessionProviding
	) -> (AuthManager, AuthTokenStore) {
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		let client = WhisperaAPIClient(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })
		let auth = AuthManager(api: client, tokenStore: store, clerk: clerk)
		return (auth, store)
	}

	@Test func signInSuccessStoresUser() async {
		let mock = MockURLProtocol.make(
			status: 200, json: #"{"id":"u1","clerkId":"tok","email":"x@y.z","name":null}"#)
		let (auth, store) = makeAuth(mock: mock, clerk: MockClerkProvider())
		defer { try? store.delete() }

		await auth.signIn(token: "tok")
		#expect(auth.isSignedIn)
		#expect(auth.user?.email == "x@y.z")
		#expect((try? store.load()) == "tok")
	}

	@Test func signInFailureRevertsToken() async {
		let mock = MockURLProtocol.make(status: 401, json: #"{"error":"Unauthorized"}"#)
		let (auth, store) = makeAuth(mock: mock, clerk: MockClerkProvider())
		defer { try? store.delete() }

		await auth.signIn(token: "bad")
		#expect(!auth.isSignedIn)
		#expect((try? store.load()) == nil)
		#expect(auth.lastError != nil)
	}

	@Test func clerkSignInPersistsSessionTokenAndUser() async {
		let clerk = MockClerkProvider()
		clerk.hasActiveSession = true
		clerk.token = "clerk-jwt"
		let mock = MockURLProtocol.make { request in
			#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer clerk-jwt")
			let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (r, Data(#"{"id":"u1","clerkId":"clerk_user","email":"clerk@example.com","name":null}"#.utf8))
		}
		let (auth, store) = makeAuth(mock: mock, clerk: clerk)
		defer { try? store.delete() }

		await auth.signInWithClerk()
		#expect(auth.isSignedIn)
		#expect(auth.user?.email == "clerk@example.com")
		#expect((try? store.load()) == "clerk-jwt")
		#expect(!auth.isClerkSheetPresented)
	}

	@Test func clerkSignInShowsSheetWhenNoActiveSession() async {
		let clerk = MockClerkProvider()
		clerk.hasActiveSession = false
		let mock = MockURLProtocol.make(status: 200, json: #"{"ok":true}"#)
		let (auth, store) = makeAuth(mock: mock, clerk: clerk)
		defer { try? store.delete() }

		await auth.signInWithClerk()
		#expect(!auth.isSignedIn)
		#expect(auth.isClerkSheetPresented)
		#expect((try? store.load()) == nil)
	}

	@Test func signOutClearsTokenAndClerkSession() async {
		let clerk = MockClerkProvider()
		let mock = MockURLProtocol.make(status: 200, json: #"{"ok":true}"#)
		let (auth, store) = makeAuth(mock: mock, clerk: clerk)
		try? store.save("persisted")

		auth.signOut()
		try? await Task.sleep(for: .milliseconds(20))
		#expect((try? store.load()) == nil)
		#expect(!auth.isSignedIn)
		#expect(clerk.signOutCalled)
	}
}
