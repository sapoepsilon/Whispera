// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import LinkHelperXPC
import SwiftUI

/// The Mac approval card (whispera-link PROTOCOL §8.1): when the bws-touchid broker asks the link
/// helper for an approval, Whispera shows who is asking for which secret and answers with Touch ID.
/// The helper launches Whispera for it when it is not running.
@MainActor
final class ApprovalCardCenter: ObservableObject {
	static let shared = ApprovalCardCenter()

	struct Enrollment: Equatable {
		var deviceID: String
		var displayFingerprint: String
		var pemPath: String

		var pinCommand: String { "bws-touchid approver add \(deviceID) \(pemPath)" }
	}

	@Published private(set) var enrollment: Enrollment?
	@Published var lastError: String?

	let key = MacApproveKey()
	private var connection: NSXPCConnection?
	private var link: XPCApprovalLink?
	private var current: ApprovalCardSession?
	private var panel: ApprovalCardPanel?
	private var settled: Set<String> = []
	private var reconnect: Task<Void, Never>?
	private var running = false

	/// Watches the helper while the Mac link is on and this Mac has an approval key.
	func start() {
		running = true
		guard connection == nil, key.identity != nil else { return }
		connect()
	}

	func stop() {
		running = false
		reconnect?.cancel()
		connection?.invalidate()
		connection = nil
		link = nil
		closeCard()
	}

	private func connect() {
		let connection = NSXPCConnection(machServiceName: MacLinkHelper.helperBundleIdentifier, options: [])
		connection.remoteObjectInterface = NSXPCInterface(with: LinkHelperXPCProtocol.self)
		connection.exportedInterface = NSXPCInterface(with: LinkHelperAppXPCProtocol.self)
		connection.exportedObject = ApprovalCallbacks { [weak self] in
			Task { @MainActor in await self?.refresh() }
		}
		if MacLinkHelper.isDeveloperIDSigned {
			connection.setCodeSigningRequirement(LinkHelperXPC.helperRequirement)
		}
		connection.invalidationHandler = { [weak self, weak connection] in
			Task { @MainActor in self?.connectionLost(connection) }
		}
		connection.interruptionHandler = { [weak self, weak connection] in
			Task { @MainActor in self?.connectionLost(connection) }
		}
		connection.resume()
		self.connection = connection
		let link = XPCApprovalLink(connection: connection)
		self.link = link
		Task {
			guard await link.watch() != nil else {
				AppLogger.shared.general.error("Approval card: the Mac link helper did not answer")
				self.connectionLost(connection)
				return
			}
			AppLogger.shared.general.info("Approval card: watching the Mac link for approvals")
			await refresh()
		}
	}

