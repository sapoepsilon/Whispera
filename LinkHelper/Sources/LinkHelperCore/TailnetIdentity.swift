import Foundation
import Security

/// A node of the owner's tailnet that may run another helper.
public struct TailnetPeer: Equatable, Sendable {
	/// Its Tailscale IPv4 address (what a probe connects to).
	public var address: String
	/// The helper port to probe; nil = this helper's own configured port.
	public var port: Int?

	public init(address: String, port: Int? = nil) {
		self.address = address
		self.port = port
	}
}

/// What `tailscale whois` says about the node behind one address.
public struct TailnetNode: Equatable, Sendable {
	/// Tailscale's stable node id (`nXXXX…CNTRL`): one listed Mac is bound to one node.
	public var id: String
	/// Its MagicDNS name's first label (`mac-b`): what the owner is shown.
	public var name: String
	/// Self-reported by the node.
	public var os: String

	public init(id: String, name: String, os: String = "macOS") {
		self.id = id
		self.name = name
		self.os = os
	}
}

/// Who is on the owner's tailnet.
///
/// This is not a trust root. Every untagged node of the owner's Tailscale user passes these
/// checks, including servers and agent containers (the account backend itself may be one).
/// It only lets the helper show a Mac's tailnet name in the "Link this Mac?" prompt and skip the
/// safety number; the owner's approval is what grants trust.
public protocol TailnetIdentity: Sendable {
	/// Untagged, unshared, online nodes of this node's own user that report macOS: where other
	/// helpers may listen. Empty (and nothing cached) when the CLI fails.
	func ownerMacs() async -> [TailnetPeer]
	/// `tailscale whois` of `address` (`ip` or `ip:port`), now: its node when it is an online,
	/// untagged, unshared macOS node of this node's own user, else nil. Blocks up to a few seconds.
	func whois(_ address: String) -> TailnetNode?
	/// This node's own stable id, when known (a probe never links this Mac to itself).
	var selfNodeID: String? { get }
	/// Whether a probe may dial `address`: a Tailscale IP literal unless a test stands loopback in.
	func isProbeAddress(_ address: String) -> Bool
	/// This Mac's MagicDNS name, asked now (may block on the CLI); nil when unknown.
	func selfDNSName() -> String?
}

extension TailnetIdentity {
	public func isProbeAddress(_ address: String) -> Bool { PeerHTTP.isTailnetAddress(address) }
	/// This Mac's MagicDNS name (`mac-a.example.ts.net`), asked now; nil when unknown.
	public func selfDNSName() -> String? { nil }
}

/// The Tailscale CLI (`status --json`, `whois --json`).
public final class TailscaleCLIIdentity: TailnetIdentity, @unchecked Sendable {
	static let candidates = [
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
		"/usr/local/bin/tailscale",
	]

	let executable: String
	private let lock = NSLock()
	private var selfUser: String?
	private var selfNode: String?

	public var selfNodeID: String? { lock.withLock { selfNode } }

	static let appCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	/// Tailscale Inc's Developer ID / App Store team.
	static let tailscaleTeam = "W5364U7YZB"

