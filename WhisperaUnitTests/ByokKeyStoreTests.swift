import Foundation
import Testing

@testable import Whispera

struct ByokKeyStoreTests {

	/// A keychain store scoped to a unique service so parallel tests never collide
	/// and never touch the user's real BYOK keys.
	private func isolatedStore() -> ByokKeyStore {
		ByokKeyStore(service: "com.whispera.byok.test.\(UUID().uuidString)")
	}

	@Test func saveThenLoadRoundTrips() throws {
		let store = isolatedStore()
		defer { try? store.delete(provider: .openai) }

		try store.save(provider: .openai, key: "sk-test-roundtrip-1234567890")
		#expect(try store.load(provider: .openai) == "sk-test-roundtrip-1234567890")
	}

	@Test func saveOverwritesExistingKey() throws {
		let store = isolatedStore()
		defer { try? store.delete(provider: .openai) }

		try store.save(provider: .openai, key: "first")
		try store.save(provider: .openai, key: "second")
		#expect(try store.load(provider: .openai) == "second")
	}

	@Test func loadMissingReturnsNil() throws {
		let store = isolatedStore()
		#expect(try store.load(provider: .anthropic) == nil)
	}

	@Test func deleteRemovesKey() throws {
		let store = isolatedStore()
		try store.save(provider: .openai, key: "to-delete")
		try store.delete(provider: .openai)
		#expect(try store.load(provider: .openai) == nil)
	}

	@Test func deleteMissingDoesNotThrow() throws {
		let store = isolatedStore()
		#expect(throws: Never.self) { try store.delete(provider: .anthropic) }
	}

	@Test func providersListsStoredWithoutLoadingMaterial() throws {
		let store = isolatedStore()
		defer {
			try? store.delete(provider: .openai)
			try? store.delete(provider: .anthropic)
		}

		#expect(try store.providers().isEmpty)
		try store.save(provider: .openai, key: "sk-openai")
		try store.save(provider: .anthropic, key: "sk-ant-anthropic")

		let providers = try store.providers()
		#expect(Set(providers) == Set([.openai, .anthropic]))
	}
}

struct LogRedactorTests {

	@Test func redactsOpenAIStyleKey() {
		let redacted = LogRedactor.redact("using key sk-proj-abcdefghij1234567890XYZ now")
		#expect(!redacted.contains("abcdefghij1234567890"))
		#expect(redacted.contains("REDACTED"))
	}

	@Test func redactsAnthropicStyleKey() {
		let redacted = LogRedactor.redact("key=sk-ant-api03-abcdefghijklmnop1234567890")
		#expect(!redacted.contains("abcdefghijklmnop"))
	}

	@Test func leavesNormalTextUntouched() {
		let message = "recipe executed in 240ms, output 42 chars"
		#expect(LogRedactor.redact(message) == message)
	}
}