	private func connectionLost(_ lost: NSXPCConnection?) {
		guard let lost, lost === connection else { return }
		lost.invalidate()
		connection = nil
		link = nil
		guard running else { return }
		reconnect?.cancel()
		reconnect = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			guard !Task.isCancelled, self.running, self.connection == nil else { return }
			self.connect()
		}
	}

	/// On every change the helper reports: refresh the open card, or open one for the oldest
	/// pending request.
	func refresh() async {
		guard let link else { return }
		if let current {
			await current.refresh()
			return
		}
		guard let data = await link.pending(),
			let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let approvals = object["approvals"] as? [[String: Any]]
		else { return }
		for item in approvals {
			guard let id = item["request_id"] as? String, !settled.contains(id), current == nil else { continue }
			guard let viewData = await link.approval(id),
				let view = (try? JSONSerialization.jsonObject(with: viewData)) as? [String: Any]
			else { continue }
			do {
				show(try ApprovalRequest(view: view, requestID: id), link: link, authenticator: key)
			} catch {
				settled.insert(id)
				AppLogger.shared.general.error("Approval card: refusing \(id): \(String(describing: error))")
			}
			return
		}
	}

	func show(
		_ request: ApprovalRequest, link: ApprovalHelperLink, authenticator: ApprovalAuthenticator,
		screen: NSScreen? = nil
	) {
		let session = ApprovalCardSession(request: request, link: link, authenticator: authenticator)
		session.onClose = { [weak self] in
			self?.settled.insert(request.requestID)
			self?.closeCard()
			Task { @MainActor in await self?.refresh() }
		}
		session.startTimer()
		current = session
		let panel = ApprovalCardPanel(session: session)
		self.panel = panel
		panel.present(on: screen)
		AppLogger.shared.general.info("Approval card shown for \(request.requestID) (op \(request.op))")
	}

	private func closeCard() {
		current = nil
		panel?.orderOut(nil)
		panel = nil
	}

	// MARK: Enrollment

	func loadEnrollment() async {
		guard let identity = key.identity else {
			enrollment = nil
			return
		}
		let link = XPCApprovalLink.oneShot()
		defer { link.invalidate() }
		enrollment = Self.enrollment(from: await link.macApprover(), deviceID: identity.deviceID)
	}

	/// Creates this Mac's approve key and hands its public half to the helper.
	func enroll() async {
		do {
			let identity = try key.enroll()
			let link = XPCApprovalLink.oneShot()
			defer { link.invalidate() }
			let name = Host.current().localizedName ?? "Mac"
			let reply = await link.enrollMacApprover(MacApproveKey.enrollment(identity, name: name))
			guard let enrollment = Self.enrollment(from: reply, deviceID: identity.deviceID) else {
				key.remove()
				throw EnrollmentError.helperRefused
			}
			self.enrollment = enrollment
			AppLogger.shared.general.info("Approval card: this Mac approves as \(identity.deviceID)")
			if MacLinkHelper.shared.isEnabled { start() }
		} catch {
			lastError = (error as? EnrollmentError)?.message ?? error.localizedDescription
		}
	}

	func removeEnrollment() async {
		let link = XPCApprovalLink.oneShot()
		defer { link.invalidate() }
		_ = await link.enrollMacApprover(Data("{}".utf8))
		key.remove()
		enrollment = nil
		stop()
		AppLogger.shared.general.info("Approval card: this Mac's approval key was removed")
	}

	private static func enrollment(from reply: Data?, deviceID: String) -> Enrollment? {
		guard let reply, let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
			let approver = object["mac_approver"] as? [String: Any], approver["device_id"] as? String == deviceID
		else { return nil }
		return Enrollment(
			deviceID: deviceID, displayFingerprint: approver["display_fp"] as? String ?? "",
			pemPath: object["pem_path"] as? String ?? "")
	}

	enum EnrollmentError: Error {
		case helperRefused

		var message: String {
			String(localized: "The Mac link isn't running. Turn it on above, then try again.")
		}
	}
}

/// The object the helper calls back on.
final class ApprovalCallbacks: NSObject, LinkHelperAppXPCProtocol, @unchecked Sendable {
	private let changed: () -> Void

	init(_ changed: @escaping () -> Void) {
		self.changed = changed
	}

	func approvalsChanged() { changed() }
}

/// `ApprovalHelperLink` over the helper's Mach service.
final class XPCApprovalLink: ApprovalHelperLink, @unchecked Sendable {
	private let connection: NSXPCConnection

	init(connection: NSXPCConnection) {
		self.connection = connection
	}

	/// A connection for one call from Settings.
	@MainActor static func oneShot() -> XPCApprovalLink {
		let connection = NSXPCConnection(machServiceName: MacLinkHelper.helperBundleIdentifier, options: [])
		connection.remoteObjectInterface = NSXPCInterface(with: LinkHelperXPCProtocol.self)
		if MacLinkHelper.isDeveloperIDSigned {
			connection.setCodeSigningRequirement(LinkHelperXPC.helperRequirement)
		}
		connection.resume()
		return XPCApprovalLink(connection: connection)
	}

	func invalidate() { connection.invalidate() }

