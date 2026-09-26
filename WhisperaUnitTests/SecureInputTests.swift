import AppKit
import Carbon
import Foundation
import Testing

@testable import Whispera

struct SecureInputStateMachineTests {
	@Test func momentaryPasswordFieldNeverBecomesSustained() {
		var machine = SecureInputStateMachine()
		let start = Date()
		#expect(machine.update(enabled: true, now: start) == .enabled)
		#expect(machine.update(enabled: true, now: start.addingTimeInterval(1)) == .none)
		#expect(machine.update(enabled: false, now: start.addingTimeInterval(2)) == .disabled(wasSustained: false))
		#expect(!machine.isSustained)
	}

	@Test func heldSecureInputBecomesSustainedOnceAfterThreshold() {
		var machine = SecureInputStateMachine()
		let start = Date()
		_ = machine.update(enabled: true, now: start)
		#expect(machine.update(enabled: true, now: start.addingTimeInterval(3)) == .sustained)
		#expect(machine.update(enabled: true, now: start.addingTimeInterval(4)) == .none)
		#expect(machine.isSustained)
		#expect(machine.update(enabled: false, now: start.addingTimeInterval(5)) == .disabled(wasSustained: true))
		#expect(!machine.isEnabled && !machine.isSustained)
	}

	@Test func staysQuietWhileDisabled() {
		var machine = SecureInputStateMachine()
		#expect(machine.update(enabled: false, now: Date()) == .none)
	}
}

struct SecureInputCulpritLookupTests {
	@Test func readsThePIDFromIORegOutput() {
		let output = """
			+-o Root  <class IORegistryEntry, id 0x100000100, retain 44>
			    "IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionSecureInputPID"=4312,"kCGSSessionUserIDKey"=501})
			"""
		#expect(SecureInputCulpritLookup.pid(fromIORegOutput: output) == 4312)
	}

	@Test func missingPIDIsNil() {
		let output = #""IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserIDKey"=501})"#
		#expect(SecureInputCulpritLookup.pid(fromIORegOutput: output) == nil)
	}

	@Test func namesTheCurrentProcess() {
		let name = SecureInputCulpritLookup.processName(for: ProcessInfo.processInfo.processIdentifier)
		#expect(!name.isEmpty)
		#expect(name != "a process that is no longer running")
	}
}

struct CarbonHotKeyMappingTests {
	@Test func mapsEveryModifier() {
		let spec = CarbonHotKeyMapping.spec(keyCode: 15, modifiers: [.command, .option, .control, .shift])
		#expect(spec?.keyCode == 15)
		#expect(spec?.modifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))
	}

	@Test func mapsTheDefaultShortcut() {
		let spec = CarbonHotKeyMapping.spec(keyCode: 15, modifiers: [.command, .option])
		#expect(spec == CarbonHotKeySpec(keyCode: 15, modifiers: UInt32(cmdKey | optionKey)))
	}

	@Test func globeKeyHasNoCarbonEquivalent() {
		#expect(CarbonHotKeyMapping.spec(keyCode: 63, modifiers: []) == nil)
	}
}

@MainActor
struct SecureInputMonitorTests {
	private final class FakeSecureInput {
		var enabled = false
	}

	// An obscure chord so registering it in the test host cannot collide with a real shortcut
	private let testSpec = CarbonHotKeySpec(
		keyCode: 80, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))

	private func makeMonitor() -> (SecureInputMonitor, FakeSecureInput, UserDefaults, String) {
		let suite = "SecureInputMonitorTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		let fake = FakeSecureInput()
		let monitor = SecureInputMonitor(defaults: defaults, isSecureInputEnabled: { fake.enabled })
		return (monitor, fake, defaults, suite)
	}

	@Test func registersTheFallbackOnlyWhileSustained() {
		let (monitor, fake, defaults, suite) = makeMonitor()
		defer {
			monitor.stop()
			defaults.removePersistentDomain(forName: suite)
		}
		monitor.configure(hotKeySpec: { self.testSpec }, action: {})
		let start = Date()

		fake.enabled = true
		monitor.poll(now: start)
		#expect(monitor.isEnabled)
		#expect(monitor.fallbackStatus == .inactive)

		monitor.poll(now: start.addingTimeInterval(SecureInputStateMachine.sustainThreshold))
		#expect(monitor.isSustained)
		#expect(monitor.fallbackStatus == .active)
		#expect(!monitor.showsWarning)

		fake.enabled = false
		monitor.poll(now: start.addingTimeInterval(5))
		#expect(!monitor.isSustained)
		#expect(monitor.fallbackStatus == .inactive)
		#expect(monitor.culprit == nil)
	}

	@Test func warnsWhenTheShortcutHasNoCarbonEquivalent() {
		let (monitor, fake, defaults, suite) = makeMonitor()
		defer {
			monitor.stop()
			defaults.removePersistentDomain(forName: suite)
		}
		monitor.configure(hotKeySpec: { nil }, action: {})
		let start = Date()
		fake.enabled = true
		monitor.poll(now: start)
		monitor.poll(now: start.addingTimeInterval(4))

		#expect(monitor.fallbackStatus == .unavailable)
		#expect(monitor.showsWarning)
	}

	@Test func respectsTheFallbackSetting() {
		let (monitor, fake, defaults, suite) = makeMonitor()
		defer {
			monitor.stop()
			defaults.removePersistentDomain(forName: suite)
		}
		#expect(monitor.isFallbackEnabled)
		defaults.set(false, forKey: SecureInputMonitor.Keys.fallbackEnabled)
		monitor.configure(hotKeySpec: { self.testSpec }, action: {})
		let start = Date()
		fake.enabled = true
		monitor.poll(now: start)
		monitor.poll(now: start.addingTimeInterval(4))
		#expect(monitor.fallbackStatus == .disabledByUser)
		#expect(monitor.showsWarning)

		defaults.set(true, forKey: SecureInputMonitor.Keys.fallbackEnabled)
		monitor.reconcileFallback()
		#expect(monitor.fallbackStatus == .active)
	}

	@Test func carbonHotKeyRegistersAndUnregisters() {
		let hotKey = CarbonHotKey()
		#expect(hotKey.register(testSpec))
		#expect(hotKey.registeredSpec == testSpec)
		#expect(hotKey.register(testSpec))
		hotKey.unregister()
		#expect(hotKey.registeredSpec == nil)
	}
}
