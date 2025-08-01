import SwiftUI

struct LiveTranscriptionView: View {
    @Bindable private var whisperKit = WhisperKitTranscriber.shared
    @State private var lastDisplayedText: String = ""
    
    // Show only the last few words being transcribed
    private var latestWords: String {
        let currentText = whisperKit.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter out WhisperKit's default messages
        if currentText.isEmpty || 
           currentText.contains("Waiting for speech") ||
           currentText.contains("Listening") ||
           currentText.contains("waiting for speech") ||
           currentText.contains("listening") {
            return ""
        }
        
        // Get the last 6-8 words to show recent context
        let words = currentText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        let maxWords = 8
        let recentWords = words.suffix(maxWords)
        
        return recentWords.joined(separator: " ")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if !latestWords.isEmpty {
                // Show only the latest words being transcribed
                Text(latestWords)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2) // Maximum 2 lines
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .animation(.none, value: latestWords) // No animation to prevent rewrites
            } else if whisperKit.isTranscribing {
                // Minimal listening indicator
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }
}