	private func call(
		timeout: TimeInterval, _ body: @escaping (LinkHelperXPCProtocol, @escaping (Data) -> Void) -> Void
	) async -> Data? {
		await withCheckedContinuation { continuation in
			let once = Once(continuation)
			let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? LinkHelperXPCProtocol
			guard let proxy else { return once.resume(nil) }
			body(proxy) { once.resume($0) }
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
		}
	}

	func watch() async -> Data? { await call(timeout: 3) { $0.watchApprovals(reply: $1) } }

	func pending() async -> Data? { await call(timeout: 3) { $0.pendingApprovals(reply: $1) } }

	func approval(_ requestID: String) async -> Data? {
		await call(timeout: 3) { $0.approval(requestID, reply: $1) }
	}

	func decide(_ requestID: String, decision: String, signature: String?) async -> Data? {
		await call(timeout: 10) { $0.decide(requestID, decision: decision, signature: signature, reply: $1) }
	}

	func macApprover() async -> Data? { await call(timeout: 3) { $0.macApprover(reply: $1) } }

	func enrollMacApprover(_ request: Data) async -> Data? {
		await call(timeout: 3) { $0.enrollMacApprover(request, reply: $1) }
	}

	private final class Once: @unchecked Sendable {
		private let lock = NSLock()
		private var continuation: CheckedContinuation<Data?, Never>?

		init(_ continuation: CheckedContinuation<Data?, Never>) {
			self.continuation = continuation
		}

		func resume(_ value: Data?) {
			lock.lock()
			let pending = continuation
			continuation = nil
			lock.unlock()
			pending?.resume(returning: value)
		}
	}
}

// MARK: Panel

/// A floating card in the top-right corner. It never activates Whispera, so whatever the owner
/// is typing in keeps the keyboard; clicking a button works without a focus change.
final class ApprovalCardPanel: NSPanel {
	init(session: ApprovalCardSession) {
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
			styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
		titleVisibility = .hidden
		titlebarAppearsTransparent = true
		titlebarSeparatorStyle = .none
		isMovableByWindowBackground = true
		isFloatingPanel = true
		level = .floating
		hidesOnDeactivate = false
		becomesKeyOnlyIfNeeded = true
		isReleasedWhenClosed = false
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			standardWindowButton(button)?.isHidden = true
		}
		let hosting = NSHostingView(rootView: ApprovalCardView(session: session))
		hosting.safeAreaRegions = []
		contentView = hosting
		setContentSize(hosting.fittingSize)
		setAccessibilityIdentifier("approval-card")
	}

	/// Top-right of the screen the owner is working on, below where notification banners land:
	/// the broker posts one for the same request, and it must not cover the buttons.
	func present(on preferred: NSScreen? = nil) {
		let screen = preferred ?? NSScreen.main ?? NSScreen.screens.first
		if let visible = screen?.visibleFrame {
			setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 112))
		}
		orderFrontRegardless()
	}
}

struct ApprovalCardView: View {
	@ObservedObject var session: ApprovalCardSession

