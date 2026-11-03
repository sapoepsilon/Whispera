// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation
import Network

/// macOS's local-network gate, which sits between this app and every server the
/// user runs on their own LAN.
///
/// Since macOS 15 a connection to a private address needs an explicit grant, and
/// the way it fails without one is uniquely unhelpful: `URLSession` returns
/// `-1009` — the code that ordinarily means "this Mac is offline" — with
/// "Local network prohibited" buried in its description, and the system prompt
/// that would let the user grant it never appears unless the app asks for local
/// networking through an API that can raise one.
///
/// QA on 2026-08-23 walked into both halves: the first connection to a LAN
/// speaches failed, Whispera said "check that the server is running" (it was),
/// and no prompt was ever shown. What follows is the two fixes — recognising the
/// denial for what it is, and provoking the prompt at the moment the user
/// commits a LAN address rather than in the middle of their first dictation.
enum LocalNetworkAccess {
	/// Where the grant lives, phrased the way the pane is labelled.
	static let settingsPath = "System Settings > Privacy & Security > Local Network"

	/// Whether talking to this host needs the local-network grant.
	///
	/// Loopback does not — it never leaves the machine — so `localhost` and
	/// `127.0.0.1` answer `false` even though they are as local as an address
	/// gets. Everything RFC 1918, link-local, or `.local` does.
	static func needsLocalNetworkGrant(host: String) -> Bool {
		let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
		guard !host.isEmpty else { return false }
		if host == "localhost" || host == "127.0.0.1" || host == "::1" { return false }
		if host.hasSuffix(".local") { return true }

		let parts = host.split(separator: ".").map(String.init)
		guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]),
			parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
		else { return false }

		switch first {
		case 10: return true
		case 172: return (16...31).contains(second)
		case 192: return second == 168
		case 169: return second == 254
		default: return false
		}
	}

	static func needsLocalNetworkGrant(url: URL) -> Bool {
		url.host.map(needsLocalNetworkGrant(host:)) ?? false
	}

	/// Whether a transport failure is macOS refusing local-network access rather
	/// than the server being down.
	///
	/// Matched on the description rather than on the code, because the code is
	/// `-1009` either way — the same one a genuinely offline Mac reports — and
	/// only the description distinguishes them.
	static func readsAsDenial(_ description: String) -> Bool {
		description.lowercased().contains("local network")
	}

	/// The sentence to show instead of "check that the server is running".
	///
	/// `nil` when the failure has nothing to do with local networking, so the
	/// caller keeps its ordinary message.
	static func advice(forFailure description: String, destination: String) -> String? {
		let host = URL(string: destination)?.host ?? destination
		if readsAsDenial(description) {
			return
				"macOS blocked Whispera from reaching \(destination) on your local network. "
				+ "Allow it under \(settingsPath), then start dictation again."
		}
		guard needsLocalNetworkGrant(host: host) else { return nil }
		return
			"Whispera could not reach \(destination). Check that the server is running, and that "
			+ "Whispera is allowed under \(settingsPath) — a LAN server is unreachable without it."
	}

	static func openSettings() {
		guard
			let url = URL(
				string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
		else { return }
		NSWorkspace.shared.open(url)
	}
}

/// Provokes the local-network prompt on purpose, before the connection that
/// would otherwise fail silently.
///
/// `URLSession` does not raise the prompt — it just returns `-1009` — so the
/// touch goes through `NWConnection`, which does. The touch is a single TCP
/// connection to the exact host and port the user typed, cancelled the moment it
/// resolves either way: no browsing, no Bonjour scan, no sweep of the subnet.
/// The point is to ask the question at the moment the user has just told us
/// which machine they mean, which is the moment the prompt makes sense.
@MainActor
final class LocalNetworkPrimer {
	static let shared = LocalNetworkPrimer()

	/// One touch per endpoint per launch. The prompt is once-ever anyway; this
	/// keeps a debounced settings field from opening a connection per keystroke.
	private var touched: Set<String> = []
	private let touch: (String, UInt16) -> Void

	init(touch: @escaping (String, UInt16) -> Void = LocalNetworkPrimer.openAndDrop) {
		self.touch = touch
	}

	/// - Returns: whether a touch was actually made, which is what a test asserts
	///   on — a loopback or public address must not be touched at all, and a
	///   repeat of the same endpoint must not be touched twice.
	@discardableResult
	func prime(for url: URL?) -> Bool {
		guard let url, let host = url.host, LocalNetworkAccess.needsLocalNetworkGrant(host: host)
		else { return false }
		let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
		let key = "\(host):\(port)"
		guard !touched.contains(key) else { return false }
		touched.insert(key)
		AppLogger.shared.general.info(
			"Touching \(key) to raise the local network prompt before the first connection")
		touch(host, port)
		return true
	}

	private static func openAndDrop(host: String, port: UInt16) {
		guard let port = NWEndpoint.Port(rawValue: port) else { return }
		let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
		connection.stateUpdateHandler = { state in
			switch state {
			case .ready, .failed, .cancelled:
				connection.cancel()
			default:
				break
			}
		}
		connection.start(queue: .global(qos: .utility))
		// Cancelled regardless, so a host that neither answers nor refuses does not
		// leave a connection open for the life of the app.
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
			connection.cancel()
		}
	}
}
