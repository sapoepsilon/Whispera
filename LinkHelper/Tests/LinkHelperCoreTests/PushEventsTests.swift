import CryptoKit
import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A settable clock.
final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var current: Date
	init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
	var now: Date {
		lock.lock()
		defer { lock.unlock() }
		return current
	}
	func advance(_ seconds: TimeInterval) {
		lock.lock()
		current = current.addingTimeInterval(seconds)
		lock.unlock()
	}
}

/// What an `AgentEventNotifier` sent.
final class FakeEventSender: AgentEventSender, @unchecked Sendable {
	struct Call: Equatable {
		var device: String
		var kind: String
		var requestID: String
		var sealed: String?
	}

	private let lock = NSLock()
	private var stored: [Call] = []
	var configured = true

	var isEventConfigured: Bool { configured }

	func sendEvent(deviceID: String, kind: String, requestID: String, sealed: String?) async -> String {
		lock.lock()
		stored.append(Call(device: deviceID, kind: kind, requestID: requestID, sealed: sealed))
		lock.unlock()
		return "sent"
	}

	var calls: [Call] {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}

	func events() -> [Call] { calls.filter { $0.kind == "agent.event" } }
	func resolved() -> [Call] { calls.filter { $0.kind == "agent.event.resolved" } }
}

/// Mutable hook answers for the notifier.
final class EventHookState: @unchecked Sendable {
	private let lock = NSLock()
	private var _turnOpen: Bool?
	private var _running: Int?
	private var _exists: Bool? = true
	var turnOpen: Bool? {
		get { lock.lock(); defer { lock.unlock() }; return _turnOpen }
		set { lock.lock(); _turnOpen = newValue; lock.unlock() }
	}
	var running: Int? {
		get { lock.lock(); defer { lock.unlock() }; return _running }
		set { lock.lock(); _running = newValue; lock.unlock() }
	}
	var exists: Bool? {
		get { lock.lock(); defer { lock.unlock() }; return _exists }
		set { lock.lock(); _exists = newValue; lock.unlock() }
	}
}

final class PushEventsTests: XCTestCase {
	let macID = "dev_macmacmacmacmacmacmacmac"
	let mac = SoftwareAgreementKey()
	let phoneKey = SoftwareAgreementKey()
	let phoneID = "dev_aaaaaaaaaaaaaaaaaaaaaaaa"
	let agentID = "w1:p1"

	func sealer() throws -> PushSealer {
		let sealer = PushSealer()
		sealer.configure(macID: macID, agreementKey: mac, macName: "Test Mac")
		sealer.setPhoneKeys([phoneID: try LinkPublicKey(x963: phoneKey.publicKeyX963)])
		return sealer
	}

	func phoneSideKey() throws -> SymmetricKey {
		try PushSealing.deriveKey(
			agreementKey: phoneKey, peerKey: try LinkPublicKey(x963: mac.publicKeyX963), phoneID: phoneID, macID: macID)
	}

	func phone(_ id: String? = nil, text: PushTextMode = .named, confirmed: Bool = true) -> DeviceRecord {
		var record = PushRoutingTests.record(id ?? phoneID, createdAt: 100)
		record.pushText = text
		record.approveConfirmed = confirmed
		return record
	}

	private func wait(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
	}

	// MARK: §1 sealed superset

