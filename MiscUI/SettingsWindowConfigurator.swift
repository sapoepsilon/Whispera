import AppKit
import SwiftUI

/// The SwiftUI Settings scene keeps taking `.resizable` off its window whatever the content
/// allows, so the sidebar layout restores it on the hosting window whenever it is removed.
struct SettingsWindowConfigurator: NSViewRepresentable {
	let minimumSize: NSSize
	let idealSize: NSSize

	func makeNSView(context: Context) -> ConfiguringView {
		ConfiguringView(minimumSize: minimumSize, idealSize: idealSize)
	}

	func updateNSView(_ view: ConfiguringView, context: Context) {
		view.minimumSize = minimumSize
		view.idealSize = idealSize
		view.apply()
	}

	final class ConfiguringView: NSView {
		var minimumSize: NSSize
		var idealSize: NSSize
		private var styleObservation: NSKeyValueObservation?
		private weak var openedWindow: NSWindow?

		init(minimumSize: NSSize, idealSize: NSSize) {
			self.minimumSize = minimumSize
			self.idealSize = idealSize
			super.init(frame: .zero)
		}

		required init?(coder: NSCoder) {
			fatalError("init(coder:) is not supported")
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			styleObservation = window?.observe(\.styleMask, options: [.new]) { window, _ in
				guard !window.styleMask.contains(.resizable) else { return }
				DispatchQueue.main.async { window.styleMask.insert(.resizable) }
			}
			apply()
			guard let window, window !== openedWindow else { return }
			openedWindow = window
			// SwiftUI sizes the Settings window after the content attaches; grow it once that is done.
			DispatchQueue.main.async { [weak self] in self?.growToIdealSizeOnce() }
		}

		private func growToIdealSizeOnce() {
			guard let window else { return }
			let defaults = UserDefaults.standard
			let alreadySized = defaults.bool(forKey: SettingsLayout.sizedToIdealKey)
			defaults.set(true, forKey: SettingsLayout.sizedToIdealKey)
			let frame = window.frame
			// The Settings window draws under its title bar, so measure the area below it.
			let content = window.contentLayoutRect.size
			let chrome = NSSize(width: frame.width - content.width, height: frame.height - content.height)
			let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? idealSize
			let available = NSSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
			guard
				let target = SettingsLayout.openingContentSize(
					current: content, minimum: minimumSize, ideal: idealSize, available: available,
					alreadySized: alreadySized)
			else { return }
			let size = NSSize(width: target.width + chrome.width, height: target.height + chrome.height)
			let screen = window.screen ?? NSScreen.main
			let grown = SettingsLayout.openingFrame(from: frame, size: size, visible: screen?.visibleFrame ?? frame)
			window.setFrame(window.constrainFrameRect(grown, to: screen), display: true)
		}

		func apply() {
			guard let window else { return }
			window.styleMask.insert(.resizable)
			window.contentMinSize = minimumSize
			let content = window.contentRect(forFrameRect: window.frame).size
			let fitted = SettingsLayout.size(content, atLeast: minimumSize)
			if fitted != content { window.setContentSize(fitted) }
		}
	}
}
