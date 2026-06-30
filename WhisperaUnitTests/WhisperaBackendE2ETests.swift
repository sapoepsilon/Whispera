import Foundation
import Testing

@testable import Whispera

/// Live integration tests against a locally-running whispera-backend.
///
/// Opt-in: only runs when `WHISPERA_E2E=1` so normal/CI runs stay offline.
/// Start the backend first (NODE_ENV=test, port 3000) — see the project memory
/// `whispera-client-e2e-env`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WHISPERA_E2E"] == "1"))
struct WhisperaBackendE2ETests {

	private let baseURL = URL(string: "http://localhost:3000")!
	private let devToken = "whisperae2e"

	private func client(_ store: AuthTokenStore) -> WhisperaAPIClient {
		WhisperaAPIClient(tokenStore: store, serverURLProvider: { self.baseURL })
	}

	@Test func authMeReturnsClerkIdForDevToken() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)

		let user = try await client(store).getMe()
		#expect(user.clerkId == devToken)
	}
}
