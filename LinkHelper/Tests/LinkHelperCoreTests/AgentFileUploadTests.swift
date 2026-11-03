import Foundation
import WhisperaLink
import XCTest
@testable import LinkHelperCore

/// File attachments of any type over the real signed HTTP boundary: chunked like images,
/// saved under the phone's folder with a sanitized original name, and referenced in the prompt.
final class AgentFileUploadTests: XCTestCase {
    private static let chunk = 24 * 1024

    private func upload(_ phone: SoftPhone, id: String, name: String, data: Data) async throws -> SoftPhone.Response {
        var last: SoftPhone.Response?
        for offset in stride(from: 0, to: data.count, by: Self.chunk) {
            let part = data.subdata(in: offset..<min(offset + Self.chunk, data.count))
            let response = try await phone.call("POST", "/v1/files/\(id)", json: [
                "name": name, "total_bytes": data.count, "offset": offset, "data": part.base64EncodedString(),
            ])
            guard response.status == 200 else { return response }
            last = response
        }
        return try XCTUnwrap(last)
    }

    private static func crashLog(bytes: Int) -> Data {
        var text = ""
        var line = 0
        while text.utf8.count < bytes {
            text += "{\"bug_type\":\"298\",\"line\":\(line),\"process\":\"WhisperaKeyboard\",\"reason\":\"per-process-limit\"}\n"
            line += 1
        }
        return Data(text.utf8.prefix(bytes))
    }

    func testAFileOfAnyTypeKeepsItsNameAndReachesThePromptByPath() async throws {
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let helper = try TestDaemon(herdrSocket: rig.localSocket); defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let health = try await phone.call("GET", "/v1/health")
        XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("file_uploads"))

        let data = Self.crashLog(bytes: 200 * 1024 + 17)
        let fileID = UUID().uuidString.lowercased()
        let done = try await upload(phone, id: fileID, name: "JetsamEvent-2026-10-29-120000.ips", data: data)
        XCTAssertEqual(done.status, 200, String(decoding: done.body, as: UTF8.self))
        XCTAssertEqual(done.json["complete"] as? Bool, true)
        XCTAssertEqual(done.json["name"] as? String, "JetsamEvent-2026-10-29-120000.ips")
        // A repeated chunk (lost response) is accepted without appending.
        let again = try await phone.call("POST", "/v1/files/\(fileID)", json: [
            "name": "JetsamEvent-2026-10-29-120000.ips", "total_bytes": data.count, "offset": 0,
            "data": data.prefix(Self.chunk).base64EncodedString(),
        ])
        XCTAssertEqual(again.json["received_bytes"] as? Int, data.count)