	func testAgentDialogsSealTheSupersetThatOldPhonesStillOpen() throws {
		let sealer = try sealer()
		let push = ApprovalPush(
			requestID: "apr_0123456789abcdef", expiresAt: 0, requester: "claude", key: "your approval",
			summary: "Run rm -rf build", project: "whispera", agentID: agentID, promptID: "pr_42", event: "permission")
		let sealed = try XCTUnwrap(sealer.seal(push, phoneID: phoneID))
		let key = try phoneSideKey()
		let plaintext = try PushSealing.openData(sealed, requestID: push.requestID, key: key)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
		XCTAssertEqual(
			Set(object.keys), ["agent_id", "body", "category", "event", "prompt_id", "request_id", "thread", "title"])
		let decoded = try JSONDecoder().decode(SealedPushPayload.self, from: plaintext)
		XCTAssertEqual(decoded.agent_id, agentID)
		XCTAssertEqual(decoded.prompt_id, "pr_42")
		XCTAssertEqual(decoded.event, "permission")
		XCTAssertEqual(decoded.category, "WL_PERMISSION")
		XCTAssertEqual(decoded.thread, "agent-\(agentID)")
		XCTAssertEqual(decoded.title, "claude wants your approval")
		XCTAssertEqual(decoded.body, "Run rm -rf build · whispera · on Test Mac")
		// Keys sorted, so the bytes are stable.
		let text = String(decoding: plaintext, as: UTF8.self)
		XCTAssertTrue(text.hasPrefix("{\"agent_id\":"))
		// An old phone decodes only PushPayload and still gets title/body.
		let old = try PushSealing.open(sealed, requestID: push.requestID, key: key)
		XCTAssertEqual(old.title, decoded.title)

		var ask = push
		ask.event = "ask"
		let askPlain = try PushSealing.openData(
			try XCTUnwrap(sealer.seal(ask, phoneID: phoneID)), requestID: ask.requestID, key: key)
		XCTAssertEqual(try JSONDecoder().decode(SealedPushPayload.self, from: askPlain).category, "WL_ASK")
	}

	func testBrokerApprovalsKeepThePlainPayload() throws {
		let sealer = try sealer()
		let push = ApprovalPush(requestID: "apr_fedcba9876543210", expiresAt: 0, requester: "ci", key: "deploy")
		let plaintext = try PushSealing.openData(
			try XCTUnwrap(sealer.seal(push, phoneID: phoneID)), requestID: push.requestID, key: try phoneSideKey())
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
		XCTAssertEqual(Set(object.keys), ["body", "request_id", "title"])
	}

	// MARK: §2 event derivation

	struct Rig {
		let notifier: AgentEventNotifier
		let sender: FakeEventSender
		let clock: TestClock
		let hooks: EventHookState
	}

	func rig(
		devices: [DeviceRecord]? = nil, prefs: NotificationPrefsStore? = nil, info: [String: Any]? = nil
	) throws -> Rig {
		let sender = FakeEventSender()
		let clock = TestClock()
		let state = EventHookState()
		let records = devices ?? [phone()]
		let described = info
		let notifier = AgentEventNotifier(
			hooks: AgentEventNotifier.Hooks(
				turnOpen: { _ in state.turnOpen }, subagentsRunning: { _, _ in state.running },
				exists: { _ in state.exists }, describe: { _ in described }),
			sender: sender, sealer: try sealer(), devices: { records }, prefs: prefs, now: { clock.now })
		return Rig(notifier: notifier, sender: sender, clock: clock, hooks: state)
	}

	func status(_ rig: Rig, _ status: String, agent: Any = "claude") {
		rig.notifier.observe("agent.status", ["id": agentID, "status": status, "agent": agent, "title": "fix tests"])
	}

