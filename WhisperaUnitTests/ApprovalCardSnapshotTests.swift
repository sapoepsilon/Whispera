import AppKit
import Foundation
import LinkHelperXPC
import SwiftUI
import Testing

@testable import Whispera

/// Renders the Mac approval card to PNG through the real `ApprovalCardPanel`, which is never the
/// key window (it is non-activating), so buttons draw the way the owner sees them. Written to
/// `WHISPERA_SNAPSHOT_DIR`, or a temp folder.
@MainActor
struct ApprovalCardSnapshotTests {
	static let created = 1_791_158_400

	static func request(
		op: String = "bws", key: String = "", summary: String = "read secret GITHUB_TOKEN", token: String = "read",
		caller: String = "claude", host: String = "build-box", expiresIn: Int = 287
	) throws -> ApprovalRequest {
		let canonical: [String: Any] = [
			"v": 1, "request_id": "apr_aaaaaaaaaaaaaaaaaaaaaaaa", "nonce": "bm9uY2Vub25jZW5vbmNlMQ", "op": op,
			"key": key, "summary": summary, "project": "fake-project", "token": token, "host": host,
			"caller": caller, "via": "ssh session to \(host)", "broker": "this Mac", "created_at": created,
			"expires_at": created + expiresIn,
		]
		let data = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
		return try ApprovalRequest(canonicalB64: data.base64EncodedString(), requestID: "apr_aaaaaaaaaaaaaaaaaaaaaaaa")
	}

	static func session(_ request: ApprovalRequest) -> ApprovalCardSession {
		ApprovalCardSession(request: request, link: StubLink(), authenticator: StubAuthenticator()) {
			created + 13
		}
	}

	/// Draws the panel (its frame view, so the window background is in the picture) without
	/// ordering it in: it stays a window that isn't key, like the real card.
	static func render(_ panel: NSPanel, name: String?, scheme: ColorScheme, withFrame: Bool = true) throws
		-> NSBitmapImageRep
	{
		panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
		let content = try #require(panel.contentView)
		let frame = withFrame ? content.superview ?? content : content
		frame.layoutSubtreeIfNeeded()
		RunLoop.current.run(until: Date().addingTimeInterval(0.3))
		frame.layoutSubtreeIfNeeded()
		let area = withFrame ? content.frame : content.bounds
		let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: area))
		frame.cacheDisplay(in: area, to: rep)
		if let name {
			let data = try #require(rep.representation(using: .png, properties: [:]))
			try data.write(to: AccountPairingSnapshotTests.directory.appendingPathComponent(name))
		}
		return rep
	}

	static func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

	@Test(arguments: [ColorScheme.light, .dark])
	func card(scheme: ColorScheme) throws {
		let panel = ApprovalCardPanel(session: Self.session(try Self.request()))
		#expect(!panel.isKeyWindow)
		_ = try Self.render(panel, name: "card-read-\(Self.suffix(scheme)).png", scheme: scheme)
	}

	/// The Approve button alone, in a non-activating panel that is not key: its label must stand
	/// out from its fill. `.borderedProminent` drew a white label on a nearly white inactive bezel
	/// here, which looked like an empty button.
	@Test(arguments: [ColorScheme.light, .dark])
	func approveButtonLabelIsVisibleInAPanelThatIsNotKey(scheme: ColorScheme) throws {
		let button = Button {
		} label: {
			Label("Approve with Touch ID", systemImage: "touchid").labelStyle(.titleAndIcon)
		}
		.buttonStyle(ApprovalCardButtonStyle(prominent: true))
		.fixedSize()
		.environment(\.controlActiveState, .inactive)
		let panel = Self.buttonPanel(button)
		#expect(!panel.isKeyWindow)
		let rep = try Self.render(
			panel, name: "card-approve-button-\(Self.suffix(scheme)).png", scheme: scheme, withFrame: false)
		let contrast = Self.labelContrast(rep, scheme: scheme)
		#expect(contrast.fraction > 0.03, "label pixels: \(contrast)")
	}

	/// A borderless, non-activating panel exactly the size of `view`.
	static func buttonPanel<V: View>(_ view: V) -> NSPanel {
		let hosting = NSHostingView(rootView: view)
		hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
		let panel = NSPanel(
			contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		panel.contentView = hosting
		return panel
	}

	/// Inside the button (a few points in from its edges), drawn over the card's background: the
	/// most common luminance is the fill; returns the share of pixels that differ from it by more
	/// than 0.3 (the label). Reads the pixels through an 8-bit sRGB context so the bitmap's own
	/// format doesn't matter, and a translucent bezel counts as what it looks like on the card.
	static func labelContrast(_ rep: NSBitmapImageRep, scheme: ColorScheme) -> (fill: Double, fraction: Double) {
		guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (0, 0) }
		let width = image.width
		let height = image.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
			guard
				let context = CGContext(
					data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
					space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			else { return false }
			// The panel's window background: about 0.93 in light mode, 0.16 in dark mode.
			context.setFillColor(CGColor(gray: scheme == .dark ? 0.16 : 0.93, alpha: 1))
			context.fill(CGRect(x: 0, y: 0, width: width, height: height))
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		guard drawn else { return (0, 0) }
		let inset = height / 4
		var lumas: [Double] = []
		for y in inset..<(height - inset) {
			for x in inset..<(width - inset) {
				let i = (y * width + x) * 4
				lumas.append(
					(0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255)
			}
		}
		var buckets = [Int](repeating: 0, count: 21)
		for luma in lumas { buckets[min(20, max(0, Int((luma * 20).rounded())))] += 1 }
		let fill = Double(buckets.firstIndex(of: buckets.max() ?? 0) ?? 0) / 20
		let label = lumas.filter { abs($0 - fill) > 0.3 }.count
		return (fill, lumas.isEmpty ? 0 : Double(label) / Double(lumas.count))
	}
}

private final class StubLink: ApprovalHelperLink, @unchecked Sendable {
	func approval(_ requestID: String) async -> Data? { Data(#"{"status":"pending"}"#.utf8) }
	func decide(_ requestID: String, decision: String, signature: String?) async -> Data? { nil }
}

private final class StubAuthenticator: ApprovalAuthenticator, @unchecked Sendable {
	func sign(_ message: Data, reason: String) async throws -> Data { throw ApprovalAuthenticationError.cancelled }
	func cancel() {}
}
