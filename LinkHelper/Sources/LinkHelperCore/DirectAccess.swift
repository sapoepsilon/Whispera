import Darwin
import Foundation

/// Who may open a direct (not relayed) connection to the helper.
///
/// The direct path is plain HTTP, and the terminal WebSocket signs only its upgrade, so the
/// helper accepts it only where the network itself encrypts and authenticates the peer: loopback
/// and the owner's Tailscale tailnet (WireGuard). Any other peer is closed at accept, before a
/// byte is parsed, unless the owner turned on "Allow unencrypted local network connections";
/// even then only private (local network) addresses get in, and never to the terminal
/// WebSocket. A phone off the tailnet uses the relay, which seals every message to this Mac.
///
/// A peer address in 100.64.0.0/10 proves nothing on its own: that is also carrier-grade NAT
/// space on hotel and mobile networks, and anyone on the LAN can send from it. A connection is
/// tailnet only when it arrived on one of this Mac's own Tailscale addresses (an address on a
/// `utun` interface), which WireGuard only delivers from authenticated tailnet peers.
///
/// Loopback is trusted as the Mac itself. Anything that forwards a port to it (`tailscale
/// serve`/`funnel`, `ssh -L`) therefore reaches the helper as loopback; what it exposes is still
/// only the signature-protected routes plus health and code pairing, which needs a code shown on
/// this Mac.
public enum DirectAccessPolicy {
	/// Whispera's setting, in the app's preferences domain; off unless the owner turns it on.
	public static let allowLANKey = "whisperaLinkAllowUnencryptedLAN"

	public enum Kind: Equatable, Sendable {
		case loopback
		/// For an address: inside a Tailscale range. For a connection: one that arrived on this
		/// Mac's own Tailscale address from a peer in those ranges.
		case tailnet
		/// RFC 1918, link-local and IPv6 unique-local addresses: the plain local network.
		case localNetwork
		/// A public address, a name, a spoofable tailnet-range peer, or something that does not parse.
		case other
	}

	public struct InterfaceAddress: Equatable, Sendable {
		public var name: String
		public var ip: String

		public init(name: String, ip: String) {
			self.name = name
			self.ip = ip
		}
	}

	public static func admits(_ kind: Kind, allowLAN: Bool) -> Bool {
		switch kind {
		case .loopback, .tailnet: return true
		case .localNetwork: return allowLAN
		case .other: return false
		}
	}

	/// What a connection is, from its peer address, the local address and the interface it arrived
	/// on (nil when the stack did not say). `ownTailnet` holds this Mac's Tailscale addresses
	/// (`normalize`d). Tailnet needs all three: a tailnet-range peer, this Mac's Tailscale address,
	/// and a `utun` interface: a LAN host can send to the tailnet IP through en0 (macOS accepts a
	/// packet for any of its addresses on any interface), and that never went through WireGuard.
	/// The interface is the connection path's (`HTTPServer.localInterface`).
	public static func connectionKind(
		peer: String, local: String?, interface: String? = nil, ownTailnet: Set<String>
	) -> Kind {
		switch classify(peer) {
		case .loopback:
			// The kernel never routes a loopback source in from another interface.
			guard let local else { return .loopback }
			return classify(local) == .loopback ? .loopback : .other
		case .tailnet:
			guard let local, ownTailnet.contains(normalize(local)), interface?.hasPrefix("utun") == true else {
				return .other
			}
			return .tailnet
		case .localNetwork:
			if let local, ownTailnet.contains(normalize(local)) { return .other }
			return .localNetwork
		case .other:
			return .other
		}
	}

