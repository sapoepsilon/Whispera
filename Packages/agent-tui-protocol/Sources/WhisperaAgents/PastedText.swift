// SPDX-License-Identifier: MIT
import Foundation

/// Text pasted into an agent's terminal as a prompt. It may only type: a carriage return
/// would press Enter (submitting or answering a dialog early) and a control character such
/// as Ctrl-C (`\u{03}`) or Esc would act as a key, so they never reach the terminal as part of
/// pasted text. Keys go through the hosts' explicit key APIs instead.
public enum PastedText {
	/// `\r\n` becomes `\n`; every other C0 control except tab and newline, DEL and the C1
	/// controls (`0x80`–`0x9F`, which some terminals read as CSI and friends) are removed.
	public static func sanitize(_ text: String) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in text.unicodeScalars where isAllowed(scalar) { scalars.append(scalar) }
		return String(scalars)
	}

	static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x09, 0x0A: return true
		case 0x00...0x1F, 0x7F, 0x80...0x9F: return false
		default: return true
		}
	}
}
