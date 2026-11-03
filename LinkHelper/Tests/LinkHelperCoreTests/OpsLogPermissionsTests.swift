import Foundation
import XCTest

@testable import LinkHelperCore

final class OpsLogPermissionsTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("opslog-\(UUID().uuidString)")
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private func permissions(_ path: String) throws -> Int {
		(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
	}

	func testNewLogIsOwnerOnly() throws {
		let path = directory.appendingPathComponent("whispera-link.log").path
		OpsLog(path: path)("serve", ["detail": "listening"])
		XCTAssertEqual(try permissions(path), 0o600)
	}

	func testExistingWorldReadableLogIsTightened() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let path = directory.appendingPathComponent("whispera-link.log").path
		XCTAssertTrue(
			FileManager.default.createFile(
				atPath: path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644]))
		OpsLog(path: path)("serve")
		XCTAssertEqual(try permissions(path), 0o600)
		XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("old\n"))
	}
}
