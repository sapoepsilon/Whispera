import AppKit
import ApplicationServices
import Metal

private let logger = AppLogger.shared.ui

extension Notification.Name {
	/// Posted immediately before a dictation result is pasted into the focused
	/// app. Object is an `NSValue` wrapping the caret point in screen
	/// coordinates, or nil when the focused element did not expose one.
	static let dictationWillPaste = Notification.Name("DictationWillPaste")
}

/// Builds the transparent full-screen surface the particle field draws into.
/// Shared by the onboarding route (out to the screen border and back) and the
/// dictation route (a one-way flight into the caret).
@MainActor
enum MagnetField {
	/// The caret's rect in Cocoa screen coordinates, or nil when the focused
	/// element does not expose a usable one.
	///
	/// `AccessibilityHelper.getCaretPosition()` is deliberately not reused: it
	/// flips Y against `NSScreen.main`, which is the focused screen rather than
	/// the primary one, and it keeps degenerate rects. Chrome answers the bounds
	/// query with a zero rect for many fields, which that path turns into a
	/// bottom-corner "position" instead of a miss.
	static func caretRect() -> CGRect? {
		guard AXIsProcessTrusted() else { return nil }

		let system = AXUIElementCreateSystemWide()
		var app: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(
				system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
			let app
		else { return nil }

		var focused: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(
				app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
			let focused
		else { return nil }

		var rangeRef: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(
				focused as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
				== .success,
			let rangeRef
		else { return nil }

		var boundsRef: CFTypeRef?
		guard
			AXUIElementCopyParameterizedAttributeValue(
				focused as! AXUIElement, kAXBoundsForRangeParameterizedAttribute as CFString,
				rangeRef as! AXValue, &boundsRef) == .success,
			let boundsRef
		else { return nil }

		var axRect = CGRect.zero
		guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &axRect) else { return nil }
		guard axRect.origin.x.isFinite, axRect.origin.y.isFinite,
			axRect.width.isFinite, axRect.height.isFinite
		else { return nil }
		// a caret always has height; zero-height is how apps say "I don't know"
		guard axRect.height > 0 else { return nil }

		// AX reports a top-left origin measured from the primary display, which
		// is screens[0] — not NSScreen.main, which follows keyboard focus
		guard let primary = NSScreen.screens.first else { return nil }
		let rect = CGRect(
			x: axRect.origin.x,
			y: primary.frame.maxY - axRect.maxY,
			width: max(axRect.width, 1),
			height: axRect.height)

		// off-screen or scrolled out of view: there is nothing to fly to
		guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
		return rect
	}

	/// Whether the dictation flight can run for this caret. Shared by the
	/// controller and by the paste timing so the two can never disagree.
	static func dictationRouteEnabled(caret: CGRect?) -> Bool {
		guard caret != nil else { return false }
		// onboarding owns the screen during its own run; this is the everyday path
		guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return false }
		// rides the same switch as the edge glow: turning that off turns the
		// whole particle treatment off
		guard UserDefaults.standard.bool(forKey: "enableRecordingGlow") else { return false }
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
		return true
	}

	/// How long to hold the paste keystroke so the text appears as the field
	/// lands, instead of a beat before it. Zero when the flight will not run.
	static func pasteLeadTime(caret: CGRect?) -> TimeInterval {
		guard dictationRouteEnabled(caret: caret) else { return 0 }
		return EdgeMagnetProfile.dictation.outbound * 0.7
	}

	static func glowColor() -> NSColor {
		NSColor(
			RecordingGlowColor.color(
				fromHex: UserDefaults.standard.string(forKey: RecordingGlowColor.key)
					?? RecordingGlowColor.defaultHex))
	}

	static func make(
		on screen: NSScreen, sourceRect: CGRect, route: EdgeMagnetRoute,
		profile: EdgeMagnetProfile
	) -> (panel: NSPanel, renderer: EdgeMagnetRenderer)? {
		guard let device = MTLCreateSystemDefaultDevice() else {
			logger.error("EdgeMagnet: no Metal device, skipping transition")
			return nil
		}

		let view = EdgeMagnetLayerView(frame: CGRect(origin: .zero, size: screen.frame.size))
		guard
			let renderer = EdgeMagnetRenderer(
				layer: view.metalLayer,
				device: device,
				sourceRect: sourceRect,
				route: route,
				color: glowColor(),
				profile: profile)
		else { return nil }

		let panel = NSPanel(
			contentRect: screen.frame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.level = .screenSaver
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.hidesOnDeactivate = false
		panel.collectionBehavior = [
			.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
		]
		panel.contentView = view
		panel.orderFrontRegardless()
		// drawable size needs the panel's backing scale, so size it once the
		// view actually has a window
		view.syncDrawableSize()
		renderer.start(pointScale: view.metalLayer.contentsScale)

		return (panel, renderer)
	}

	/// Rebases a global screen rect into a panel that spans `screen`.
	static func localRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
		rect.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)
	}
}
