import AppKit
import WhisperaLink
import XCTest
@testable import LinkHelperCore

/// Real signed HTTP and terminal protocol boundary, using only generated test agents.
final class AgentSubmissionTests: XCTestCase {
    func testImagesArePrivateCompleteAndAnAcknowledgedRetryDoesNotResend() async throws {
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let helper = try TestDaemon(herdrSocket: rig.localSocket); defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        var random: UInt32 = 1234
        for i in 0..<bitmap.bytesPerRow * bitmap.pixelsHigh {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            bitmap.bitmapData![i] = UInt8(truncatingIfNeeded: random)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]))
        XCTAssertGreaterThan(data.count, 24 * 1024, "exercise multiple signed upload chunks")
        let client = LinkClient(baseURL: helper.baseURL, deviceID: phone.deviceID, linkKey: phone.linkKey,
                                daemonPubkey: Data())
        let imageID = UUID().uuidString.lowercased()
        _ = try await client.uploadImage(data, id: imageID)
        _ = try await client.uploadImage(data, id: imageID)
        let chunk: [String: Any] = ["mime_type": "image/jpeg", "total_bytes": data.count, "offset": 0,
                                   "data": data.prefix(24 * 1024).base64EncodedString()]
        let submission = UUID().uuidString.lowercased()
        let body: [String: Any] = ["text": "Describe this image", "images": [imageID], "submission_id": submission]
        let first = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: body)
        XCTAssertEqual(first.status, 200, String(decoding: first.body, as: UTF8.self))
        let retry = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: body)
        XCTAssertEqual(retry.status, 200)
        XCTAssertEqual(first.body, retry.body)
        let writes = try rig.writes(rig.localSocket).filter { $0.0 == "agent.prompt" }
        XCTAssertEqual(writes.count, 1)
        let delivered = try XCTUnwrap(writes.first?.1["text"] as? String)
        XCTAssertTrue(delivered.contains("Attached images"))
        let file = try XCTUnwrap(delivered.split(separator: "\n").last).description
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(writes.first?.1["wait"], "delivery never waits for turn completion")
        let other = try await helper.pairedPhone()
        let stolen = try await other.call("POST", "/v1/agents/w1:p1/prompt", json: body)
        XCTAssertEqual(stolen.errorCode, "image_incomplete")
        let conflict = try await phone.call("POST", "/v1/agents/w1:p1/prompt", json: ["text": "different", "submission_id": submission])
        XCTAssertEqual(conflict.errorCode, "submission_conflict")
        let badID = try await phone.call("POST", "/v1/images/..%2fsecret", json: chunk)
        XCTAssertEqual(badID.status, 400)
        let invalid = try await phone.call("POST", "/v1/images/\(UUID().uuidString)", json: ["mime_type": "image/png", "total_bytes": 3, "offset": 0, "data": Data("bad".utf8).base64EncodedString()])
        XCTAssertEqual(invalid.errorCode, "invalid_image")
    }
    func testRemoteAgentGetsImageOnItsOwnMachineBeforeThePrompt() async throws {
        let target = ProcessInfo.processInfo.environment["WL_REMOTE_IMAGE_QA_TARGET"] ?? ""
        try XCTSkipIf(target.isEmpty, "Set WL_REMOTE_IMAGE_QA_TARGET for the SSH image integration.")
        let rig = try FakeHerdrRig(); defer { rig.stop() }
        let config = rig.directory.appendingPathComponent("cli.json")
        var object = try XCTUnwrap(WireJSON.decodeObject(Data(contentsOf: config)))
        var machines = try XCTUnwrap(object["machines"] as? [[String: Any]])
        machines[0]["target"] = target; object["machines"] = machines
        try WireJSON.encode(object).write(to: config)
        let helper = try TestDaemon { config in config.herdrSocket = rig.localSocket; config.herdrCLI = rig.cli }
        defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let client = LinkClient(baseURL: helper.baseURL, deviceID: phone.deviceID, linkKey: phone.linkKey, daemonPubkey: Data())
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .jpeg, properties: [:]))
        let imageID = UUID().uuidString.lowercased()
        _ = try await client.uploadImage(data, id: imageID)
        let result = try await client.submitPrompt("m_fake-main.w9:p1", text: "Describe this QA image",
                                                  submissionID: UUID().uuidString.lowercased(), images: [imageID])
        XCTAssertEqual(result.agent.id, "m_fake-main.w9:p1")
        let prompt = try XCTUnwrap(rig.writes(rig.remoteSocket).first { $0.0 == "agent.prompt" })
        let text = try XCTUnwrap(prompt.1["text"] as? String)
        let path = try XCTUnwrap(text.split(separator: "\n").last).description
        XCTAssertTrue(path.hasSuffix(imageID + ".jpg"))
        let remote = try HerdrCLI.spawn("/usr/bin/ssh", ["-o", "BatchMode=yes", "--", target, "cat '" + path + "'"], timeout: 10)
        XCTAssertEqual(remote.status, 0); XCTAssertEqual(remote.stdout, data)
        let mode = try HerdrCLI.spawn("/usr/bin/ssh", ["-o", "BatchMode=yes", "--", target, "stat -f %Lp '" + path + "'"], timeout: 10)
        XCTAssertEqual(String(decoding: mode.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "600")
        _ = try HerdrCLI.spawn("/usr/bin/ssh", ["-o", "BatchMode=yes", "--", target, "rm -- '" + path + "'; rmdir '" + URL(fileURLWithPath: path).deletingLastPathComponent().path + "'"], timeout: 10)
    }

}