	func testTurnDoneWaitsOutFlappingAndCollapsesPerTurn() async throws {
		let rig = try rig(info: ["name": "builder", "cwd": "/Users/x/whispera"])
		status(rig, "working")
		rig.clock.advance(5)
		status(rig, "idle")
		rig.clock.advance(1)
		rig.notifier.tick()
		status(rig, "working")  // a 1 s idle: flapping, not the end of the turn
		rig.clock.advance(5)
		rig.notifier.tick()
		XCTAssertTrue(rig.sender.calls.isEmpty)

		status(rig, "done")
		rig.clock.advance(2.9)
		rig.notifier.tick()
		XCTAssertTrue(rig.sender.calls.isEmpty, "inside the debounce")
		rig.clock.advance(0.2)
		rig.notifier.tick()
		try await wait { rig.sender.events().count == 1 }
		status(rig, "idle")
		rig.clock.advance(10)
		rig.notifier.tick()
		try await Task.sleep(nanoseconds: 100_000_000)
		let first = try XCTUnwrap(rig.sender.events().first)
		XCTAssertEqual(rig.sender.events().count, 1, "one turn_done per turn")
		XCTAssertEqual(first.device, phoneID)
		XCTAssertTrue(first.requestID.hasPrefix("evt_"))
		let plaintext = try PushSealing.openData(
			try XCTUnwrap(first.sealed), requestID: first.requestID, key: try phoneSideKey())
		let payload = try JSONDecoder().decode(SealedPushPayload.self, from: plaintext)
		XCTAssertEqual(payload.event, "turn_done")
		XCTAssertEqual(payload.category, "WL_AGENT")
		XCTAssertEqual(payload.agent_id, agentID)
		XCTAssertEqual(payload.thread, "agent-\(agentID)")
		XCTAssertEqual(payload.request_id, first.requestID)
		XCTAssertNil(payload.prompt_id)
		XCTAssertEqual(payload.title, "builder is done")
		XCTAssertEqual(payload.body, "fix tests · whispera · on Test Mac")

		// Working again supersedes it, and the next turn gets a new id.
		status(rig, "working")
		try await wait { rig.sender.resolved().count == 1 }
		XCTAssertEqual(rig.sender.resolved().first?.requestID, first.requestID)
		XCTAssertNil(rig.sender.resolved().first?.sealed)
		status(rig, "idle")
		rig.clock.advance(4)
		rig.notifier.tick()
		try await wait { rig.sender.events().count == 2 }
		XCTAssertNotEqual(rig.sender.events()[1].requestID, first.requestID)
	}

	func testAnOpenTurnInTheLogHoldsTurnDoneUntilItClosesOrTheCap() async throws {
		let rig = try rig()
		rig.hooks.turnOpen = true
		status(rig, "working")
		status(rig, "idle")
		rig.clock.advance(5)
		rig.notifier.tick()
		XCTAssertTrue(rig.sender.calls.isEmpty, "the log says the turn is still open")
		rig.hooks.turnOpen = false
		rig.notifier.tick()
		try await wait { rig.sender.events().count == 1 }

		let capped = try self.rig()
		capped.hooks.turnOpen = true
		status(capped, "working")
		status(capped, "idle")
		capped.clock.advance(29)
		capped.notifier.tick()
		XCTAssertTrue(capped.sender.calls.isEmpty)
		capped.clock.advance(2)
		capped.notifier.tick()
		try await wait { capped.sender.events().count == 1 }
	}

	func testIdleWithoutWorkAndBlockedDialogsAreNotTurnEnds() async throws {
		let rig = try rig()
		status(rig, "idle")
		rig.clock.advance(10)
		rig.notifier.tick()
		status(rig, "working")
		status(rig, "blocked")
		rig.clock.advance(10)
		rig.notifier.tick()
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertTrue(rig.sender.calls.isEmpty)
	}

	func payloadEvent(_ call: FakeEventSender.Call) throws -> String {
		let plaintext = try PushSealing.openData(
			try XCTUnwrap(call.sealed), requestID: call.requestID, key: try phoneSideKey())
		return try JSONDecoder().decode(SealedPushPayload.self, from: plaintext).event
	}

	func testAnAgentThatExitsOrVanishesMidTurnIsStopped() async throws {
		let rig = try rig()
		status(rig, "working")
		status(rig, "unknown", agent: NSNull())
		rig.clock.advance(3)
		rig.notifier.tick()
		try await wait { rig.sender.events().count == 1 }
		XCTAssertEqual(try payloadEvent(rig.sender.events()[0]), "stopped")

		let vanished = try self.rig()
		status(vanished, "working")
		vanished.hooks.exists = nil
		vanished.notifier.observe("agents.changed", [:])
		vanished.notifier.tick()
		XCTAssertTrue(vanished.sender.calls.isEmpty, "herdr could not say")
		vanished.hooks.exists = false
		vanished.notifier.tick()
		try await wait { vanished.sender.events().count == 1 }
		XCTAssertEqual(try payloadEvent(vanished.sender.events()[0]), "stopped")
		vanished.notifier.tick()
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertEqual(vanished.sender.events().count, 1)

		let idle = try self.rig()
		status(idle, "idle")
		idle.hooks.exists = false
		idle.notifier.observe("agents.changed", [:])
		idle.notifier.tick()
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertTrue(idle.sender.calls.isEmpty, "a closed idle pane is not a stop")
	}

