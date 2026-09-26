import AppKit
import SwiftUI

/// Standalone history window for the URL scheme, App Intents and launchers, which cannot
/// reach the SwiftUI Settings scene's tab selection.
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

	/// The hosting view only reports a minimum size: by default it also pushes the list's ideal
	/// height onto the window, which grew past the bottom of the screen once history had a few
	/// dozen entries.
	static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: defaultContentSize),
			styleMask: [.titled, .closable, .resizable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		let hostingView = NSHostingView(rootView: rootView)
		hostingView.sizingOptions = [.minSize]
		window.contentView = hostingView
		window.setContentSize(defaultContentSize)
		return window
	}

	func windowWillClose(_ notification: Notification) {
		// Drop the hosting view so the history list and its player are released while closed.
		window?.contentView = nil
		window = nil
	}
}
