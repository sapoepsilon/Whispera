import Foundation

extension TranscriptTextProcessor {
	private struct MatchKey {
		let wordIndex: Int
		let key: String
	}

	private static let maxNgramLength = 4
	private static let maxCandidateLength = 50

	static func applyCustomWords(_ text: String, customWords: [String], threshold: Double) -> String {
		let words = customWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
			!$0.isEmpty
		}
		guard !words.isEmpty else { return text }

		let keys = words.enumerated().flatMap { index, word in matchKeys(for: word, index: index) }
		guard !keys.isEmpty else { return text }

		let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		var output: [String] = []
		var i = 0

		while i < tokens.count {
			var best: (length: Int, replacement: String, score: Double)?

			for n in 1...maxNgramLength where i + n <= tokens.count {
				let ngram = Array(tokens[i..<(i + n)])
				// Never merge across punctuation: in "Charge B, che" the comma closes the candidate.
				if ngram.dropLast().contains(where: { !extractPunctuation($0).suffix.isEmpty }) {
					continue
				}
				let candidate = ngram.map(matchKey).joined()
				guard let match = bestMatch(for: candidate, words: words, keys: keys, threshold: threshold)
				else { continue }
				// Iterating shortest first and requiring a strictly better score means ties keep the
				// shorter n-gram, so an ordinary trailing word is not swallowed.
				if best == nil || match.score < best!.score {
					best = (n, match.word, match.score)
				}
			}

			if let best {
				let first = tokens[i]
				let last = tokens[i + best.length - 1]
				let prefix = extractPunctuation(first).prefix
				let suffix = extractPunctuation(last).suffix
				let core = String(first.dropFirst(prefix.count))
				output.append(
					prefix + preserveCasePattern(original: core, replacement: best.replacement) + suffix)
				i += best.length
			} else {
				output.append(tokens[i])
				i += 1
			}
		}

		return output.joined(separator: " ")
	}

	private static func matchKeys(for word: String, index: Int) -> [MatchKey] {
		var keys: [MatchKey] = []
		let primary = matchKey(word)
		// Tokenization and Soundex are only meaningful for ASCII terms; CJK words are skipped.
		if isSupportedFuzzyKey(primary) {
			keys.append(MatchKey(wordIndex: index, key: primary))
		}
		if word.contains("&") {
			let expanded = matchKey(word.replacingOccurrences(of: "&", with: " and "))
			if isSupportedFuzzyKey(expanded) && expanded != primary {
				keys.append(MatchKey(wordIndex: index, key: expanded))
			}
		}
		return keys
	}

	private static func bestMatch(
		for candidate: String, words: [String], keys: [MatchKey], threshold: Double
	) -> (word: String, score: Double)? {
		guard isSupportedFuzzyKey(candidate), candidate.count <= maxCandidateLength else { return nil }

		var bestWord: String?
		var bestScore = Double.greatestFiniteMagnitude
		let candidateSoundex = supportsSoundex(candidate) ? soundex(candidate) : nil

		for key in keys {
			let candidateLength = candidate.count
			let keyLength = key.key.count
			let maxLength = Double(max(candidateLength, keyLength))
			let lengthDifference = Double(abs(candidateLength - keyLength))
			if lengthDifference > max(maxLength * 0.25, 2) {
				continue
			}

			let distance = Double(levenshtein(candidate, key.key))
			let editScore = maxLength > 0 ? distance / maxLength : 1

			let phoneticMatch =
				candidateSoundex != nil && supportsSoundex(key.key) && candidateSoundex == soundex(key.key)
			let score = phoneticMatch ? editScore * 0.3 : editScore

			if score < threshold && score < bestScore {
				bestWord = words[key.wordIndex]
				bestScore = score
			}
		}

		return bestWord.map { ($0, bestScore) }
	}

	static func matchKey(_ word: String) -> String {
		String(word.filter { $0.isLetter || $0.isNumber }.lowercased())
	}

	private static func isSupportedFuzzyKey(_ key: String) -> Bool {
		!key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
	}

	private static func supportsSoundex(_ key: String) -> Bool {
		!key.isEmpty && key.allSatisfy { $0.isASCII && $0.isLetter }
	}

	static func preserveCasePattern(original: String, replacement: String) -> String {
		let letters = original.filter { $0.isLetter }
		if !letters.isEmpty && letters.allSatisfy({ $0.isUppercase }) {
			return replacement.uppercased()
		}
		if let first = original.first, first.isUppercase, let replacementFirst = replacement.first {
			return replacementFirst.uppercased() + replacement.dropFirst()
		}
		return replacement
	}

	static func extractPunctuation(_ word: String) -> (prefix: String, suffix: String) {
		let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
		guard let firstIndex = word.firstIndex(where: isWordCharacter),
			let lastIndex = word.lastIndex(where: isWordCharacter)
		else {
			return (word, word)
		}
		return (String(word[..<firstIndex]), String(word[word.index(after: lastIndex)...]))
	}

	static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
		let a = Array(lhs)
		let b = Array(rhs)
		if a.isEmpty { return b.count }
		if b.isEmpty { return a.count }

		var previous = Array(0...b.count)
		var current = [Int](repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			current[0] = i
			for j in 1...b.count {
				let cost = a[i - 1] == b[j - 1] ? 0 : 1
				current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			}
			swap(&previous, &current)
		}
		return previous[b.count]
	}

	/// American Soundex: first letter plus three consonant-class digits.
	static func soundex(_ word: String) -> String? {
		let letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
		guard let first = letters.first else { return nil }

		func digit(_ c: Character) -> Character? {
			switch c {
			case "b", "f", "p", "v": return "1"
			case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
			case "d", "t": return "3"
			case "l": return "4"
			case "m", "n": return "5"
			case "r": return "6"
			default: return nil
			}
		}

		var code = String(first).uppercased()
		var lastDigit = digit(first)
		for c in letters.dropFirst() {
			let d = digit(c)
			if let d, d != lastDigit {
				code.append(d)
				if code.count == 4 { break }
			}
			// H and W do not separate letters with the same code; vowels do.
			if c != "h" && c != "w" {
				lastDigit = d
			}
		}
		return code.padding(toLength: 4, withPad: "0", startingAt: 0)
	}
}
