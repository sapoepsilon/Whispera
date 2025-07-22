import SwiftUI

struct DictationView: View {
    private var whisperKit = WhisperKitTranscriber.shared
    
    var body: some View {
        VStack(spacing: 0) {
            if !whisperKit.confirmedText.isEmpty || !whisperKit.pendingText.isEmpty {
                Text(whisperKit.dictationDisplayText)
                    .font(.system(.body, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(.easeInOut(duration: 0.2), value: whisperKit.dictationDisplayText)
            } else if whisperKit.isTranscribing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 4, height: 4)
                        .scaleEffect(whisperKit.isTranscribing ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), 
                                 value: whisperKit.isTranscribing)
                    
                    Text("Listening...")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 2)
    }
}

#Preview {
    DictationView()
        .frame(width: 300)
        .padding()
}