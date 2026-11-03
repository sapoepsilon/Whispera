import Foundation

/// `WHISPERA_AUTOSTART_DICTATION=<seconds to record>`: a headless verification run starts one
/// dictation without a keypress. Debug builds only; a release build never reads the variable,
/// so nothing in a user's environment can open the microphone on launch.
enum AutostartDictationAffordance {
	static let environmentKey = "WHISPERA_AUTOSTART_DICTATION"
	/// Clamped so a stray value cannot hold the microphone open indefinitely.
	static let maximumSeconds: Double = 120

	/// The seconds to record, or nil when the affordance is off (always nil in release builds).
	static func requestedSeconds(environment: [String: String]) -> Double? {
		#if DEBUG
			guard let raw = environment[environmentKey], let requested = Double(raw), requested > 0 else {
				return nil
			}
			return min(requested, maximumSeconds)
		#else
			return nil
		#endif
	}
}
