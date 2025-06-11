import SwiftUI

struct DebugConfirmedView: View {
    @Bindable private var whisperKit = WhisperKitTranscriber.shared
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
                Text("Confirmed Segments (Debug)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            VStack(spacing: 8) {
                // Confirmed text section
                if !whisperKit.confirmedText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confirmed:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(whisperKit.confirmedText)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.green.opacity(0.3), lineWidth: 1)
                            )
                            .animation(.easeInOut(duration: 0.2), value: whisperKit.confirmedText)
                    }
                }
                
                // Pending text section for debug comparison
                if !whisperKit.pendingText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pending:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(whisperKit.pendingText)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.orange.opacity(0.3), lineWidth: 1)
                            )
                            .animation(.easeInOut(duration: 0.2), value: whisperKit.pendingText)
                    }
                }
                
                // Latest word highlight
                if !whisperKit.latestWord.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Latest Word:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(whisperKit.latestWord)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.blue.opacity(0.3), lineWidth: 1)
                            )
                            .animation(.easeInOut(duration: 0.2), value: whisperKit.latestWord)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .frame(maxWidth: 500)
    }
}