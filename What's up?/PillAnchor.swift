import AppKit

/// Publishes the listening pill's on-screen frame so other floating surfaces —
/// today, only the live-words HUD — can sit relative to it without reaching
/// into `ListeningWindow`'s `NSWindow` directly. `ListeningWindow` is the sole
/// writer; everything else only reads. See WHI-58.
@MainActor
@Observable
final class PillAnchorProvider {
	static let shared = PillAnchorProvider()

	/// nil while the pill is off screen. Anything anchoring to it should fall
	/// back to the pill's own resting spot — see `PillAnchor.frame`.
	private(set) var pillFrame: NSRect?

	func publish(_ frame: NSRect?) {
		pillFrame = frame
	}
}

/// Pure geometry for where a surface of a given size should sit relative to the
/// pill. No `NSWindow`, no observation — a plain function so the coordination
/// rule is covered by an ordinary unit test instead of a screenshot. See
/// PillAnchorTests.
enum PillAnchor {
	/// Gap between the pill's top edge and the bottom of whatever sits above it,
	/// matching the pill's own controls-panel gap (`PillMetrics.controlsGap`) so
	/// every surface that grows out of the pill uses the same one number.
	static let gap: CGFloat = PillMetrics.controlsGap

	/// A rect for `size` whose bottom edge sits `gap` above the pill — so growth
	/// in `size.height` reads as the surface growing upward, away from the
	/// pill, never toward or through it — and which is horizontally centered on
	/// the pill. With no pill on screen, falls back to the pill's own
	/// bottom-center resting spot, so a transient shown before the pill appears
	/// (or a stale read racing the pill's own visibility notification) lands
	/// exactly where the pill would be.
	static func frame(for size: CGSize, screenFrame: NSRect, pillFrame: NSRect?) -> NSRect {
		guard let pillFrame else {
			let x = screenFrame.origin.x + (screenFrame.width - size.width) / 2
			let y = screenFrame.origin.y + screenFrame.height * PillMetrics.bottomAnchorFraction
			return NSRect(x: x, y: y, width: size.width, height: size.height)
		}

		let x = (pillFrame.midX - size.width / 2).rounded()
		let y = pillFrame.maxY + gap
		return NSRect(x: x, y: y, width: size.width, height: size.height)
	}
}
