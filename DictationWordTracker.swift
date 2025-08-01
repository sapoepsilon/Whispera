import Foundation
import AppKit

func simulateKeyPressWithModifier(keyCode: CGKeyCode, modifier: CGEventFlags) async {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    
    keyDownEvent?.flags = modifier
    keyUpEvent?.flags = modifier
    
    keyDownEvent?.post(tap: .cghidEventTap)
    keyUpEvent?.post(tap: .cghidEventTap)
}

struct TrackedWord: Equatable {
    let text: String
    let relativePosition: Int
    let timestamp: Date
}

enum CorrectionCommand {
    case replaceLastWords(count: Int, with: String)
    case selectAllDictated
    case undoAndCorrect(with: String)
    case replaceWord(target: String, with: String)
}

@MainActor
@Observable class DictationWordTracker {
	private(set) var trackedWords: [TrackedWord] = []
	private(set) var totalLength: Int = 0
	private(set) var sessionStartPosition: Int = 0
	private var transcriber: WhisperKitTranscriber = WhisperKitTranscriber.shared
    private var isTrackingEnabled = true
	
	init() {
		setupTranscriberCallback()
	}
	
	private func setupTranscriberCallback() {
		transcriber.onConfirmedTextChange = { [weak self] newConfirmedText in
			self?.handleConfirmedTextChange(newConfirmedText)
		}
	}
	
	private func handleConfirmedTextChange(_ fullText: String) {
		guard isTrackingEnabled else { return }
		let newContent = extractNewContent(from: fullText)
		if !newContent.isEmpty {
			trackWords(from: newContent)
			Task {
				await pasteText(newContent)
			}
		} else {
			print("📝 No new content to paste")
		}
	}
	
	
	private func extractNewContent(from fullText: String) -> String {
		print("full text: \(fullText) in extractNewContent")
		let trackedText = trackedWords.map(\.text).joined(separator: " ")
		
		if trackedText.isEmpty {
			return fullText
		}
		
			if fullText.hasPrefix(trackedText) {
			let newContent = String(fullText.dropFirst(trackedText.count))
			if newContent.hasPrefix(" ") {
				return String(newContent.dropFirst())
			}
			return newContent
		}
		
		// WhisperKit sometimes returns slightly different text for the same audio
		if fullText.count > trackedText.count {
			let trackedCount = trackedText.count
			let commonPrefixLength = min(trackedCount, fullText.count / 2)
			
			if fullText.prefix(commonPrefixLength) == trackedText.prefix(commonPrefixLength) {
				let newContent = String(fullText.dropFirst(trackedCount))
				if newContent.hasPrefix(" ") {
					return String(newContent.dropFirst())
				}
				return newContent
			}
		}
		
		AppLogger.shared.liveTranscriber.log(
			"⚠️ Text filtering logic failed, returning the confirmed text by Whisperkit."
		)
		return fullText // TODO: Examine more, this is more of a fallback if the above logic fails. Do not remove the todo, and don't impelement it the original author will work on it on their own pace
	}

    func startNewSession() {
        trackedWords.removeAll()
        totalLength = 0
        sessionStartPosition = 0
        isTrackingEnabled = true
    }
    
    func endSession() {
        isTrackingEnabled = false
		AppLogger.shared.liveTranscriber.debug(
			"📝 Ended dictation word tracking session - tracked \(self.trackedWords.count) words"
		)
    }
	private func trackWords(from text: String) {
		guard isTrackingEnabled else { return }
		
		// Ignore marker // TODO: create a dictionary for words. If you are reading this do not implement it, I will do it myself
//		if text.contains("[BLANK_AUDIO]") {
//			print("📝 Ignoring [BLANK_AUDIO] marker")
//			return
//		}
		
		let words = text.split(separator: " ").map(String.init)
		
		for word in words {
			let trackedWord = TrackedWord(
				text: word,
				relativePosition: totalLength,
				timestamp: Date()
			)
			trackedWords.append(trackedWord)
			
			totalLength += word.count
			if word != words.last {
				totalLength += 1 // Add space
			}
		}
		
		print("📝 Tracked \(words.count) new words: \(words.joined(separator: " "))")
		print("📝 Total length now: \(totalLength), Total words: \(trackedWords.count)")
	}
	
	func trackPastedText(_ text: String) {
		trackWords(from: text)
	}
    
    func updateAfterCorrection(removedWordCount: Int, newText: String) {
        guard isTrackingEnabled && removedWordCount <= trackedWords.count else { return }
        
        let removedWords = Array(trackedWords.suffix(removedWordCount))
        trackedWords.removeLast(removedWordCount)
        
        let removedLength = removedWords.reduce(0) { total, word in
            total + word.text.count + (word != removedWords.last ? 1 : 0)
        }
        
        totalLength -= removedLength
        
        trackWords(from: newText)
        
        print("📝 Updated tracking after correction: removed \(removedWordCount) words, added '\(newText)'")
    }
    
    func getLastNWords(_ count: Int) -> [TrackedWord] {
        guard count > 0 && count <= trackedWords.count else { return [] }
        return Array(trackedWords.suffix(count))
    }
    
    func calculateSelectionRange(forLastWords count: Int) -> (start: Int, length: Int)? {
        let lastWords = getLastNWords(count)
        guard !lastWords.isEmpty else { return nil }
        
        let firstWord = lastWords.first!
        let totalWordsLength = lastWords.reduce(0) { total, word in
            total + word.text.count
        }
        let spacesCount = max(0, lastWords.count - 1)
        
        return (
            start: firstWord.relativePosition,
            length: totalWordsLength + spacesCount
        )
    }
    
