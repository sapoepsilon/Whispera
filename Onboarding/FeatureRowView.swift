//
//  FeatureRowView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//

import SwiftUI

struct FeatureRowView: View {
	let icon: String
	let title: String
	let description: String
	
	var body: some View {
		HStack(spacing: 16) {
			Image(systemName: icon)
				.font(.title2)
				.foregroundColor(.blue)
				.frame(width: 24)
			
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.system(.subheadline, design: .rounded, weight: .medium))
				Text(description)
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			Spacer()
		}
	}
}