	/// Classifies a numeric address as NWEndpoint prints it (`100.64.0.1`, `::1`, `fe80::1%en0`,
	/// `::ffff:100.64.0.1`, optionally in brackets) by range alone.
	public static func classify(_ raw: String) -> Kind {
		guard let bytes = parse(raw) else { return .other }
		if bytes.count == 4 { return classify(v4: bytes) }
		if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .loopback }
		// fd7a:115c:a1e0::/48, Tailscale's IPv6 range.
		if bytes[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailnet }
		if bytes[0] & 0xfe == 0xfc { return .localNetwork }
		if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .localNetwork }
		return .other
	}

	static func classify(v4 octets: [UInt8]) -> Kind {
		guard octets.count == 4 else { return .other }
		let (a, b) = (octets[0], octets[1])
		if a == 127 { return .loopback }
		// 100.64.0.0/10: Tailscale's range (and carrier-grade NAT's).
		if a == 100, (64...127).contains(b) { return .tailnet }
		if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) {
			return .localNetwork
		}
		return .other
	}

	/// 4 bytes for IPv4 (and IPv4-mapped IPv6), 16 for IPv6; brackets and a zone dropped.
	static func parse(_ raw: String) -> [UInt8]? {
		var host = raw.trimmingCharacters(in: .whitespaces)
		if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
		if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
		var v4 = in_addr()
		if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
		var v6 = in6_addr()
		guard inet_pton(AF_INET6, host, &v6) == 1 else { return nil }
		let bytes = withUnsafeBytes(of: v6) { Array($0) }
		if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return Array(bytes[12..<16]) }
		return bytes
	}

	/// One spelling per address, so a local endpoint compares equal to the interface's address.
	public static func normalize(_ raw: String) -> String {
		guard let bytes = parse(raw) else { return raw }
		if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
		var address = in6_addr()
		withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
		var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return raw }
		return String(cString: buffer)
	}

	/// This Mac's Tailscale addresses: tailnet-range addresses on a `utun` interface. A
	/// carrier-NAT 100.x address on Wi-Fi is not one.
	public static func ownTailnetAddresses(_ interfaces: [InterfaceAddress]) -> Set<String> {
		Set(interfaces.filter { $0.name.hasPrefix("utun") && classify($0.ip) == .tailnet }.map { normalize($0.ip) })
	}

	/// IPv4 and IPv6 addresses of up, running, non-loopback interfaces.
	public static func interfaceAddresses() -> [InterfaceAddress] {
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return [] }
		defer { freeifaddrs(head) }
		var out: [InterfaceAddress] = []
		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			let flags = Int32(entry.pointee.ifa_flags)
			guard let address = entry.pointee.ifa_addr,
				address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6),
				flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
			else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard
				getnameinfo(
					address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
					== 0
			else { continue }
			let item = InterfaceAddress(name: String(cString: entry.pointee.ifa_name), ip: String(cString: host))
			if !out.contains(item) { out.append(item) }
		}
		return out
	}
}

/// The live answer to "is plain-LAN direct access on?" and "which addresses are this Mac's
/// Tailscale ones?": the helper's own config, or Whispera's setting read from the app's
/// preferences domain (so flipping it in Settings applies to the next connection without
/// restarting the helper), read at most once a second; the interfaces at most every 5 seconds.
public final class DirectAccessGate: @unchecked Sendable {
	private let configured: Bool
	private let preference: (@Sendable () -> Bool)?
	private let interfaces: @Sendable () -> [DirectAccessPolicy.InterfaceAddress]
	private let lock = NSLock()
	private var cached: (value: Bool, at: Date)?
	private var cachedInterfaces: (value: [DirectAccessPolicy.InterfaceAddress], at: Date)?

	public init(
		configured: Bool, preference: (@Sendable () -> Bool)? = nil,
		interfaces: @escaping @Sendable () -> [DirectAccessPolicy.InterfaceAddress] = {
			DirectAccessPolicy.interfaceAddresses()
		}
	) {
		self.configured = configured
		self.preference = preference
		self.interfaces = interfaces
	}

	/// Reads `DirectAccessPolicy.allowLANKey` from another process's preferences domain.
	public static func appPreference(domain: String) -> @Sendable () -> Bool {
		{
			CFPreferencesAppSynchronize(domain as CFString)
			return CFPreferencesCopyAppValue(DirectAccessPolicy.allowLANKey as CFString, domain as CFString) as? Bool
				?? false
		}
	}

	public var allowsLAN: Bool {
		if configured { return true }
		guard let preference else { return false }
		lock.lock()
		defer { lock.unlock() }
		if let cached, Date().timeIntervalSince(cached.at) < 1 { return cached.value }
		let value = preference()
		cached = (value, Date())
		return value
	}

	public var currentInterfaces: [DirectAccessPolicy.InterfaceAddress] {
		lock.lock()
		defer { lock.unlock() }
		if let cachedInterfaces, Date().timeIntervalSince(cachedInterfaces.at) < 5 { return cachedInterfaces.value }
		let value = interfaces()
		cachedInterfaces = (value, Date())
		return value
	}

	public var ownTailnet: Set<String> { DirectAccessPolicy.ownTailnetAddresses(currentInterfaces) }

	public func kind(peer: String, local: String?, interface: String?) -> DirectAccessPolicy.Kind {
		DirectAccessPolicy.connectionKind(peer: peer, local: local, interface: interface, ownTailnet: ownTailnet)
	}

	public func admits(peer: String, local: String?, interface: String?) -> Bool {
		DirectAccessPolicy.admits(kind(peer: peer, local: local, interface: interface), allowLAN: allowsLAN)
	}
}