	private var request: ApprovalRequest { session.request }
	private var state: ApprovalCardState { session.state }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Label {
					Text("Approve secret access?").font(.headline)
				} icon: {
					Image(systemName: "lock.shield").foregroundColor(.accentColor)
				}
				Spacer()
				if !state.isFinished {
					Text(String(format: String(localized: "%@ left"), clock))
						.font(.caption.monospacedDigit())
						.foregroundColor(state.secondsLeft(now: session.now) <= 30 ? .orange : .secondary)
				}
			}
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
				row("Agent", request.caller)
				row("Mac", request.host)
				row("Secret", request.secret)
				if !request.project.isEmpty { row("Project", request.project) }
			}
			.font(.callout)
			footer
		}
		.padding(16)
		.frame(width: 380)
	}

	private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
		GridRow {
			Text(label).foregroundColor(.secondary)
			Text(value.isEmpty ? "—" : value)
				.lineLimit(2)
				.truncationMode(.middle)
				.textSelection(.enabled)
		}
	}

	@ViewBuilder private var footer: some View {
		switch state.phase {
		case .finished(let outcome):
			Text(outcomeText(outcome))
				.font(.callout.weight(.medium))
				.foregroundColor(outcomeIsApproval(outcome) ? .green : .secondary)
		default:
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Button("Deny") { session.deny() }
						.buttonStyle(ApprovalCardButtonStyle(prominent: false))
						.disabled(!canDeny)
					Spacer()
					if case .submitting = state.phase {
						ProgressView().controlSize(.small)
					}
					Button {
						session.approve()
					} label: {
						Label("Approve with Touch ID", systemImage: "touchid")
							.labelStyle(.titleAndIcon)
					}
					.buttonStyle(ApprovalCardButtonStyle(prominent: true))
					.disabled(!state.canApprove(now: session.now))
				}
				if let notice = state.notice {
					Text(noticeText(notice)).font(.caption).foregroundColor(.secondary)
				}
			}
		}
	}

	/// Deny is signed too, so it stays available while the approve prompt is up (it replaces it)
	/// but not while its own prompt is.
	private var canDeny: Bool {
		switch state.phase {
		case .pending, .authenticating(.approve): return true
		default: return false
		}
	}

	private var clock: String {
		let left = state.secondsLeft(now: session.now)
		return String(format: "%d:%02d", left / 60, left % 60)
	}

	private func noticeText(_ notice: ApprovalCardState.Notice) -> String {
		switch notice {
		case .tooLate: return String(localized: "Too late to approve here.")
		case .authenticationCancelled: return String(localized: "Touch ID was cancelled. Nothing was sent.")
		case .noKey: return String(localized: "This Mac's approval key is missing. Set it up again in Settings.")
		case .authenticationFailed(let message): return message
		}
	}

	private func outcomeIsApproval(_ outcome: ApprovalCardState.Outcome) -> Bool {
		switch outcome {
		case .approved, .approvedElsewhere: return true
		default: return false
		}
	}

	private func outcomeText(_ outcome: ApprovalCardState.Outcome) -> String {
		switch outcome {
		case .approved: return String(localized: "Approved.")
		case .denied: return String(localized: "Denied.")
		case .approvedElsewhere(let by):
			return by == "touchid"
				? String(localized: "Approved with Touch ID.") : String(localized: "Approved on your iPhone.")
		case .deniedElsewhere(let by):
			return by == "touchid"
				? String(localized: "Denied with Touch ID.") : String(localized: "Denied on your iPhone.")
		case .rejected(let reason):
			return String(format: String(localized: "The broker refused this approval (%@)."), reason)
		case .cancelled: return String(localized: "The request was withdrawn.")
		case .expired: return String(localized: "The request expired.")
		case .failed: return String(localized: "Couldn't finish here. Approve with Touch ID or on your iPhone.")
		}
	}
}

/// The card's buttons draw their own fill and label colours. The panel never becomes the key
/// window (it must not take the keyboard from whatever the owner is typing in), and in a window
/// that isn't key macOS draws `.borderedProminent` with its inactive, translucent white bezel
/// while the label stays white: in light mode Approve showed as an empty light rectangle and only
/// Deny was readable.
/// These colours don't depend on the window's key state, in light and dark mode.
struct ApprovalCardButtonStyle: ButtonStyle {
	var prominent: Bool

	func makeBody(configuration: Configuration) -> some View {
		StyledButton(configuration: configuration, prominent: prominent)
	}

	private struct StyledButton: View {
		let configuration: ButtonStyleConfiguration
		let prominent: Bool
		@Environment(\.isEnabled) private var isEnabled

