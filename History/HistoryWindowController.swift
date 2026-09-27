import AppKit
import SwiftUI

/// Standalone history window for the URL scheme, App Intents and launchers, which cannot
/// reach the SwiftUI Settings scene's section selection.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
	static let shared = HistoryWindowController()

	private var window: NSWindow?

	func show() {
		if let window {
			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)
			return
		}
		let window = Self.makeWindow(rootView: TranscriptionHistoryView())
		window.title = String(localized: "Transcription History")
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.center()
		self.window = window
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
	}

	static let defaultContentSize = NSSize(width: 640, height: 620)
	static let minimumContentSize = NSSize(width: 520, height: 400)

	/// The hosting view sets no window size constraints at all. With the default options it pushed
	/// the list's ideal height onto the window, and even with only `.minSize` the history list
	/// reported its full height as the minimum (640 x 2745 pt with 50 entries), so the window ran
	/// off the bottom of the screen. The minimum is fixed here instead.
	static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: defaultContentSize),
			styleMask: [.titled, .closable, .resizable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		let hostingView = NSHostingView(rootView: rootView)
		hostingView.sizingOptions = []
		window.contentView = hostingView
		window.contentMinSize = minimumContentSize
		window.setContentSize(defaultContentSize)
		return window
	}

	func windowWillClose(_ notification: Notification) {
		// Drop the hosting view so the history list and its player are released while closed.
		window?.contentView = nil
		window = nil
	}
}
