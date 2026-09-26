import SwiftUI

struct SlideTransition: Transition {
	let direction: Int

	func body(content: Content, phase: TransitionPhase) -> some View {
		content
			.offset(x: xOffset(for: phase))
			.opacity(phase.isIdentity ? 1.0 : 0.0)
	}

	private func xOffset(for phase: TransitionPhase) -> CGFloat {
		switch phase {
		case .willAppear: return CGFloat(direction) * 50
		case .identity: return 0
		case .didDisappear: return CGFloat(-direction) * 50
		}
	}
}