    func processCorrectionCommand(_ command: String) -> CorrectionCommand? {
        let lowercased = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // "replace last N words with X"
        if let match = lowercased.range(of: #"replace last (\d+) words? with (.+)"#, options: .regularExpression) {
            let matchString = String(lowercased[match])
            let components = matchString.components(separatedBy: " with ")
            if components.count == 2,
               let numberPart = components[0].components(separatedBy: " ").last,
               let count = Int(numberPart) {
                return .replaceLastWords(count: count, with: components[1])
            }
        }
        
        if lowercased.hasPrefix("correct that to ") {
            let correction = String(lowercased.dropFirst("correct that to ".count))
            return .undoAndCorrect(with: correction)
        }
        
        if lowercased.contains("select all dictated") {
            return .selectAllDictated
        }
        
        if let match = lowercased.range(of: #"replace (.+) with (.+)"#, options: .regularExpression) {
            let matchString = String(lowercased[match])
            let components = matchString.components(separatedBy: " with ")
            if components.count == 2 {
                let target = components[0].replacingOccurrences(of: "replace ", with: "")
                return .replaceWord(target: target, with: components[1])
            }
        }
        
        return nil
    }
    
    func executeCorrection(_ command: CorrectionCommand) async {
        switch command {
        case .replaceLastWords(let count, let newText):
            await replaceLastWords(count: count, with: newText)
            
        case .selectAllDictated:
            await selectAllDictatedText()
            
        case .undoAndCorrect(let newText):
            await undoAndCorrect(with: newText)
            
        case .replaceWord(let target, let newText):
            await replaceSpecificWord(target: target, with: newText)
        }
    }
    
    private func replaceLastWords(count: Int, with newText: String) async {
        guard let range = calculateSelectionRange(forLastWords: count) else {
            print("❌ Cannot calculate range for last \(count) words")
            return
        }
        print("📝 Attempting to replace last \(count) words with '\(newText)'")
        await selectTextRange(charactersBack: range.length)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await pasteText(newText)
        updateAfterCorrection(removedWordCount: count, newText: newText)
    }
    
    private func selectAllDictatedText() async {
        guard totalLength > 0 else {
            print("❌ No dictated text to select")
            return
        }
        print("📝 Selecting all dictated text (\(totalLength) characters)")
        await selectTextRange(charactersBack: totalLength)
    }
    
    private func undoAndCorrect(with newText: String) async {
        print("📝 Undoing last paste and correcting with '\(newText)'")
        
		await simulateKeyPressWithModifier(
			keyCode: 0x06,
			modifier: .maskCommand
		)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await pasteText(newText)
	
        if let lastWord = trackedWords.last {
            let wordsInLastBatch = trackedWords.filter { word in
                word.timestamp.timeIntervalSince(lastWord.timestamp) < 1.0
            }.count
            
            updateAfterCorrection(removedWordCount: wordsInLastBatch, newText: newText)
        }
    }
    
    private func replaceSpecificWord(target: String, with newText: String) async {
        guard let wordIndex = trackedWords.lastIndex(where: { $0.text.lowercased() == target.lowercased() }) else {
            print("❌ Could not find word '\(target)' in tracked words")
            return
        }
        
        let targetWord = trackedWords[wordIndex]
        let wordsAfterTarget = trackedWords.count - wordIndex - 1
        
        print("📝 Replacing '\(target)' with '\(newText)' (\(wordsAfterTarget) words after target)")
        
        let charactersToTarget = trackedWords.suffix(wordsAfterTarget + 1).reduce(0) { total, word in
            total + word.text.count + 1
        } - 1
        
        await selectTextRange(charactersBack: charactersToTarget)
        
        await extendSelectionForward(characters: targetWord.text.count)
        
        await pasteText(newText)
        
        trackedWords[wordIndex] = TrackedWord(
            text: newText,
            relativePosition: targetWord.relativePosition,
            timestamp: Date()
        )
    }
    
    private func selectTextRange(charactersBack: Int) async {
        for _ in 0..<charactersBack {
			await simulateKeyPressWithModifier(
				keyCode: 0x7B,
				modifier: [.maskShift]
			)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    
    private func extendSelectionForward(characters: Int) async {
        for _ in 0..<characters {
			await simulateKeyPressWithModifier(
				keyCode: 0x7C,
				modifier: [.maskShift]
			)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    
    private func pasteText(_ text: String) async {
		let addSpaceToText = " " + text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
		pasteboard.setString(addSpaceToText, forType: .string)
		
		await simulateKeyPressWithModifier(
			keyCode: 0x09,
			modifier: .maskCommand
		)
		
    }

    func printTrackingState() {
        print("📊 Dictation Tracking State:")
        print("   Enabled: \(isTrackingEnabled)")
        print("   Words tracked: \(trackedWords.count)")
        print("   Total length: \(totalLength)")
        print("   Words: \(trackedWords.map(\.text).joined(separator: " "))")
    }
    
    func getTrackingStats() -> [String: Any] {
        return [
            "enabled": isTrackingEnabled,
            "wordCount": trackedWords.count,
            "totalLength": totalLength,
            "words": trackedWords.map(\.text)
        ]
    }
}
