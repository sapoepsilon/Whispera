import AppKit
import Carbon.HIToolbox
import Foundation

enum KeyboardEventKind: Sendable {
	case keyDown
	case keyUp
	case flagsChanged
}

enum KeyboardEventScope: Sendable {
	/// Delivered while another app is frontmost; only arrives with Accessibility granted.
	case global
	case local
}

enum HotkeyShortcutKind: String, Sendable {
	case dictation
	case fileSelection
}

/// Event counters for the keyboard diagnostic. Deliberately stores no key codes or
/// characters, so running it while typing a password leaks nothing.
struct KeyboardDiagnosticCounts: Equatable {
	var keyDown = 0
	var keyUp = 0
	var flagsChanged = 0
	var autoRepeats = 0
	var global = 0
	var local = 0
	var dictationMatches = 0
	var fileSelectionMatches = 0
	var eventMonitorMatches = 0
	var carbonMatches = 0

	var totalEvents: Int { keyDown + keyUp + flagsChanged }

	mutating func record(_ kind: KeyboardEventKind, scope: KeyboardEventScope, isRepeat: Bool = false) {
		switch kind {
		case .keyDown: keyDown += 1
		case .keyUp: keyUp += 1
		case .flagsChanged: flagsChanged += 1
		}
		if isRepeat { autoRepeats += 1 }
		switch scope {
		case .global: global += 1
		case .local: local += 1
		}
	}

	mutating func recordShortcut(_ shortcut: HotkeyShortcutKind, backend: HotkeyBackend) {
		switch shortcut {
		case .dictation: dictationMatches += 1
		case .fileSelection: fileSelectionMatches += 1
		}
		switch backend {
		case .eventMonitor: eventMonitorMatches += 1
		case .carbon: carbonMatches += 1
		}
	}
}

@MainActor
@Observable
final class KeyboardDiagnostics {
	static let shared = KeyboardDiagnostics()

	private(set) var counts = KeyboardDiagnosticCounts()
	private(set) var isCapturing = false
	private(set) var lastEventAt: Date?
	private(set) var lastShortcutAt: Date?
	private(set) var requestedBackend: HotkeyBackend = .eventMonitor
	private(set) var activeBackend: HotkeyBackend = .eventMonitor
	private(set) var backendMessage: String?

	@ObservationIgnored private var globalMonitor: Any?
	@ObservationIgnored private var localMonitor: Any?

	var accessibilityTrusted: Bool { AXIsProcessTrusted() }
	var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

	func startCapture() {
		guard !isCapturing else { return }
		let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
			let kind = Self.kind(of: event)
			let isRepeat = event.type == .keyDown && event.isARepeat
			Task { @MainActor in self?.record(kind, scope: .global, isRepeat: isRepeat) }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
			let kind = Self.kind(of: event)
			let isRepeat = event.type == .keyDown && event.isARepeat
			MainActor.assumeIsolated {
				self?.record(kind, scope: .local, isRepeat: isRepeat)
			}
			return event
		}
		isCapturing = true
		AppLogger.shared.general.info("Keyboard diagnostic capture started")
	}

	func stopCapture() {
		if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
		if let localMonitor { NSEvent.removeMonitor(localMonitor) }
		globalMonitor = nil
		localMonitor = nil
		guard isCapturing else { return }
		isCapturing = false
		AppLogger.shared.general.info(
			"Keyboard diagnostic capture stopped: \(counts.totalEvents) events, \(counts.global) global")
	}

	func reset() {
		counts = KeyboardDiagnosticCounts()
		lastEventAt = nil
		lastShortcutAt = nil
	}

	func record(_ kind: KeyboardEventKind, scope: KeyboardEventScope, isRepeat: Bool) {
		counts.record(kind, scope: scope, isRepeat: isRepeat)
		lastEventAt = Date()
	}

	func recordShortcut(_ shortcut: HotkeyShortcutKind, backend: HotkeyBackend) {
		counts.recordShortcut(shortcut, backend: backend)
		lastShortcutAt = Date()
	}

	func updateBackend(requested: HotkeyBackend, active: HotkeyBackend, message: String?) {
		requestedBackend = requested
		activeBackend = active
		backendMessage = message
	}

	private nonisolated static func kind(of event: NSEvent) -> KeyboardEventKind {
		switch event.type {
		case .keyUp: return .keyUp
		case .flagsChanged: return .flagsChanged
		default: return .keyDown
		}
	}
}
