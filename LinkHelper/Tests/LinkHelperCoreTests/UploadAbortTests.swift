import Foundation
import XCTest

@testable import LinkHelperCore

/// A phone that gives up on an upload can delete it; uploads nobody finishes are swept on a
/// timer; and one phone's slow submission never holds up another's.
final class UploadAbortTests: XCTestCase {
	private static let chunk = 24 * 1024

	private func filePart(_ data: Data, offset: Int, name: String = "notes.txt") -> [String: Any] {
		[
			"name": name, "total_bytes": data.count, "offset": offset,
			"data": data.subdata(in: offset..<min(offset + Self.chunk, data.count)).base64EncodedString(),
		]
	}

	private func imagePart(_ data: Data, offset: Int) -> [String: Any] {
		[
			"mime_type": "image/jpeg", "total_bytes": data.count, "offset": offset,
			"data": data.subdata(in: offset..<min(offset + Self.chunk, data.count)).base64EncodedString(),
		]
	}

	private func submissionsFolder(_ helper: TestDaemon, _ phone: SoftPhone) -> URL {
		helper.directory.appendingPathComponent("state/submissions").appendingPathComponent(phone.deviceID)
	}

	func testDeletingAPartialUploadRemovesItsChunksAndOnlyTheOwnerCan() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("uploads_abort"))

		let file = Data((0..<(3 * Self.chunk)).map { UInt8(truncatingIfNeeded: $0) })
		let fileID = UUID().uuidString.lowercased()
		let first = try await phone.call("POST", "/v1/files/\(fileID)", json: filePart(file, offset: 0))
		XCTAssertEqual(first.status, 200, String(decoding: first.body, as: UTF8.self))
		XCTAssertEqual(first.json["complete"] as? Bool, false)
		let image = Data(repeating: 0xAB, count: 2 * Self.chunk)
		let imageID = UUID().uuidString.lowercased()
		let half = try await phone.call("POST", "/v1/images/\(imageID)", json: imagePart(image, offset: 0))
		XCTAssertEqual(half.json["received_bytes"] as? Int, Self.chunk)

		let folder = submissionsFolder(helper, phone)
		let fm = FileManager.default
		XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("files/\(fileID)/notes.txt").path))
		XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(imageID + ".jpg").path))

		// Another phone can't touch it: its delete looks only in its own folder.
		let other = try await helper.pairedPhone()
		let foreign = try await other.call("DELETE", "/v1/files/\(fileID)")
		XCTAssertEqual(foreign.status, 200)
		XCTAssertEqual(foreign.json["deleted"] as? Bool, false)
		XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("files/\(fileID)/notes.txt").path))

		let deleted = try await phone.call("DELETE", "/v1/files/\(fileID)")
		XCTAssertEqual(deleted.status, 200, String(decoding: deleted.body, as: UTF8.self))
		XCTAssertEqual(deleted.json["deleted"] as? Bool, true)
		XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("files/\(fileID)").path))
		XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(fileID + ".file.json").path))
		let imageGone = try await phone.call("DELETE", "/v1/images/\(imageID)")
		XCTAssertEqual(imageGone.json["deleted"] as? Bool, true)
		XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(imageID + ".jpg").path))
		XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(imageID + ".image.json").path))

		// Idempotent, and a chunk that arrives after the delete has to start over.
		let again = try await phone.call("DELETE", "/v1/images/\(imageID)")
		XCTAssertEqual(again.json["deleted"] as? Bool, false)
		let late = try await phone.call("POST", "/v1/files/\(fileID)", json: filePart(file, offset: Self.chunk))
		XCTAssertEqual(late.errorCode, "file_offset")
		let bad = try await phone.call("DELETE", "/v1/files/not-a-uuid")
		XCTAssertEqual(bad.status, 400)
		XCTAssertEqual(LinkAPI.match("DELETE", "/v1/images/\(imageID)")?.auth, .signed)
	}

	func testImageChunksAppendAndTheFinishedImageIsStillChecked() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let image = Data(repeating: 7, count: Self.chunk + 10)
		let id = UUID().uuidString.lowercased()
		let first = try submissions.upload(id, device: "dev_a", request: imagePart(image, offset: 0))
		XCTAssertEqual(first["received_bytes"] as? Int, Self.chunk)
		let path = state.appendingPathComponent("submissions/dev_a/\(id).jpg").path
		let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
		let repeated = try submissions.upload(id, device: "dev_a", request: imagePart(image, offset: 0))
		XCTAssertEqual(repeated["received_bytes"] as? Int, Self.chunk, "a repeated chunk is not appended")
		XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int, inode, "appended in place")
		XCTAssertThrowsError(try submissions.upload(id, device: "dev_a", request: imagePart(image, offset: Self.chunk))) {
			XCTAssertEqual(($0 as? APIError)?.code, "invalid_image", "not a JPEG once complete")
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: path))
	}

	func testTheSweepRemovesStalePartialsAndKeepsTheRest() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let data = Data(repeating: 1, count: 2 * Self.chunk)
		let stale = UUID().uuidString.lowercased(), fresh = UUID().uuidString.lowercased()
		let done = UUID().uuidString.lowercased(), staleImage = UUID().uuidString.lowercased()
		_ = try submissions.uploadFile(stale, device: "dev_a", request: filePart(data, offset: 0))
		_ = try submissions.uploadFile(fresh, device: "dev_b", request: filePart(data, offset: 0))
		_ = try submissions.uploadFile(done, device: "dev_a", request: filePart(data, offset: 0))
		_ = try submissions.uploadFile(done, device: "dev_a", request: filePart(data, offset: Self.chunk))
		_ = try submissions.upload(staleImage, device: "dev_b", request: imagePart(data, offset: 0))
		let root = state.appendingPathComponent("submissions")
		let old = Date().addingTimeInterval(-2 * 3600)
		for path in ["dev_a/files/\(stale)/notes.txt", "dev_a/\(stale).file.json", "dev_a/files/\(done)/notes.txt", "dev_b/\(staleImage).jpg"] {
			try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(path).path)
		}
		let swept = submissions.sweep()
		XCTAssertEqual(swept.partials, 2)
		let fm = FileManager.default
		XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("dev_a/files/\(stale)").path))
		XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("dev_a/\(stale).file.json").path))
		XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("dev_b/\(staleImage).jpg").path))
		XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("dev_b/files/\(fresh)/notes.txt").path), "a growing upload stays")
		XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("dev_a/files/\(done)/notes.txt").path), "a finished upload stays")

		// Finished uploads and receipts go after a week.
		XCTAssertEqual(submissions.sweep(now: Date().addingTimeInterval(8 * 86400)).expired > 0, true)
		XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("dev_a/files/\(done)").path))
	}

	func testTheSweepRunsOnItsTimerWithoutNewUploads() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let id = UUID().uuidString.lowercased()
		_ = try submissions.uploadFile(id, device: "dev_a", request: filePart(Data(repeating: 2, count: 2 * Self.chunk), offset: 0))
		let file = state.appendingPathComponent("submissions/dev_a/files/\(id)/notes.txt")
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
		let swept = expectation(description: "swept")
		submissions.startSweeping(every: 0.2, firstAfter: 0.1) { partials, _ in if partials > 0 { swept.fulfill() } }
		defer { submissions.stopSweeping() }
		wait(for: [swept], timeout: 3)
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
	}

	func testTwoPhonesSubmitAtTheSameTime() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let slowCopyStarted = DispatchSemaphore(value: 0)
		let releaseSlowCopy = DispatchSemaphore(value: 0)
		let slowDone = expectation(description: "slow phone delivered")
		DispatchQueue.global().async {
			let answer = try? submissions.submit(
				UUID().uuidString.lowercased(), device: "dev_slow", agent: "m_x.w1:p1", text: "slow", images: [],
				prepare: { paths in
					slowCopyStarted.signal()
					// A long scp to an unreachable machine.
					_ = releaseSlowCopy.wait(timeout: .now() + 10)
					return paths
				}, send: { _ in ["ok": "slow"] })
			XCTAssertEqual(answer?["ok"] as? String, "slow")
			slowDone.fulfill()
		}
		XCTAssertEqual(slowCopyStarted.wait(timeout: .now() + 5), .success)
		let started = Date()
		let fast = try submissions.submit(
			UUID().uuidString.lowercased(), device: "dev_fast", agent: "w1:p1", text: "fast", images: [],
			prepare: { $0 }, send: { _ in ["ok": "fast"] })
		XCTAssertEqual(fast["ok"] as? String, "fast")
		XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the other phone did not wait for the slow copy")
		// The same phone's other message is not held up either; only a retry of the same id waits.
		let sameDevice = try submissions.submit(
			UUID().uuidString.lowercased(), device: "dev_slow", agent: "w1:p1", text: "second", images: [],
			prepare: { $0 }, send: { _ in ["ok": "second"] })
		XCTAssertEqual(sameDevice["ok"] as? String, "second")
		releaseSlowCopy.signal()
		wait(for: [slowDone], timeout: 5)
	}

	func testARetryOfTheSameSubmissionWaitsAndIsNotSentTwice() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let id = UUID().uuidString.lowercased()
		let sends = SendCounter()
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let firstDone = expectation(description: "first")
		DispatchQueue.global().async {
			_ = try? submissions.submit(id, device: "dev", agent: "w1:p1", text: "hi", images: [],
				prepare: { paths in entered.signal(); _ = release.wait(timeout: .now() + 10); return paths },
				send: { _ in sends.bump(); return ["n": 1] })
			firstDone.fulfill()
		}
		XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
		let retryDone = expectation(description: "retry")
		DispatchQueue.global().async {
			let answer = try? submissions.submit(id, device: "dev", agent: "w1:p1", text: "hi", images: [],
				prepare: { $0 }, send: { _ in sends.bump(); return ["n": 2] })
			XCTAssertEqual(answer?["n"] as? Int, 1, "the retry answers the first delivery's receipt")
			retryDone.fulfill()
		}
		Thread.sleep(forTimeInterval: 0.2)
		release.signal()
		wait(for: [firstDone, retryDone], timeout: 5)
		XCTAssertEqual(sends.count, 1)
	}

	func testACancelledSubmissionStopsBeforeTheTerminalWrite() throws {
		let state = FileManager.default.temporaryDirectory.appendingPathComponent("wlu-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: state) }
		let submissions = AgentSubmissions(stateDirectory: state.path)
		let token = CancelToken()
		let sends = SendCounter()
		XCTAssertThrowsError(
			try CancelToken.with(token) {
				try submissions.submit(UUID().uuidString.lowercased(), device: "dev", agent: "w1:p1", text: "hi", images: [],
					prepare: { paths in token.cancel("phone left"); return paths },
					send: { _ in sends.bump(); return [:] })
			}
		) { XCTAssertTrue($0 is RequestCancelled) }
		XCTAssertEqual(sends.count, 0)
	}
}

final class SendCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	func bump() { lock.lock(); value += 1; lock.unlock() }
	var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
