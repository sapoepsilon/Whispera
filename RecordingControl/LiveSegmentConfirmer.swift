import Foundation

/// A decoded live segment and where it sits in the session audio, in seconds.
struct LiveSegment: Equatable, Sendable {
	var text: String
	var start: Float
	var end: Float
}

/// Decides which live segments are final and so get typed.
///
/// Every pass decodes from `confirmedThroughSeconds`, so audio behind a confirmed segment is never
/// decoded again. Confirming by segment index over a re-decoded whole buffer dropped or retyped
/// sentences whenever Whisper merged or split the window's segments differently between passes.
/// A segment is confirmed once `holdBack` newer segments follow it and the previous pass decoded
/// the same text in the same place, so one unstable decode (short windows carry nonsense
/// timestamps) cannot move the confirmation point.
struct LiveSegmentConfirmer: Equatable, Sendable {
	struct Result: Equatable, Sendable {
		/// Processed text of the newly confirmed segments, empty when nothing new is typed.
		var confirmedAddition: String
		/// Every unconfirmed segment of this pass: what stopping the session still has to type.
		var pendingText: String
		var confirmedSegmentCount: Int
	}

	var holdBack: Int
	private(set) var confirmedThroughSeconds: Float = 0
	private var previousPass: [String] = []

	init(holdBack: Int = 2) {
		self.holdBack = holdBack
	}

	mutating func apply(
		_ segments: [LiveSegment], audioSeconds: Float, process: (String) -> String
	) -> Result {
		let live =
			segments
			.map { LiveSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end) }
			.filter { !$0.text.isEmpty && $0.end > confirmedThroughSeconds + 0.01 }
		let keys = live.map { Self.comparisonKey($0.text) }
		let confirmable = max(0, live.count - holdBack)
		var agreed = 0
		while agreed < confirmable, agreed < previousPass.count, keys[agreed] == previousPass[agreed] {
			agreed += 1
		}

		var through = live.prefix(agreed).last?.end ?? confirmedThroughSeconds
		if agreed < live.count, live[agreed].start > confirmedThroughSeconds {
			through = min(through, live[agreed].start)
		}
		through = min(through, audioSeconds)
		// A confirmation that would not move the decode start would decode the same audio again
		guard agreed > 0, through > confirmedThroughSeconds else {
			previousPass = keys
			return Result(confirmedAddition: "", pendingText: Self.joined(live[...]), confirmedSegmentCount: 0)
		}

		confirmedThroughSeconds = through
		previousPass = Array(keys.dropFirst(agreed))
		let raw = Self.joined(live.prefix(agreed))
		return Result(
			// A chunk made only of filler words is consumed without typing anything
			confirmedAddition: process(raw), pendingText: Self.joined(live.dropFirst(agreed)),
			confirmedSegmentCount: agreed)
	}

	private static func joined(_ segments: ArraySlice<LiveSegment>) -> String {
		segments.map(\.text).joined(separator: " ")
	}

	/// Case and punctuation flip between passes ("cancel" / "Cancel.") without the words changing.
	static func comparisonKey(_ text: String) -> String {
		text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
}
