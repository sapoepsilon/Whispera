// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Testing

@testable import Whispera

/// Pins the geometry the live-words HUD uses to sit above the listening pill —
/// see WHI-58. Pure functions of screen + pill geometry, so the coordination
/// rule is covered without standing up any NSWindow.
struct PillAnchorTests {
	private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

	@Test func sitsDirectlyAboveThePillWithTheDesignLanguageGap() {
		let pill = NSRect(x: 600, y: 80, width: 200, height: 50)
		let size = CGSize(width: 240, height: 36)

		let frame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: pill)

		#expect(frame.origin.y == pill.maxY + PillAnchor.gap)
		#expect(PillAnchor.gap == PillMetrics.controlsGap, "one shared gap, not a second invented number")
	}

	@Test func neverOverlapsThePill() {
		let pill = NSRect(x: 600, y: 80, width: 200, height: 50)
		let size = CGSize(width: 240, height: 200)  // a tall, many-line surface

		let frame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: pill)

		#expect(frame.minY >= pill.maxY, "the surface's own bottom edge must never dip into the pill")
	}

	@Test func isHorizontallyCenteredOnThePill() {
		let pill = NSRect(x: 600, y: 80, width: 200, height: 50)
		let size = CGSize(width: 240, height: 36)

		let frame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: pill)

		#expect(frame.midX == pill.midX)
	}

	/// The requirement is that words "grow upward": the pill's bottom-adjacent
	/// edge is the anchor, so taller content must extend the frame's top
	/// without moving its bottom.
	@Test func growingContentExtendsUpwardNotDownward() {
		let pill = NSRect(x: 600, y: 80, width: 200, height: 50)
		let shortFrame = PillAnchor.frame(
			for: CGSize(width: 240, height: 36), screenFrame: screen, pillFrame: pill)
		let tallFrame = PillAnchor.frame(
			for: CGSize(width: 240, height: 120), screenFrame: screen, pillFrame: pill)

		#expect(shortFrame.origin.y == tallFrame.origin.y, "the bottom edge stays put as height grows")
		#expect(tallFrame.maxY > shortFrame.maxY, "growth reads as extending upward")
	}

	@Test func followsThePillHorizontallyWhenItMoves() {
		let size = CGSize(width: 240, height: 36)
		let leftPill = NSRect(x: 100, y: 80, width: 200, height: 50)
		let rightPill = NSRect(x: 900, y: 80, width: 200, height: 50)

		let leftFrame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: leftPill)
		let rightFrame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: rightPill)

		#expect(leftFrame.midX == leftPill.midX)
		#expect(rightFrame.midX == rightPill.midX)
		#expect(leftFrame.origin.x != rightFrame.origin.x)
	}

	/// With no pill on screen — a transient racing the pill's own visibility
	/// notification, or shown before the pill ever appears — the surface still
	/// lands at the pill's own bottom-center resting spot, never at some other
	/// improvised location.
	@Test func fallsBackToThePillsRestingSpotWithNoPillOnScreen() {
		let size = CGSize(width: 240, height: 36)

		let frame = PillAnchor.frame(for: size, screenFrame: screen, pillFrame: nil)

		let expectedY = screen.origin.y + screen.height * PillMetrics.bottomAnchorFraction
		let expectedX = screen.origin.x + (screen.width - size.width) / 2
		#expect(frame.origin.y == expectedY)
		#expect(frame.origin.x == expectedX)
	}
}

/// `PillAnchorProvider` is a one-writer, many-reader broadcast of the pill's
/// frame. `ListeningWindow` is the only writer in the app; this pins the
/// contract every reader (today, `LiveTranscriptionWindow`) depends on.
@MainActor
struct PillAnchorProviderTests {
	@Test func startsWithNoPillPublished() {
		let provider = PillAnchorProvider()

		#expect(provider.pillFrame == nil)
	}

	@Test func publishesTheFrameItIsGiven() {
		let provider = PillAnchorProvider()
		let frame = NSRect(x: 10, y: 20, width: 30, height: 40)

		provider.publish(frame)

		#expect(provider.pillFrame == frame)
	}

	@Test func publishingNilClearsIt() {
		let provider = PillAnchorProvider()
		provider.publish(NSRect(x: 10, y: 20, width: 30, height: 40))

		provider.publish(nil)

		#expect(provider.pillFrame == nil)
	}
}
