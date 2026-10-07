import Foundation
import WhisperaLink

/// Wakes paired phones when an approval arrives. The helper never holds APNs credentials: it
/// asks the account backend's `POST /v1/notify` to push on its behalf (PROTOCOL §10 moved to
/// the backend). Results are best effort and never delay `approval.ack` (§8: ack within 2 s).
public protocol PushNotifier: Sendable {
	var isConfigured: Bool { get }
	/// Enqueues a push for every target, `preferDevice` first. Returns the §8 ack value:
	/// `sent` (enqueued), `unconfigured`, `no_token` or `failed`.
	func notifyApproval(requestID: String, expiresAt: Int, preferDevice: String?, devices: [DeviceRecord]) -> String
	func notifyResolved(requestID: String, devices: [DeviceRecord])
}

/// No backend configured yet (accounts arrive with step 11): every send is a no-op.
public struct UnconfiguredPush: PushNotifier {
	public init() {}
	public var isConfigured: Bool { false }
	public func notifyApproval(requestID: String, expiresAt: Int, preferDevice: String?, devices: [DeviceRecord])
		-> String
	{
		"unconfigured"
	}
	public func notifyResolved(requestID: String, devices: [DeviceRecord]) {}
}

/// Pushes through the account backend: one WL1-signed `POST /v1/notify {"device_id"}` per
/// target device, the preferred (last used) device first.
public final class RelayPush: PushNotifier, @unchecked Sendable {
	public typealias Notify = @Sendable (String) async throws -> String
	private let notify: Notify
	private let log: OpsLog
	private let queue = DispatchQueue(label: "link.push")
	static let sendCap: TimeInterval = 12

	public init(notify: @escaping Notify, log: OpsLog = .null) {
		self.notify = notify
		self.log = log
	}

	public convenience init(client: RelayClient, log: OpsLog = .null) {
		self.init(notify: { deviceID in try await client.notify(deviceID).push }, log: log)
	}

	public var isConfigured: Bool { true }

	static func ordered(_ devices: [DeviceRecord], preferDevice: String?) -> [DeviceRecord] {
		guard let preferDevice, let first = devices.firstIndex(where: { $0.deviceID == preferDevice }) else {
			return devices
		}
		var out = devices
		out.insert(out.remove(at: first), at: 0)
		return out
	}

	public func notifyApproval(requestID: String, expiresAt: Int, preferDevice: String?, devices: [DeviceRecord])
		-> String
	{
		let targets = Self.ordered(devices, preferDevice: preferDevice)
		guard !targets.isEmpty else { return "no_token" }
		let notify = self.notify
		let log = self.log
		queue.async {
			for device in targets {
				let semaphore = DispatchSemaphore(value: 0)
				let box = ResultBox()
				Task {
					do {
						box.value = try await notify(device.deviceID)
					} catch {
						box.value = "failed"
					}
					semaphore.signal()
				}
				let outcome =
					semaphore.wait(timeout: .now() + Self.sendCap) == .timedOut
					? "failed" : (box.value ?? "failed")
				log("push", ["device": device.deviceID, "request_id": requestID, "detail": "push=\(outcome)"])
			}
		}
		return "sent"
	}

	public func notifyResolved(requestID: String, devices: [DeviceRecord]) {}

	private final class ResultBox: @unchecked Sendable {
		var value: String?
	}
}

/// The notifier the daemon hands out, whose backend can change while it runs: unconfigured until
/// the Mac joins an account, then the relay (step 11), unconfigured again after sign-out.
public final class SwitchablePush: PushNotifier, @unchecked Sendable {
	private let lock = NSLock()
	private var inner: PushNotifier

	public init(_ inner: PushNotifier = UnconfiguredPush()) {
		self.inner = inner
	}

	public func replace(with notifier: PushNotifier) {
		lock.lock()
		inner = notifier
		lock.unlock()
	}

	private var current: PushNotifier {
		lock.lock()
		defer { lock.unlock() }
		return inner
	}

	public var isConfigured: Bool { current.isConfigured }

	public func notifyApproval(requestID: String, expiresAt: Int, preferDevice: String?, devices: [DeviceRecord])
		-> String
	{
		current.notifyApproval(requestID: requestID, expiresAt: expiresAt, preferDevice: preferDevice, devices: devices)
	}

	public func notifyResolved(requestID: String, devices: [DeviceRecord]) {
		current.notifyResolved(requestID: requestID, devices: devices)
	}
}