	func testSubagentsDoneOnceAllFinish() async throws {
		let rig = try rig()
		status(rig, "working")
		rig.hooks.running = 2
		rig.notifier.tick()
		rig.hooks.running = 1
		rig.notifier.tick()
		XCTAssertTrue(rig.sender.calls.isEmpty)
		rig.hooks.running = 0
		rig.notifier.tick()
		rig.notifier.tick()
		try await wait { rig.sender.events().count == 1 }
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertEqual(rig.sender.events().count, 1)
		XCTAssertEqual(try payloadEvent(rig.sender.events()[0]), "subagents_done")
	}

	func testOnlyConfirmedNamedSealablePhonesGetAgentEvents() async throws {
		let generic = phone("dev_bbbbbbbbbbbbbbbbbbbbbbbb", text: .generic)
		let unconfirmed = phone("dev_cccccccccccccccccccccccc", confirmed: false)
		let noKey = phone("dev_dddddddddddddddddddddddd")
		let rig = try rig(devices: [phone(), generic, unconfirmed, noKey])
		XCTAssertEqual(rig.notifier.recipients("turn_done", agentID: agentID).map(\.deviceID), [phoneID])

		let unconfigured = try self.rig()
		unconfigured.sender.configured = false
		status(unconfigured, "working")
		status(unconfigured, "idle")
		unconfigured.clock.advance(4)
		unconfigured.notifier.tick()
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertTrue(unconfigured.sender.calls.isEmpty)
	}

	// MARK: §4 prefs

	func testPrefsValidation() throws {
		XCTAssertEqual(try NotificationPrefs.parse([:]), .defaults)
		let full = try NotificationPrefs.parse([
			"events": ["turn_done": false], "muted_agents": ["a", "a", "b"],
			"quiet_hours": ["start": 1320, "end": 420, "tz": "America/Denver", "allow_permission": false],
		])
		XCTAssertEqual(full.events["turn_done"], false)
		XCTAssertEqual(full.events["permission"], true)
		XCTAssertEqual(full.mutedAgents, ["a", "b"])
		XCTAssertEqual(full.quietHours?.allowPermission, false)
		XCTAssertEqual(try NotificationPrefs.parse(full.json), full)

		let bad: [[String: Any]] = [
			["surprise": true],
			["events": ["mac_unreachable": true]],
			["events": ["ask": 1]],
			["events": "all"],
			["muted_agents": Array(repeating: "x", count: 201).enumerated().map { "a\($0.offset)" }],
			["muted_agents": [""]],
			["muted_agents": [String(repeating: "x", count: 257)]],
			["muted_agents": [3]],
			["quiet_hours": ["start": 0, "end": 60, "tz": "Mars/Olympus"]],
			["quiet_hours": ["start": 0, "end": 1440, "tz": "UTC"]],
			["quiet_hours": ["start": -1, "end": 60, "tz": "UTC"]],
			["quiet_hours": ["start": true, "end": 60, "tz": "UTC"]],
			["quiet_hours": ["start": 0, "end": 60, "tz": "UTC", "later": 1]],
			["quiet_hours": ["start": 0, "end": 60]],
			["quiet_hours": "night"],
		]
		for body in bad {
			XCTAssertThrowsError(try NotificationPrefs.parse(body), "\(body)") { error in
				XCTAssertEqual((error as? APIError)?.status, 400)
			}
		}
		XCTAssertNoThrow(
			try NotificationPrefs.parse(["muted_agents": (0..<200).map { "a\($0)" }, "quiet_hours": NSNull()]))
	}

