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
/// the same text ending at about the same time. The decode start then moves to the end of the last
/// confirmed segment's speech as both passes place it, and never past the start of the first
/// segment still pending in either pass or the end of the audio: short windows carry nonsense
/// timestamps, and a cut too early retypes the end of a sentence while a cut too late skips the
/// start of the next one. A pass whose timestamps allow no such point confirms nothing. Only when
/// the whole pass is confirmed (no hold-back) may a segment's end past the audio be clamped to it.
struct LiveSegmentConfirmer: Equatable, Sendable {
	struct Result: Equatable, Sendable {
		/// Processed text of the newly confirmed segments, empty when nothing new is typed.
		var confirmedAddition: String
		/// Every unconfirmed segment of this pass: what stopping the session still has to type.
		var pendingText: String
		var confirmedSegmentCount: Int
	}

	private struct Decoded: Equatable, Sendable {
		var key: String
		var start: Float
		var end: Float
	}

	var holdBack: Int
	/// How far the end of the same segment may move between two passes and still count as agreed.
	var endTolerance: Float = 0.6
	/// Whisper's 20 ms timestamp steps let neighbouring segments touch or overlap slightly.
	var overlapTolerance: Float = 0.1
	private(set) var confirmedThroughSeconds: Float = 0
	private var previousPass: [Decoded] = []

	init(holdBack: Int = 2) {
		self.holdBack = holdBack
	}

	mutating func apply(
		_ segments: [LiveSegment], audioSeconds: Float, process: (String) -> String
	) -> Result {
		let live = unconfirmed(segments)
		let decoded = live.map { Decoded(key: Self.comparisonKey($0.text), start: $0.start, end: $0.end) }
		let confirmable = max(0, live.count - holdBack)
		var agreed = 0
		while agreed < confirmable, agreed < previousPass.count, decoded[agreed].key == previousPass[agreed].key,
			abs(decoded[agreed].end - previousPass[agreed].end) <= endTolerance
		{
			agreed += 1
		}

		guard agreed > 0, let through = cutPoint(after: agreed, in: decoded, audioSeconds: audioSeconds) else {
			previousPass = decoded
			return Result(confirmedAddition: "", pendingText: Self.joined(live[...]), confirmedSegmentCount: 0)
		}

		confirmedThroughSeconds = through
		previousPass = Array(decoded.dropFirst(agreed))
		let raw = Self.joined(live.prefix(agreed))
		return Result(
			// A chunk made only of filler words is consumed without typing anything
			confirmedAddition: process(raw), pendingText: Self.joined(live.dropFirst(agreed)),
			confirmedSegmentCount: agreed)
	}

	/// The text of every segment that is not already confirmed, as stopping the session types it.
	func unconfirmedText(_ segments: [LiveSegment]) -> String {
		Self.joined(unconfirmed(segments)[...])
	}

	/// Segments that end inside confirmed audio are stale copies of text already typed.
	private func unconfirmed(_ segments: [LiveSegment]) -> [LiveSegment] {
		segments
			.map { LiveSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end) }
			.filter { !$0.text.isEmpty && $0.end > confirmedThroughSeconds + 0.01 }
	}

	/// Where the next pass starts decoding once the first `agreed` segments are confirmed, or nil
	/// when the two passes' timestamps leave no point between the confirmed and pending speech.
	private func cutPoint(after agreed: Int, in decoded: [Decoded], audioSeconds: Float) -> Float? {
		for index in 0..<agreed {
			let segment = decoded[index]
			guard segment.end > segment.start else { return nil }
			if index > 0, segment.start < decoded[index - 1].end - overlapTolerance { return nil }
		}
		let speechEnd = max(decoded[agreed - 1].end, previousPass[agreed - 1].end)
		let through: Float
		if agreed < decoded.count {
			var limit = min(audioSeconds, decoded[agreed].start)
			if agreed < previousPass.count, previousPass[agreed].key == decoded[agreed].key {
				limit = min(limit, previousPass[agreed].start)
			}
			guard speechEnd <= limit + overlapTolerance else { return nil }
			through = min(speechEnd, limit)
		} else {
			// Nothing of this pass stays pending, so no words lie between its end and the audio's
			through = min(speechEnd, audioSeconds)
		}
		// A confirmation that would not move the decode start would decode the same audio again
		return through > confirmedThroughSeconds ? through : nil
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
