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
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
			styleMask: [.titled, .closable, .resizable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		window.title = String(localized: "Transcription History")
		window.contentView = NSHostingView(rootView: TranscriptionHistoryView())
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.center()
		self.window = window
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
	}

	func windowWillClose(_ notification: Notification) {
		// Drop the hosting view so the history list and its player are released while closed.
		window?.contentView = nil
		window = nil
	}
}