		var body: some View {
			let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
			configuration.label
				.font(.body.weight(prominent ? .semibold : .regular))
				.foregroundStyle(prominent ? Color.white : Color.primary)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				.background(shape.fill(fill))
				.overlay(shape.strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12)))
				.contentShape(shape)
				.opacity(isEnabled ? 1 : 0.45)
		}

		private var fill: Color {
			// The owner's system accent colour, whatever the window's state.
			if prominent {
				return Color(nsColor: .controlAccentColor).opacity(configuration.isPressed ? 0.75 : 1)
			}
			return Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)
		}
	}
}

// MARK: Settings

/// Settings ▸ Servers ▸ Mac Link: the approval card's key and the one command that pins it.
struct MacApproverSettingsRow: View {
	@ObservedObject private var center = ApprovalCardCenter.shared
	@State private var busy = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let enrollment = center.enrollment {
				Text(
					String(
						format: String(localized: "This Mac approves as %@ · key %@"), enrollment.deviceID,
						enrollment.displayFingerprint)
				)
				.font(.caption.monospaced())
				.textSelection(.enabled)
				Text("Pin it once in Terminal; bws-touchid asks for Touch ID and the last 4 characters of the key.")
					.font(.caption)
					.foregroundColor(.secondary)
				HStack {
					Text(enrollment.pinCommand)
						.font(.caption.monospaced())
						.lineLimit(1)
						.truncationMode(.middle)
						.textSelection(.enabled)
					Button("Copy Command") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(enrollment.pinCommand, forType: .string)
					}
					Button("Remove") { run { await center.removeEnrollment() } }
				}
			} else {
				Button("Approve Secret Requests on This Mac…") { run { await center.enroll() } }
					.disabled(busy || !MacApproveKey.isAvailable)
				Text("Shows a card with Touch ID when an agent asks the broker for a secret.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.task { await center.loadEnrollment() }
		.alert(
			"Couldn't set up approvals on this Mac",
			isPresented: Binding(get: { center.lastError != nil }, set: { if !$0 { center.lastError = nil } }),
			presenting: center.lastError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private func run(_ work: @escaping @MainActor () async -> Void) {
		busy = true
		Task { @MainActor in
			await work()
			busy = false
		}
	}
}

#if DEBUG
	/// `--approval-card-demo`: the card with a made-up request, for screenshots. Nothing reaches
	/// the helper or the broker.
	extension ApprovalCardCenter {
		func showDemoIfRequested(arguments: [String] = CommandLine.arguments) {
			guard arguments.contains("--approval-card-demo") else { return }
			let now = Int(Date().timeIntervalSince1970)
			let canonical: [String: Any] = [
				"v": 1, "request_id": "apr_demodemodemodemodemodemo", "nonce": "ZGVtb2RlbW9kZW1vZGVtbw",
				"op": "save", "key": "DEMO_API_KEY", "summary": "save DEMO_API_KEY → demo-project",
				"project": "demo-project", "token": "write", "host": "build-box", "caller": "hermes agent",
				"via": "ssh session to build-box", "broker": "this Mac", "created_at": now - 13,
				"expires_at": now + 287,
			]
			guard let data = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]),
				let request = try? ApprovalRequest(
					canonicalB64: data.base64EncodedString(), requestID: "apr_demodemodemodemodemodemo")
			else { return }
			show(request, link: DemoLink(), authenticator: DemoAuthenticator(), screen: NSScreen.screens.first)
		}
	}

	private final class DemoLink: ApprovalHelperLink, @unchecked Sendable {
		func approval(_ requestID: String) async -> Data? { Data(#"{"status":"pending"}"#.utf8) }

		func decide(_ requestID: String, decision: String, signature: String?) async -> Data? {
			Data(#"{"status":"\#(decision == "approve" ? "approved" : "denied")","broker_outcome":"accepted"}"#.utf8)
		}
	}

	private final class DemoAuthenticator: ApprovalAuthenticator, @unchecked Sendable {
		func sign(_ message: Data, reason: String) async throws -> Data { Data([0x30]) }

		func cancel() {}
	}
#endif