	func utc(_ hour: Int, _ minute: Int) -> Date {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		return calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
	}

	func testQuietHoursWrapMidnightInTheirTimeZone() {
		let night = NotificationPrefs.QuietHours(start: 22 * 60, end: 7 * 60, tz: "UTC", allowPermission: true)
		XCTAssertTrue(night.contains(utc(23, 0)))
		XCTAssertTrue(night.contains(utc(0, 30)))
		XCTAssertTrue(night.contains(utc(6, 59)))
		XCTAssertFalse(night.contains(utc(7, 0)))
		XCTAssertFalse(night.contains(utc(12, 0)))
		XCTAssertTrue(night.contains(utc(22, 0)))
		XCTAssertFalse(night.contains(utc(21, 59)))
		let day = NotificationPrefs.QuietHours(start: 9 * 60, end: 17 * 60, tz: "UTC", allowPermission: true)
		XCTAssertTrue(day.contains(utc(9, 0)))
		XCTAssertFalse(day.contains(utc(17, 0)))
		XCTAssertFalse(day.contains(utc(3, 0)))
		// 23:00 UTC is 17:00 in Denver (MDT, UTC-6 on 2026-10-28): outside 22:00-07:00 there.
		let denver = NotificationPrefs.QuietHours(start: 22 * 60, end: 7 * 60, tz: "America/Denver", allowPermission: true)
		XCTAssertFalse(denver.contains(utc(23, 0)))
		XCTAssertTrue(denver.contains(utc(5, 0)))
		XCTAssertFalse(NotificationPrefs.QuietHours(start: 60, end: 60, tz: "UTC", allowPermission: true).contains(utc(1, 0)))
	}

	func testPrefsFilterEventsMutesAndQuietHours() {
		let prefs = NotificationPrefs(
			events: ["subagents_done": false], mutedAgents: ["w1:p1"],
			quietHours: .init(start: 22 * 60, end: 7 * 60, tz: "UTC", allowPermission: true))
		let day = utc(12, 0)
		let night = utc(2, 0)
		XCTAssertTrue(prefs.allows("turn_done", agentID: "w1:p2", at: day))
		XCTAssertFalse(prefs.allows("subagents_done", agentID: "w1:p2", at: day))
		XCTAssertFalse(prefs.allows("turn_done", agentID: "w1:p1", at: day), "muted")
		XCTAssertTrue(prefs.allows("permission", agentID: "w1:p1", at: day), "a mute keeps dialogs")
		XCTAssertFalse(prefs.allows("turn_done", agentID: "w1:p2", at: night))
		XCTAssertTrue(prefs.allows("permission", agentID: "w1:p2", at: night))
		XCTAssertTrue(prefs.allows("ask", agentID: "w1:p2", at: night))
		var strict = prefs
		strict.quietHours?.allowPermission = false
		XCTAssertFalse(strict.allows("permission", agentID: "w1:p2", at: night))
		XCTAssertFalse(NotificationPrefs(events: ["ask": false]).allows("ask", agentID: nil, at: day))
	}

	func testTheStorePersistsPerDeviceAndTheNotifierHonoursIt() async throws {
		let path = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString).json").path
		defer { try? FileManager.default.removeItem(atPath: path) }
		let clock = TestClock(utc(2, 0))
		let store = NotificationPrefsStore(path: path, now: { clock.now })
		let quiet = NotificationPrefs(quietHours: .init(start: 22 * 60, end: 7 * 60, tz: "UTC", allowPermission: true))
		try store.set(quiet, for: phoneID)
		XCTAssertEqual(NotificationPrefsStore(path: path).prefs(phoneID), quiet)
		XCTAssertEqual(store.prefs("dev_other"), .defaults)
		XCTAssertFalse(store.allows(phoneID, "turn_done", agentID: agentID))
		XCTAssertTrue(store.allows(phoneID, "permission", agentID: agentID))

