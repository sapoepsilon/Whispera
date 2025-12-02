import SwiftUI

// MARK: - Main Queue View

struct TranscriptionQueueView: View {
	@Bindable var queueManager: TranscriptionQueueManager
	@State private var dragOffset: CGSize = .zero

	var body: some View {
		if queueManager.hasItems {
			VStack(spacing: 0) {
				if queueManager.isExpanded {
					expandedQueueView
				} else {
					collapsedQueueView
				}
			}
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
			.shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
			.transition(
				.asymmetric(
					insertion: .scale(scale: 0.8).combined(with: .opacity),
					removal: .scale(scale: 0.8).combined(with: .opacity)
				))
		}
	}

	// MARK: - Collapsed Queue View (iOS Notification Style)

	private var collapsedQueueView: some View {
		Button(action: {
			queueManager.toggleExpanded()
		}) {
			ZStack {
				// Background cards (stacked effect)
				ForEach(Array(queueManager.items.prefix(3).enumerated()), id: \.element.id) { index, item in
					QueueCardView(item: item, isTopCard: index == 0)
						.offset(x: CGFloat(index) * 2, y: CGFloat(index) * -3)
						.scaleEffect(1.0 - CGFloat(index) * 0.02)
						.opacity(1.0 - CGFloat(index) * 0.15)
						.zIndex(Double(3 - index))
				}

				// Count badge if more than 3 items
				if queueManager.items.count > 3 {
					VStack {
						HStack {
							Spacer()
							CountBadge(count: queueManager.items.count)
								.offset(x: -8, y: 8)
						}
						Spacer()
					}
					.zIndex(10)
				}
			}
			.frame(width: 280, height: 60)
		}
		.buttonStyle(.plain)
		.scaleEffect(dragOffset == .zero ? 1.0 : 0.95)
		.animation(.spring(response: 0.3, dampingFraction: 0.6), value: dragOffset)
	}

	// MARK: - Expanded Queue View