	/// Release builds: only `/Applications/Tailscale.app`, and only while its code signature is
	/// valid and Tailscale's (`tailscaleTeam`), so nothing on PATH or in a config can stand in
	/// for `whois`. Debug builds: `configured` (an absolute path, or a bare name looked up in the
	/// usual places). Nil when there is none; empty turns tailnet linking off.
	public init?(configured: String) {
		let value = configured.trimmingCharacters(in: .whitespaces)
		guard !value.isEmpty else { return nil }
		#if DEBUG
			if value.hasPrefix("/") {
				guard FileManager.default.isExecutableFile(atPath: value) else { return nil }
				executable = value
			} else if let found = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
				executable = found
			} else {
				return nil
			}
		#else
			guard Self.isSignedByTailscale(Self.appCLI) else { return nil }
			executable = Self.appCLI
		#endif
	}

	/// The bundle around `executable` has a valid signature anchored at Apple with Tailscale's
	/// team as the leaf's OU.
	static func isSignedByTailscale(_ executable: String) -> Bool {
		let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent()
		guard bundle.pathExtension == "app" else { return false }
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
		var requirement: SecRequirement?
		let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(tailscaleTeam)\""
		guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
		else { return false }
		return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
			== errSecSuccess
	}

	public func ownerMacs() async -> [TailnetPeer] {
		let executable = self.executable
		let data = await Task.detached { Self.run(executable, ["status", "--json"]) }.value
		guard let data, let status = Self.parseStatus(data) else {
			lock.withLock {
				selfUser = nil
				selfNode = nil
			}
			return []
		}
		lock.withLock {
			selfUser = status.selfUser
			selfNode = status.selfNode
		}
		return status.macs
	}

	public func selfDNSName() -> String? {
		guard let data = Self.run(executable, ["status", "--json"]) else { return nil }
		return Self.parseSelfDNSName(data)
	}

	/// `Self.DNSName` without its trailing dot, when it is a MagicDNS name.
	static func parseSelfDNSName(_ data: Data) -> String? {
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let me = root["Self"] as? [String: Any], var name = (me["DNSName"] as? String)?.lowercased()
		else { return nil }
		while name.hasSuffix(".") { name.removeLast() }
		guard name.hasSuffix(".ts.net"), name.count > ".ts.net".count,
			name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
		else { return nil }
		return name
	}

	public func whois(_ address: String) -> TailnetNode? {
		var user = lock.withLock { selfUser }
		if user == nil, let data = Self.run(executable, ["status", "--json"]), let status = Self.parseStatus(data) {
			user = status.selfUser
			lock.withLock {
				selfUser = status.selfUser
				selfNode = status.selfNode
			}
		}
		guard let user, let data = Self.run(executable, ["whois", "--json", address]) else {
			lock.withLock { selfUser = nil }
			return nil
		}
		return Self.parseWhois(data, selfUser: user)
	}

	struct Status: Equatable {
		var selfUser: String
		var selfNode: String?
		var macs: [TailnetPeer]
	}

	static func parseStatus(_ data: Data) -> Status? {
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let me = root["Self"] as? [String: Any], let myUser = userID(me["UserID"]), !isTagged(me)
		else { return nil }
		var macs: [TailnetPeer] = []
		for case let peer as [String: Any] in ((root["Peer"] as? [String: Any]) ?? [:]).values {
			guard userID(peer["UserID"]) == myUser, peer["Online"] as? Bool == true, !isTagged(peer),
				peer["ShareeNode"] as? Bool != true, (peer["OS"] as? String)?.lowercased() == "macos",
				let v4 = ((peer["TailscaleIPs"] as? [String]) ?? []).first(where: { OfferAddresses.isTailscale($0) })
			else { continue }
			macs.append(TailnetPeer(address: v4))
		}
		macs.sort { $0.address < $1.address }
		return Status(selfUser: myUser, selfNode: me["ID"] as? String, macs: macs)
	}

	/// The node in a `whois --json` answer, when it is the owner's Mac: same `User` as this node,
	/// no `Sharer` (shared in from another tailnet), no tags, not reported offline, macOS.
	static func parseWhois(_ data: Data, selfUser: String) -> TailnetNode? {
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let node = root["Node"] as? [String: Any], userID(node["User"]) == selfUser,
			userID(node["Sharer"]) == nil || userID(node["Sharer"]) == "0", !isTagged(node),
			node["Online"] as? Bool != false, let stable = node["StableID"] as? String, !stable.isEmpty
		else { return nil }
		let full = (node["Name"] as? String) ?? ""
		let label = full.split(separator: ".").first.map(String.init) ?? ""
		let name = label.isEmpty ? ((node["ComputedName"] as? String) ?? "") : label
		guard !name.isEmpty else { return nil }
		let os = ((node["Hostinfo"] as? [String: Any])?["OS"] as? String) ?? ""
		guard os.lowercased() == "macos" else { return nil }
		return TailnetNode(id: stable, name: DeviceRegistry.sanitizedName(name), os: os)
	}

	private static func isTagged(_ node: [String: Any]) -> Bool {
		!((node["Tags"] as? [Any])?.isEmpty ?? true)
	}

	private static func userID(_ value: Any?) -> String? {
		if let number = value as? NSNumber { return number.stringValue }
		if let text = value as? String, !text.isEmpty { return text }
		return nil
	}

	/// Runs the CLI with a 5 s limit; nil on failure.
	static func run(_ executable: String, _ arguments: [String]) -> Data? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		// Tailscale.app's binary acts as the CLI only when TERM is set. A launchd job has none, and
		// then it tries to start the GUI instead, printing that to stdout with status 0.
		var environment = ProcessInfo.processInfo.environment
		if (environment["TERM"] ?? "").isEmpty { environment["TERM"] = "dumb" }
		process.environment = environment
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return nil }
		let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
		DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		watchdog.cancel()
		return process.terminationStatus == 0 ? data : nil
	}
}
