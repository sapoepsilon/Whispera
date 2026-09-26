import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Whispera

struct HotkeyBackendTests {

	@Test func preferenceDefaultsToEventMonitorAndIgnoresGarbage() throws {
		let suite = "HotkeyBackendTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(HotkeyBackend.preferred(in: defaults) == .eventMonitor)
		defaults.set("carbon", forKey: HotkeyBackend.defaultsKey)
		#expect(HotkeyBackend.preferred(in: defaults) == .carbon)
		defaults.set("nonsense", forKey: HotkeyBackend.defaultsKey)
		#expect(HotkeyBackend.preferred(in: defaults) == .eventMonitor)
	}

	@Test func mapsCocoaModifiersToCarbon() {
		#expect(CarbonHotKeyMapping.carbonModifiers(from: []) == 0)
		#expect(CarbonHotKeyMapping.carbonModifiers(from: .command) == UInt32(cmdKey))
		#expect(
			CarbonHotKeyMapping.carbonModifiers(from: [.option, .command])
				== UInt32(optionKey) | UInt32(cmdKey))
		#expect(
			CarbonHotKeyMapping.carbonModifiers(from: [.control, .shift, .option, .command])
				== UInt32(controlKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(cmdKey))
		#expect(CarbonHotKeyMapping.carbonModifiers(from: [.capsLock, .function]) == 0)
	}

	@Test func refusesFunctionKey() {
		#expect(!CarbonHotKeyMapping.isSupported(keyCode: 63))
		#expect(CarbonHotKeyMapping.isSupported(keyCode: 15))
		#expect(throws: CarbonHotKeyError.unsupportedKey) {
			try CarbonHotKeyCenter().register(keyCode: 63, modifiers: .command) {}
		}
	}

	@Test @MainActor func registersAndReleasesARealSystemHotkey() {
		let center = CarbonHotKeyCenter()
		// F19 with every modifier: nothing on a stock Mac claims it.
		let keyCode = UInt16(kVK_F19)
		let modifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
		var firstID: UInt32?
		do {
			firstID = try center.register(keyCode: keyCode, modifiers: modifiers) {}
		} catch {
			Issue.record("First registration failed: \(error)")
		}
		#expect(center.registeredCount == 1)

		let second = CarbonHotKeyCenter()
		var secondOutcome = "registered"
		do {
			let id = try second.register(keyCode: keyCode, modifiers: modifiers) {}
			second.unregister(id: id)
		} catch {
			secondOutcome = "\(error)"
		}
		#expect(secondOutcome == "\(CarbonHotKeyError.alreadyTaken)", "Duplicate registration outcome")

		if let firstID { center.unregister(id: firstID) }
		#expect(center.registeredCount == 0)
		do {
			let reused = try second.register(keyCode: keyCode, modifiers: modifiers) {}
			second.unregister(id: reused)
		} catch {
			Issue.record("Re-registration after release failed: \(error)")
		}
	}
}

struct KeyboardDiagnosticCountsTests {

	@Test func countsEventKindsAndScopesWithoutKeyIdentity() {
		var counts = KeyboardDiagnosticCounts()
		counts.record(.keyDown, scope: .global)
		counts.record(.keyDown, scope: .global, isRepeat: true)
		counts.record(.keyUp, scope: .local)
		counts.record(.flagsChanged, scope: .local)

		#expect(counts.keyDown == 2)
		#expect(counts.keyUp == 1)
		#expect(counts.flagsChanged == 1)
		#expect(counts.autoRepeats == 1)
		#expect(counts.global == 2)
		#expect(counts.local == 2)
		#expect(counts.totalEvents == 4)
	}

	@Test func countsShortcutMatchesPerBackend() {
		var counts = KeyboardDiagnosticCounts()
		counts.recordShortcut(.dictation, backend: .eventMonitor)
		counts.recordShortcut(.dictation, backend: .carbon)
		counts.recordShortcut(.fileSelection, backend: .carbon)

		#expect(counts.dictationMatches == 2)
		#expect(counts.fileSelectionMatches == 1)
		#expect(counts.eventMonitorMatches == 1)
		#expect(counts.carbonMatches == 2)
	}

	@Test @MainActor func diagnosticsResetClearsCounters() {
		let diagnostics = KeyboardDiagnostics()
		diagnostics.record(.keyDown, scope: .local, isRepeat: false)
		diagnostics.recordShortcut(.dictation, backend: .carbon)
		#expect(diagnostics.lastEventAt != nil)

		diagnostics.reset()
		#expect(diagnostics.counts == KeyboardDiagnosticCounts())
		#expect(diagnostics.lastEventAt == nil)
		#expect(diagnostics.lastShortcutAt == nil)
	}

	@Test @MainActor func captureInstallsAndRemovesMonitors() {
		let diagnostics = KeyboardDiagnostics()
		diagnostics.startCapture()
		#expect(diagnostics.isCapturing)
		diagnostics.stopCapture()
		#expect(!diagnostics.isCapturing)
	}
}
