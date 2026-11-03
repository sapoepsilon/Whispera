import Foundation
import XCTest

@testable import LinkHelperXPC

/// The approve key's storage and the one-time move out of the legacy plain file, with a fake
/// store and a fake enclave check: no real Keychain or Secure Enclave involved.
final class MacApproveKeyStoreTests: XCTestCase {
	private final class FakeStore: MacApproveKeyStoring, @unchecked Sendable {
		var data: Data?
		var failSave = false
		var corruptOnSave = false
		private(set) var saves = 0

		func load() throws -> Data? { data }

		func save(_ data: Data) throws {
			saves += 1
			if failSave { throw MacApproveKeyStoreError(status: errSecMissingEntitlement) }
			self.data = corruptOnSave ? Data("x".utf8) : data
		}

		func delete() throws { data = nil }
	}

	private final class Lines: @unchecked Sendable {
		var all: [String] = []
	}

	private var directory: URL!
	private var legacy: URL { directory.appendingPathComponent("link-approve-key.json") }
	private let identity = MacApproveKey.Identity(
		deviceID: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", keyBlob: Data([1, 2, 3]), publicKeyX963: Data([4, 5]),
		createdAt: 1_700_000_000)

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"approve-key-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private func writeLegacy() throws -> Data {
		let data = try JSONEncoder().encode(identity)
		try data.write(to: legacy)
		return data
	}

	private func key(_ store: FakeStore, opens: Bool = true, lines: Lines = Lines()) -> MacApproveKey {
		MacApproveKey(
			store: store, legacyFileURL: legacy, opensInEnclave: { _ in opens }, log: { lines.all.append($0) })
	}

	func testNoKeyAnywhereIsNoIdentity() {
		XCTAssertNil(key(FakeStore()).identity)
	}

	func testLegacyFileMovesIntoTheStoreAndIsDeleted() throws {
		let data = try writeLegacy()
		let store = FakeStore()
		let lines = Lines()
		XCTAssertEqual(key(store, lines: lines).identity, identity)
		XCTAssertEqual(store.data, data)
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
		XCTAssertTrue(lines.all.contains { $0.contains("migrated into the Keychain") })
		// Later reads come from the store alone.
		XCTAssertEqual(key(store).identity, identity)
		XCTAssertEqual(store.saves, 1)
	}

	func testStoreWriteFailureKeepsTheFileAndStillSigns() throws {
		_ = try writeLegacy()
		let store = FakeStore()
		store.failSave = true
		let lines = Lines()
		XCTAssertEqual(key(store, lines: lines).identity, identity)
		XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
		XCTAssertTrue(lines.all.contains { $0.contains("keeping the legacy file") })
	}

	func testStoreThatReturnsOtherBytesKeepsTheFile() throws {
		_ = try writeLegacy()
		let store = FakeStore()
		store.corruptOnSave = true
		XCTAssertEqual(key(store).identity, identity)
		XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
	}

	func testKeyThatNoLongerOpensInTheEnclaveIsNotImported() throws {
		_ = try writeLegacy()
		let store = FakeStore()
		_ = key(store, opens: false).identity
		XCTAssertNil(store.data)
		XCTAssertEqual(store.saves, 0)
		XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
	}

	func testStoredKeyWinsAndALeftoverFileIsRemoved() throws {
		let other = MacApproveKey.Identity(
			deviceID: "dev_bbbbbbbbbbbbbbbbbbbbbbbb", keyBlob: Data([9]), publicKeyX963: Data([8]), createdAt: 1)
		let store = FakeStore()
		store.data = try JSONEncoder().encode(other)
		_ = try writeLegacy()
		XCTAssertEqual(key(store).identity, other)
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
		XCTAssertEqual(store.saves, 0)
	}

	func testRemoveClearsTheStoreAndTheFile() throws {
		_ = try writeLegacy()
		let store = FakeStore()
		store.failSave = true
		let approveKey = key(store)
		_ = approveKey.identity
		store.data = try JSONEncoder().encode(identity)
		approveKey.remove()
		XCTAssertNil(store.data)
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
		XCTAssertNil(approveKey.identity)
	}
}
