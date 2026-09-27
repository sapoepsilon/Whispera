import AppKit
import SwiftUI

/// The SwiftUI Settings scene keeps taking `.resizable` off its window whatever the content
/// allows, so the sidebar layout restores it on the hosting window whenever it is removed.
struct SettingsWindowConfigurator: NSViewRepresentable {
	let minimumSize: NSSize

	func makeNSView(context: Context) -> ConfiguringView {
		ConfiguringView(minimumSize: minimumSize)
	}

	func updateNSView(_ view: ConfiguringView, context: Context) {
		view.minimumSize = minimumSize
		view.apply()
	}

	final class ConfiguringView: NSView {
		var minimumSize: NSSize
		private var styleObservation: NSKeyValueObservation?

		init(minimumSize: NSSize) {
			self.minimumSize = minimumSize
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
