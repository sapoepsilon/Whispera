//
//  GlassBeta.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/26/25.
//
import SwiftUI

struct GlassBetaElement: View {
	// MARK: - Properties
	private let onTap: (() -> Void)?
	private let cornerRadius: CGFloat
	private let elementSize: CGSize

	// MARK: - Animation State
	@State private var shimmerOffset: CGFloat = -100
	@State private var pulseScale: CGFloat = 1.0
	@State private var isPressed: Bool = false

	// MARK: - Constants
	private struct Constants {
		static let shimmerWidth: CGFloat = 15
		static let shimmerOpacity: Double = 0.2
		static let shimmerDuration: Double = 3.0
		static let pulseRange: CGFloat = 1.03
		static let pulseDuration: Double = 3.0
	}

	// MARK: - Initializer
	init(
		onTap: (() -> Void)? = nil,
		cornerRadius: CGFloat = 12,
		size: CGSize = CGSize(width: 40, height: 24)
	) {
		self.onTap = onTap
		self.cornerRadius = cornerRadius
		self.elementSize = size
	}

	var body: some View {
		ZStack {
			glassBackground
			shimmerOverlay
			betaText
		}
		.scaleEffect(pulseScale)
		.scaleEffect(isPressed ? 0.95 : 1.0)
		.animation(.easeInOut(duration: 0.1), value: isPressed)
		.onAppear(perform: startAnimations)
		.onTapGesture(perform: handleTap)
	}
}

// MARK: - View Components
extension GlassBetaElement {
	fileprivate var glassBackground: some View {
		RoundedRectangle(cornerRadius: cornerRadius)
			.fill(.ultraThinMaterial)
			.frame(width: elementSize.width, height: elementSize.height)
			.background(backgroundGradient)
			.overlay(borderGradient)
			.shadow(color: Color.blue.opacity(0.15), radius: 8, x: 0, y: 4)
	}

	fileprivate var backgroundGradient: some View {
		RoundedRectangle(cornerRadius: cornerRadius)
			.fill(
				LinearGradient(
					colors: [
						Color.blue.opacity(0.25),
						Color.purple.opacity(0.15),
						Color.pink.opacity(0.08),
					],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)
			)
			.blur(radius: 0.8)
	}

	fileprivate var borderGradient: some View {
		RoundedRectangle(cornerRadius: cornerRadius)
			.stroke(
				LinearGradient(
					colors: [
						Color.white.opacity(0.5),
						Color.white.opacity(0.08),
					],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				),
				lineWidth: 0.8
			)
	}

	fileprivate var shimmerOverlay: some View {
		RoundedRectangle(cornerRadius: cornerRadius)
			.fill(
				LinearGradient(
					colors: [
						Color.clear,
						Color.white.opacity(Constants.shimmerOpacity),
						Color.clear,
					],
					startPoint: .leading,
					endPoint: .trailing
				)
			)
			.frame(width: Constants.shimmerWidth, height: elementSize.height)
			.offset(x: shimmerOffset)
			.mask(
				RoundedRectangle(cornerRadius: cornerRadius)
					.frame(width: elementSize.width, height: elementSize.height)
			)
	}

	fileprivate var betaText: some View {
		Text("BETA")
			.font(.system(size: 9, weight: .bold, design: .default))
			.foregroundColor(.orange)
			.shadow(color: Color.black.opacity(0.3), radius: 0.5, x: 0, y: 0.5)
	}
}

// MARK: - Animation Methods
extension GlassBetaElement {
	fileprivate func startAnimations() {
		startShimmerAnimation()
		startPulseAnimation()
	}

	fileprivate func startShimmerAnimation() {
		withAnimation(
			Animation.linear(duration: Constants.shimmerDuration)
				.repeatForever(autoreverses: false)
		) {
			shimmerOffset = elementSize.width + Constants.shimmerWidth
		}
	}

	fileprivate func startPulseAnimation() {
		withAnimation(
			Animation.easeInOut(duration: Constants.pulseDuration)
				.repeatForever(autoreverses: true)
		) {
			pulseScale = Constants.pulseRange
		}
	}

	fileprivate func handleTap() {
		withAnimation(.easeInOut(duration: 0.1)) {
			isPressed = true
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			withAnimation(.easeInOut(duration: 0.1)) {
				isPressed = false
			}
		}

		onTap?()
	}
}