		let rig = try rig(prefs: store)
		XCTAssertTrue(rig.notifier.recipients("turn_done", agentID: agentID).isEmpty)
		clock.advance(10 * 3600)
		XCTAssertEqual(rig.notifier.recipients("turn_done", agentID: agentID).count, 1)
		try store.set(NotificationPrefs(mutedAgents: [agentID]), for: phoneID)
		XCTAssertTrue(rig.notifier.recipients("stopped", agentID: agentID).isEmpty)
		XCTAssertEqual(rig.notifier.recipients("stopped", agentID: "w9:p9").count, 1)
	}
}

/// The dialog trackers fill the §1 fields and consult the prefs filter.
final class ApprovalPushPrefsTests: XCTestCase {
	final class DevicesPush: PushNotifier, @unchecked Sendable {
		let lock = NSLock()
		var calls: [(ApprovalPush, [String])] = []
		var isConfigured: Bool { true }
		func notifyApproval(_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool)
			-> String
		{
			lock.lock()
			calls.append((push, devices.map(\.deviceID)))
			lock.unlock()
			return "sent"
		}
		func notifyResolved(requestID: String) {}
	}

	func testPermissionPushesCarryTheAgentAndSkipPhonesThatOptedOut() throws {
		let agent = AgentPermissionTests.FakeAgent()
		let push = DevicesPush()
		let a = PushRoutingTests.record("dev_aaaaaaaaaaaaaaaaaaaaaaaa", createdAt: 1)
		let b = PushRoutingTests.record("dev_bbbbbbbbbbbbbbbbbbbbbbbb", createdAt: 2)
		let tracker = PermissionTracker(
			reader: agent.reader, publish: { _, _ in }, push: push, devices: { [a, b] }, lastDevice: { nil },
			now: { 1000 })
		var asked: [(String, String, String)] = []
		tracker.pushFilter = { device, event, agentID in
			asked.append((device, event, agentID))
			return device == a.deviceID
		}
		let current = try tracker.current("w1:p1")
		let promptID = (current["permission"] as? [String: Any])?["prompt_id"] as? String
		let (message, devices) = try XCTUnwrap(push.calls.first)
		XCTAssertEqual(devices, [a.deviceID])
		XCTAssertEqual(message.agentID, "w1:p1")
		XCTAssertEqual(message.event, "permission")
		XCTAssertEqual(message.promptID, promptID)
		XCTAssertEqual(asked.map(\.1), ["permission", "permission"])
		XCTAssertEqual(asked.map(\.2), ["w1:p1", "w1:p1"])
	}
}

/// The relay sender's wire shape.
final class RelayEventSenderTests: XCTestCase {
	final class CapturingTransport: LinkTransport, @unchecked Sendable {
		let lock = NSLock()
		var requests: [URLRequest] = []
		func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
			lock.lock()
			requests.append(request)
			lock.unlock()
			let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (Data(#"{"push":"sent"}"#.utf8), response)
		}
		func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPURLResponse) {
			throw URLError(.unsupportedURL)
		}
	}

