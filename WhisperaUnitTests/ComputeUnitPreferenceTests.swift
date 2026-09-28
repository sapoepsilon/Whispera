import CoreML
import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct ComputeUnitPreferenceTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "ComputeUnitPreferenceTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsToAutomaticWhenUnset() {
		#expect(ComputeUnitPreference.load(from: isolatedDefaults()) == .automatic)
	}

	@Test func unknownStoredValueFallsBackToAutomatic() {
		let defaults = isolatedDefaults()
		defaults.set("tpu", forKey: ComputeUnitPreference.storageKey)
		#expect(ComputeUnitPreference.load(from: defaults) == .automatic)
	}

	@Test(arguments: ComputeUnitPreference.allCases)
	func persistsRoundTrip(preference: ComputeUnitPreference) {
		let defaults = isolatedDefaults("roundTrip.\(preference.rawValue)")
		preference.save(to: defaults)
		#expect(ComputeUnitPreference.load(from: defaults) == preference)
	}

	@Test func automaticKeepsTheTunedSplit() {
		let options = ComputeUnitPreference.automatic.whisperKitComputeOptions
		#expect(options.melCompute == .cpuAndGPU)
		#expect(options.audioEncoderCompute == .cpuAndGPU)
		#expect(options.textDecoderCompute == .cpuAndNeuralEngine)
		#expect(options.prefillCompute == .cpuAndGPU)
		#expect(ComputeUnitPreference.automatic.parakeetComputeUnits == nil)
	}

	@Test(arguments: [
		(ComputeUnitPreference.cpuOnly, MLComputeUnits.cpuOnly),
		(ComputeUnitPreference.gpu, MLComputeUnits.cpuAndGPU),
		(ComputeUnitPreference.neuralEngine, MLComputeUnits.cpuAndNeuralEngine),
	])
	func explicitChoicesApplyToEveryStage(preference: ComputeUnitPreference, units: MLComputeUnits) {
		let options = preference.whisperKitComputeOptions
		#expect(options.melCompute == units)
		#expect(options.audioEncoderCompute == units)
		#expect(options.textDecoderCompute == units)
		#expect(options.prefillCompute == units)
		#expect(preference.parakeetComputeUnits == units)
	}
}
