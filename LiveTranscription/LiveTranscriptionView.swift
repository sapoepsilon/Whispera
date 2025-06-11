import SwiftUI

struct LiveTranscriptionView: View {
    @Bindable private var whisperKit = WhisperKitTranscriber.shared
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                    .font(.system(size: 16))
                Text("Live Transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            if !whisperKit.pendingText.isEmpty {
                HStack {
                    Text(whisperKit.displayText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .animation(.easeInOut(duration: 0.2), value: whisperKit.pendingText)
                    Spacer()
                }
            } else {
                HStack {
                    Text("Listening...")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .frame(maxWidth: 400)
    }
}