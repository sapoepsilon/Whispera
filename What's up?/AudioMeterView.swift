//
//  AudioMeterView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 10/18/25.
//

import SwiftUI

struct AudioMeterView: View {
	let levels: [Float]
	@AppStorage("audioMeterBarWidth") private var barWidth = 3.0
	@AppStorage("audioMeterBarSpacing") private var barSpacing = 3.0
	@AppStorage("audioMeterMaxHeight") private var maxHeight = 50.0
	@AppStorage("audioMeterMinHeight") private var minHeight = 3.0

	var body: some View {
		HStack(spacing: barSpacing) {
			ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
				RoundedRectangle(cornerRadius: barWidth / 2)
					.fill(
						LinearGradient(
							colors: [
								Color.blue.opacity(0.9),
								Color.blue.opacity(0.6),
							],
							startPoint: .bottom,
							endPoint: .top
						)
					)
					.frame(
						width: barWidth,
						height: calculateBarHeight(for: level)
					)
					.animation(.spring(response: 0.15, dampingFraction: 0.6), value: level)
			}
		}
	}

	private func calculateBarHeight(for level: Float) -> CGFloat {
		let height = minHeight + (maxHeight - minHeight) * CGFloat(level)
		return max(minHeight, min(maxHeight, height))
	}
}