	private var expandedQueueView: some View {
		VStack(spacing: 0) {
			// Header
			queueHeader

			Divider()
				.padding(.horizontal, 16)

			// Queue items list
			ScrollView {
				LazyVStack(spacing: 8) {
					ForEach(queueManager.items) { item in
						ExpandedQueueItemView(item: item, queueManager: queueManager)
							.transition(
								.asymmetric(
									insertion: .move(edge: .trailing).combined(with: .opacity),
									removal: .move(edge: .leading).combined(with: .opacity)
								))
					}
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
			}
			.frame(maxHeight: 300)

			// Footer actions
			if queueManager.hasItems {
				Divider()
					.padding(.horizontal, 16)

				queueFooter
			}
		}
		.frame(width: 320)
	}

	// MARK: - Header

	private var queueHeader: some View {
		HStack(spacing: 12) {
			// Status icon
			ZStack {
				Circle()
					.fill(queueManager.isProcessing ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2))
					.frame(width: 32, height: 32)

				if queueManager.isProcessing {
					ProgressView()
						.scaleEffect(0.8)
						.progressViewStyle(CircularProgressViewStyle(tint: .blue))
				} else {
					Image(systemName: "list.bullet")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.secondary)
				}
			}

			VStack(alignment: .leading, spacing: 2) {
				Text("Transcription Queue")
					.font(.system(.headline, design: .rounded))
					.foregroundColor(.primary)

				Text(queueStatusText)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()

			// Collapse button
			Button(action: {
				queueManager.toggleExpanded()
			}) {
				Image(systemName: "chevron.up")
					.font(.system(size: 12, weight: .medium))
					.foregroundColor(.secondary)
					.contentShape(Circle())
			}
			.buttonStyle(.plain)
			.help("Collapse queue")
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	// MARK: - Footer

	private var queueFooter: some View {
		HStack(spacing: 12) {
			if !queueManager.failedItems.isEmpty {
				Button("Retry Failed") {
					queueManager.retryFailed()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}

			if !queueManager.completedItems.isEmpty {
				Button("Clear Completed") {
					queueManager.clearCompleted()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}

			Spacer()

			if queueManager.isProcessing {
				Button("Cancel All") {
					queueManager.cancelAll()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.foregroundColor(.red)
			}

			Button("Clear All") {
				queueManager.clearAll()
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	// MARK: - Computed Properties

	private var queueStatusText: String {
		if queueManager.isProcessing {
			let current = queueManager.currentItem?.filename ?? "Unknown"
			return "Processing: \(current)"
		} else if queueManager.hasItems {
			let pending = queueManager.pendingItems.count
			let completed = queueManager.completedItems.count
			let failed = queueManager.failedItems.count

			if pending > 0 {
				return "\(pending) pending, \(completed) completed"
			} else if failed > 0 {
				return "\(completed) completed, \(failed) failed"
			} else {
				return "All completed (\(completed))"
			}
		} else {
			return "No items"
		}
	}
}

// MARK: - Queue Card View (Collapsed State)

struct QueueCardView: View {
	let item: TranscriptionQueueItem
	let isTopCard: Bool

	var body: some View {
		HStack(spacing: 12) {
			// Status icon
			ZStack {
				Circle()
					.fill(item.status.color.opacity(0.2))
					.frame(width: 28, height: 28)

				Image(systemName: item.status.icon)
					.font(.system(size: 12, weight: .medium))
					.foregroundColor(item.status.color)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(item.filename)
					.font(.system(.body, design: .rounded, weight: .medium))
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.middle)

				HStack(spacing: 4) {
					Text(item.status.displayName)
						.font(.caption)
						.foregroundColor(.secondary)

					if item.status == .processing {
						Text("• \(Int(item.progress * 100))%")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}

			Spacer()

			// Progress indicator for top card
			if isTopCard && item.status == .processing {
				CircularProgressView(progress: item.progress)
					.frame(width: 20, height: 20)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.secondary.opacity(0.1), lineWidth: 1)
		)
	}
}

// MARK: - Expanded Queue Item View
struct ExpandedQueueItemView: View {
	@Bindable var item: TranscriptionQueueItem
	let queueManager: TranscriptionQueueManager

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 12) {
				// File icon
				Image(systemName: "doc.on.doc")
					.font(.system(size: 20))
					.foregroundColor(.blue)

				VStack(alignment: .leading, spacing: 2) {
					Text(item.filename)
						.font(.system(.body, design: .rounded, weight: .medium))
						.foregroundColor(.primary)
						.lineLimit(1)
						.truncationMode(.middle)

					HStack(spacing: 8) {
						StatusPill(status: item.status)

						if item.status == .processing {
							Text("\(Int(item.progress * 100))%")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				}

				Spacer()

				// Actions
				HStack(spacing: 8) {
					if item.status == .processing || item.status == .pending {
						Button(action: {
							queueManager.cancelItem(item)
						}) {
							Image(systemName: "xmark.circle.fill")
								.font(.system(size: 16))
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
						.help("Cancel")
					}

					if item.status == .completed || item.status == .failed {
						Button(action: {
							queueManager.removeItem(item)
						}) {
							Image(systemName: "trash")
								.font(.system(size: 14))
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
						.help("Remove")
					}
				}
			}

			// Progress bar for processing items
			if item.status == .processing {
				ProgressView(value: item.progress)
					.progressViewStyle(LinearProgressViewStyle(tint: .blue))
					.frame(height: 4)
			}

			// Error message for failed items
			if item.status == .failed, let error = item.error {
				Text(error)
					.font(.caption)
					.foregroundColor(.red)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(Color.secondary.opacity(0.1), lineWidth: 1)
		)
	}
}

// MARK: - Supporting Views
struct CountBadge: View {
	let count: Int

	var body: some View {
		Text("\(count)")
			.font(.system(.caption2, design: .rounded, weight: .bold))
			.foregroundColor(.white)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(.red, in: Capsule())
			.shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
	}
}

struct StatusPill: View {
	let status: QueueItemStatus

	var body: some View {
		Text(status.displayName)
			.font(.system(.caption2, design: .rounded, weight: .medium))
			.foregroundColor(status.color)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(status.color.opacity(0.1), in: Capsule())
	}
}

struct CircularProgressView: View {
	let progress: Double

	var body: some View {
		ZStack {
			Circle()
				.stroke(Color.secondary.opacity(0.2), lineWidth: 2)

			Circle()
				.trim(from: 0, to: progress)
				.stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
				.rotationEffect(.degrees(-90))
				.animation(.easeInOut(duration: 0.5), value: progress)
		}
	}
}

// MARK: - Previews

#Preview {
	let queueManager = TranscriptionQueueManager(
		fileTranscriptionManager: FileTranscriptionManager(),
		networkDownloader: NetworkFileDownloader()
	)

	// Add some mock items
	let mockURLs = [
		URL(fileURLWithPath: "/Users/test/file1.mp3"),
		URL(fileURLWithPath: "/Users/test/file2.m4a"),
		URL(fileURLWithPath: "/Users/test/file3.wav"),
	]

	queueManager.addFiles(mockURLs)
	queueManager.items[0].status = .processing
	queueManager.items[0].progress = 0.6
	queueManager.items[1].status = .completed
	queueManager.items[2].status = .failed
	queueManager.items[2].error = "Unsupported format"

	return VStack {
		Spacer()
		HStack {
			Spacer()
			TranscriptionQueueView(queueManager: queueManager)
				.padding()
		}
	}
	.frame(width: 400, height: 600)
	.background(.gray.opacity(0.1))
}
