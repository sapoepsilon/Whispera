//
//  OnboardingProgressView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//

import SwiftUI

struct OnboardingProgressView: View {
	let currentStep: Int
	let totalSteps: Int

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 8) {
				ForEach(0..<totalSteps, id: \.self) { step in
					Circle()
						.fill(step <= currentStep ? .blue : .gray.opacity(0.3))
						.frame(width: 8, height: 8)
						.animation(.easeInOut(duration: 0.3), value: currentStep)
				}
			}

			Text("Step \(currentStep + 1) of \(totalSteps)")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}
}