        let submission = UUID().uuidString.lowercased()
        let body: [String: Any] = ["text": "Why did the keyboard die?", "submission_id": submission, "files": [fileID]]
        let first = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: body)
        XCTAssertEqual(first.status, 200, String(decoding: first.body, as: UTF8.self))
        let retry = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: body)
        XCTAssertEqual(retry.body, first.body)
        let writes = try rig.writes(rig.localSocket).filter { $0.0 == "agent.prompt" }
        XCTAssertEqual(writes.count, 1, "an acknowledged retry does not resend")
        let delivered = try XCTUnwrap(writes.first?.1["text"] as? String)
        XCTAssertTrue(delivered.hasPrefix("Why did the keyboard die?\n\n" + AgentSubmissions.filesMarker + "\n"))
        let path = try XCTUnwrap(delivered.split(separator: "\n").last).description
        XCTAssertTrue(path.hasSuffix("/files/\(fileID)/JetsamEvent-2026-10-29-120000.ips"), path)
        XCTAssertTrue(path.hasPrefix(helper.directory.appendingPathComponent("state/submissions").path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        let holder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: holder)[.posixPermissions] as? Int, 0o700)

        // Another phone can neither see nor send this phone's upload.
        let other = try await helper.pairedPhone()
        let stolen = try await other.call("POST", "/v1/agents/w1:p1/prompt", json: [
            "text": "x", "submission_id": UUID().uuidString.lowercased(), "files": [fileID],
        ])
        XCTAssertEqual(stolen.errorCode, "file_incomplete")
    }

    func testImagesAndFilesTogetherAndAnUnfinishedFileIsRefused() async throws {
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let helper = try TestDaemon(herdrSocket: rig.localSocket); defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let data = Data((0..<(Self.chunk + 5)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let partial = UUID().uuidString.lowercased()
        let first = try await phone.call("POST", "/v1/files/\(partial)", json: [
            "name": "logs.zip", "total_bytes": data.count, "offset": 0, "data": data.prefix(Self.chunk).base64EncodedString(),
        ])
        XCTAssertEqual(first.json["complete"] as? Bool, false)
        let refused = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: [
            "text": "look", "submission_id": UUID().uuidString.lowercased(), "files": [partial],
        ])
        XCTAssertEqual(refused.errorCode, "file_incomplete")
        XCTAssertTrue(try rig.writes(rig.localSocket).filter { $0.0 == "agent.prompt" }.isEmpty)

        let gap = try await phone.call("POST", "/v1/files/\(partial)", json: [
            "name": "logs.zip", "total_bytes": data.count, "offset": Self.chunk + 1, "data": Data([1, 2]).base64EncodedString(),
        ])
        XCTAssertEqual(gap.errorCode, "file_offset")
        let renamed = try await phone.call("POST", "/v1/files/\(partial)", json: [
            "name": "other.zip", "total_bytes": data.count, "offset": Self.chunk, "data": data.suffix(5).base64EncodedString(),
        ])
        XCTAssertEqual(renamed.errorCode, "file_conflict")
        let tooBig = try await phone.call("POST", "/v1/files/\(UUID().uuidString.lowercased())", json: [
            "name": "huge.bin", "total_bytes": AgentSubmissions.maxFile + 1, "offset": 0, "data": Data([1]).base64EncodedString(),
        ])
        XCTAssertEqual(tooBig.status, 400)
        let traversal = try await phone.call("POST", "/v1/files/..%2fsecret", json: [
            "name": "a.txt", "total_bytes": 1, "offset": 0, "data": Data([1]).base64EncodedString(),
        ])
        XCTAssertEqual(traversal.status, 400)

        let rest = try await phone.call("POST", "/v1/files/\(partial)", json: [
            "name": "logs.zip", "total_bytes": data.count, "offset": Self.chunk, "data": data.suffix(5).base64EncodedString(),
        ])
        XCTAssertEqual(rest.json["complete"] as? Bool, true)
        let client = LinkClient(baseURL: helper.baseURL, deviceID: phone.deviceID, linkKey: phone.linkKey, daemonPubkey: Data())
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let imageID = UUID().uuidString.lowercased()
        _ = try await client.uploadImage(png, id: imageID, mimeType: "image/png")
        let sent = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: [
            "text": "both", "submission_id": UUID().uuidString.lowercased(), "images": [imageID], "files": [partial],
        ])
        XCTAssertEqual(sent.status, 200, String(decoding: sent.body, as: UTF8.self))
        let delivered = try XCTUnwrap(try rig.writes(rig.localSocket).first { $0.0 == "agent.prompt" }?.1["text"] as? String)
        let lines = delivered.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "both")
        XCTAssertEqual(lines[2], "Attached images (open these files to view):")
        XCTAssertTrue(lines[3].hasSuffix(imageID + ".png"))
        XCTAssertEqual(lines[5], AgentSubmissions.filesMarker)
        XCTAssertTrue(lines[6].hasSuffix("/files/\(partial)/logs.zip"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: lines[6])), data)
    }

    func testPromptTextAboveTheOldLimitIsAccepted() async throws {
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let helper = try TestDaemon(herdrSocket: rig.localSocket); defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let text = String(repeating: "log line\n", count: 1200)
        XCTAssertGreaterThan(text.unicodeScalars.count, 8000)
        let sent = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: [
            "text": text, "submission_id": UUID().uuidString.lowercased(),
        ])
        XCTAssertEqual(sent.status, 200, String(decoding: sent.body, as: UTF8.self))
        let tooLong = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: [
            "text": String(repeating: "a", count: AgentSubmissions.maxText + 1), "submission_id": UUID().uuidString.lowercased(),
        ])
        XCTAssertEqual(tooLong.status, 400)
    }

    func testFileNamesAreSanitizedButKeepTheirExtension() {
        XCTAssertEqual(AgentSubmissions.safeFileName("WhisperaKeyboard-2026-10-29-120000.ips"), "WhisperaKeyboard-2026-10-29-120000.ips")
        XCTAssertEqual(AgentSubmissions.safeFileName("Pasted text.txt"), "Pasted_text.txt")
        XCTAssertEqual(AgentSubmissions.safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(AgentSubmissions.safeFileName(".."), "file")
        XCTAssertEqual(AgentSubmissions.safeFileName(".zshrc"), "file.zshrc")
        XCTAssertEqual(AgentSubmissions.safeFileName("$(rm -rf ~); `x`.log"), "rm_-rf_x.log")
        XCTAssertEqual(AgentSubmissions.safeFileName("отчёт.pdf"), "file.pdf")
        XCTAssertEqual(AgentSubmissions.safeFileName("-n.txt"), "n.txt")
        XCTAssertNil(AgentSubmissions.safeFileName(""))
        XCTAssertNil(AgentSubmissions.safeFileName("a\0b"))
        let long = AgentSubmissions.safeFileName(String(repeating: "x", count: 300) + ".json")
        XCTAssertEqual(long, String(repeating: "x", count: 100) + ".json")
        for name in ["Pasted_text.txt", "a.b.c", "file.pdf", "x+y@z.log"] {
            XCTAssertEqual(AgentSubmissions.safeFileName(name), name, "sanitizing is stable")
        }
    }

    func testRemoteCopiesKeepFilesApart() {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(AgentDirectory.remoteName("/s/dev/files/\(id)/crash.ips"), id + "-crash.ips")
        XCTAssertEqual(AgentDirectory.remoteName("/s/dev/\(id).jpg"), id + ".jpg")
    }
}