	func testPostsAgentEventsToNotify() async throws {
		let transport = CapturingTransport()
		let client = RelayClient(
			baseURL: URL(string: "http://127.0.0.1:9")!, deviceID: "dev_macmacmacmacmacmacmacmac",
			linkKey: SoftwareSigningKey(), transport: transport)
		let sender = RelayEventSender(client: client, transport: transport)
		let outcome = await sender.sendEvent(
			deviceID: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", kind: "agent.event", requestID: "evt_0123456789abcdef", sealed: "c2VhbGVk")
		XCTAssertEqual(outcome, "sent")
		let resolved = await sender.sendEvent(
			deviceID: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", kind: "agent.event.resolved", requestID: "evt_0123456789abcdef",
			sealed: nil)
		XCTAssertEqual(resolved, "sent")
		let request = try XCTUnwrap(transport.requests.first)
		XCTAssertEqual(request.httpMethod, "POST")
		XCTAssertEqual(request.url?.path, "/v1/notify")
		XCTAssertNotNil(request.value(forHTTPHeaderField: "X-WL-Signature") ?? request.value(forHTTPHeaderField: "X-WL-Device"))
		let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
		XCTAssertEqual(
			body,
			["device_id": "dev_aaaaaaaaaaaaaaaaaaaaaaaa", "kind": "agent.event", "request_id": "evt_0123456789abcdef",
				"sealed": "c2VhbGVk"])
		let second = try XCTUnwrap(
			try JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests.last?.httpBody)) as? [String: String])
		XCTAssertNil(second["sealed"])
		XCTAssertEqual(second["kind"], "agent.event.resolved")
	}

	func testSwitchablePushOnlySendsEventsOnAnAccount() async {
		let switchable = SwitchablePush()
		XCTAssertFalse(switchable.isEventConfigured)
		let outcome = await switchable.sendEvent(deviceID: "dev_x", kind: "agent.event", requestID: "evt_x", sealed: nil)
		XCTAssertEqual(outcome, "unconfigured")
		let fake = FakeEventSender()
		switchable.replace(with: RelayPush(notify: { _, _, _, _ in "sent" }, events: fake))
		XCTAssertTrue(switchable.isEventConfigured)
		_ = await switchable.sendEvent(deviceID: "dev_x", kind: "agent.event", requestID: "evt_x", sealed: "s")
		XCTAssertEqual(fake.calls.count, 1)
		switchable.replace(with: UnconfiguredPush())
		XCTAssertFalse(switchable.isEventConfigured)
	}
}

/// The prefs routes on a real helper.
final class NotificationPrefsRouteTests: XCTestCase {
	var helper: TestDaemon!

	override func setUpWithError() throws {
		helper = try TestDaemon(engine: FakeEngine())
	}

	override func tearDown() {
		helper.stop()
	}

	func testGetPutAndValidation() async throws {
		let phone = try await helper.pairedPhone()
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("notification_prefs"))

		let initial = try await phone.call("GET", "/v1/notifications/prefs")
		XCTAssertEqual(initial.status, 200)
		let defaults = try XCTUnwrap(initial.json["prefs"] as? [String: Any])
		XCTAssertEqual((defaults["events"] as? [String: Bool])?["turn_done"], true)
		XCTAssertTrue(defaults["quiet_hours"] is NSNull)

		let body: [String: Any] = [
			"events": ["permission": true, "ask": true, "turn_done": false, "subagents_done": true, "stopped": true],
			"muted_agents": ["w1:p3"],
			"quiet_hours": ["start": 1320, "end": 420, "tz": "America/Denver", "allow_permission": true],
		]
		let put = try await phone.call("PUT", "/v1/notifications/prefs", json: body)
		XCTAssertEqual(put.status, 200)
		let stored = try await phone.call("GET", "/v1/notifications/prefs")
		let prefs = try XCTUnwrap(stored.json["prefs"] as? [String: Any])
		XCTAssertEqual((prefs["events"] as? [String: Bool])?["turn_done"], false)
		XCTAssertEqual(prefs["muted_agents"] as? [String], ["w1:p3"])
		XCTAssertEqual((prefs["quiet_hours"] as? [String: Any])?["tz"] as? String, "America/Denver")

		let bad = try await phone.call("PUT", "/v1/notifications/prefs", json: ["events": ["nope": true]])
		XCTAssertEqual(bad.status, 400)
		let tz = try await phone.call(
			"PUT", "/v1/notifications/prefs", json: ["quiet_hours": ["start": 0, "end": 1, "tz": "Nowhere/Land"]])
		XCTAssertEqual(tz.status, 400)
		let after = try await phone.call("GET", "/v1/notifications/prefs")
		XCTAssertEqual((after.json["prefs"] as? [String: Any])?["muted_agents"] as? [String], ["w1:p3"], "a bad PUT keeps the old prefs")

		let unsigned = try await SoftPhone.send(
			URLRequest(url: helper.baseURL.appendingPathComponent("v1/notifications/prefs")))
		XCTAssertEqual(unsigned.status, 401)
	}
}
