import Combine
import Foundation

/// Proves the owner is present and signs with the Mac's approve key. The app's is
/// `MacApproveKey` (Touch ID, passcode fallback); tests inject a software key.
public protocol ApprovalAuthenticator: AnyObject, Sendable {
	/// DER signature over `message`. Throws `ApprovalAuthenticationError` when the owner did not confirm.
	func sign(_ message: Data, reason: String) async throws -> Data
	/// Dismisses a prompt still on screen; the pending `sign` then throws.
	func cancel()
}

public enum ApprovalAuthenticationError: Error, Equatable {
	case cancelled
	case failed(String)
	case noKey
}

/// The card's line to the helper: XPC in the app, the daemon itself in tests.
public protocol ApprovalHelperLink: AnyObject, Sendable {
	/// `GET /v1/approvals/{id}`'s body, or nil when the helper does not answer.
	func approval(_ requestID: String) async -> Data?
	/// The decision reply, or nil when the helper does not answer.
	func decide(_ requestID: String, decision: String, signature: String?) async -> Data?
}

/// One open approval card: feeds the state machine and runs its effects.
@MainActor
public final class ApprovalCardSession: ObservableObject, Identifiable {
	@Published public private(set) var state: ApprovalCardState
	@Published public private(set) var now: Int
	public nonisolated let id: String
	/// Called once, when the card should go away.
	public var onClose: (() -> Void)?

	private let link: ApprovalHelperLink
	private let authenticator: ApprovalAuthenticator
	private let clock: () -> Int
	private var timer: Timer?
	private var closeScheduled = false

	public init(
		request: ApprovalRequest, link: ApprovalHelperLink, authenticator: ApprovalAuthenticator,
		clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }
	) {
		id = request.requestID
		state = ApprovalCardState(request: request)
		self.link = link
		self.authenticator = authenticator
		self.clock = clock
		now = clock()
	}

	public var request: ApprovalRequest { state.request }

	/// Ticks the countdown once a second until the card finishes.
	public func startTimer() {
		timer?.invalidate()
		timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.send(.tick) }
		}
	}

	public func approve() { send(.approveTapped) }

	public func deny() { send(.denyTapped) }

	/// Re-reads the approval from the helper (on `approvalsChanged`) so a phone or Touch ID
	/// answer elsewhere closes the card.
	public func refresh() async {
		guard !state.isFinished else { return }
		guard let data = await link.approval(state.request.requestID),
			let view = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else { return }
		if let error = view["error"] as? [String: Any] {
			if error["code"] as? String == "not_found" { send(.remote(status: "cancelled", decidedBy: nil, reason: nil)) }
			return
		}
		guard let status = view["status"] as? String else { return }
		send(.remote(status: status, decidedBy: view["decided_by"] as? String, reason: view["reason"] as? String))
	}

	public func send(_ event: ApprovalCardState.Event) {
		now = clock()
		let effects = state.handle(event, now: now)
		for effect in effects { run(effect) }
	}

	private func run(_ effect: ApprovalCardState.Effect) {
		switch effect {
		case .authenticate(let decision, let message, let reason):
			let authenticator = self.authenticator
			Task { @MainActor in
				do {
					let signature = try await authenticator.sign(message, reason: reason)
					self.send(.authenticated(decision, signature: signature.base64EncodedString()))
				} catch ApprovalAuthenticationError.cancelled {
					self.send(.authenticationFailed(decision, .authenticationCancelled))
				} catch ApprovalAuthenticationError.noKey {
					self.send(.authenticationFailed(decision, .noKey))
				} catch ApprovalAuthenticationError.failed(let message) {
					self.send(.authenticationFailed(decision, .authenticationFailed(message)))
				} catch {
					self.send(.authenticationFailed(decision, .authenticationFailed(error.localizedDescription)))
				}
			}
		case .cancelAuthentication:
			authenticator.cancel()
		case .submit(let decision, let signature):
			let link = self.link
			let requestID = state.request.requestID
			Task { @MainActor in
				let reply = await link.decide(requestID, decision: decision.rawValue, signature: signature)
				self.send(.answered(DecisionAnswer(json: reply)))
			}
		case .close(let delay):
			timer?.invalidate()
			timer = nil
			guard !closeScheduled else { return }
			closeScheduled = true
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				self.onClose?()
				self.onClose = nil
			}
		}
	}
}
