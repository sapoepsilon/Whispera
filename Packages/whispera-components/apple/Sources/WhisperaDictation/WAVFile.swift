import Foundation

/// A minimal RIFF/WAVE reader: enough to get PCM out of a file, and no more.
///
/// It walks the chunk list rather than assuming the 44-byte canonical header, and
/// that is not pedantry. The speech fixture this package was developed against
/// carries an `FLLR` padding chunk of 4044 bytes between `fmt ` and `data` — an
/// alignment chunk Apple's encoders like to insert. Skipping a fixed 44 bytes on
/// that file hands 4 kB of zeros and a shifted stream to the engine, which
/// transcribes it as silence or garbage with no error anywhere.
public struct WAVFile: Sendable {
	public let format: DictationAudioFormat
	/// The raw contents of the `data` chunk, still in the file's own format.
	public let pcm: Data

	public var duration: Double {
		let frames = pcm.count / max(1, format.bytesPerFrame)
		return Double(frames) / Double(format.sampleRate)
	}

	public enum ReadError: Error, LocalizedError, Equatable {
		case notRIFF
		case notWAVE
		case truncated(String)
		case missingChunk(String)
		case unsupportedFormat(code: UInt16)
		case unsupportedBitDepth(Int)

		public var errorDescription: String? {
			switch self {
			case .notRIFF: return "not a RIFF file"
			case .notWAVE: return "RIFF container is not WAVE"
			case .truncated(let what): return "truncated WAV: ran out of bytes reading \(what)"
			case .missingChunk(let name): return "WAV has no '\(name)' chunk"
			case .unsupportedFormat(let code):
				return
					"WAV audio format \(code) is not supported; only PCM (1) and IEEE float (3) are"
			case .unsupportedBitDepth(let bits):
				return "WAV bit depth \(bits) is not supported; only 16-bit PCM and 32-bit float are"
			}
		}
	}

	public init(contentsOf url: URL) throws {
		// Mapped rather than read: the demo streams a five-second file today, but a
		// host handing over an hour of audio should not need the whole thing resident.
		try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
	}

	public init(data: Data) throws {
		guard data.count >= 12 else { throw ReadError.truncated("the RIFF header") }
		guard data.readASCII(at: 0, count: 4) == "RIFF" else { throw ReadError.notRIFF }
		guard data.readASCII(at: 8, count: 4) == "WAVE" else { throw ReadError.notWAVE }

		var formatCode: UInt16?
		var channels = 0
		var sampleRate = 0
		var bitsPerSample = 0
		var pcmData: Data?

		// Chunks are id(4) + size(4) + payload, payload padded to even length.
		var offset = 12
		while offset + 8 <= data.count {
			let id = data.readASCII(at: offset, count: 4)
			let size = Int(data.readUInt32LE(at: offset + 4))
			let body = offset + 8
			// A size that overruns the file is corruption, not a chunk to skip:
			// trusting it would read past the end.
			guard size >= 0, body + size <= data.count else {
				throw ReadError.truncated("chunk '\(id)'")
			}

			switch id {
			case "fmt ":
				guard size >= 16 else { throw ReadError.truncated("the 'fmt ' chunk") }
				formatCode = data.readUInt16LE(at: body)
				channels = Int(data.readUInt16LE(at: body + 2))
				sampleRate = Int(data.readUInt32LE(at: body + 4))
				bitsPerSample = Int(data.readUInt16LE(at: body + 14))
			case "data":
				pcmData = data.subdata(in: body..<(body + size))
			default:
				// FLLR, LIST, fact, id3 … all irrelevant here, all skipped by size.
				break
			}

			offset = body + size + (size % 2)  // the pad byte is not counted by size
		}

		guard let formatCode else { throw ReadError.missingChunk("fmt ") }
		guard let pcmData else { throw ReadError.missingChunk("data") }

		// 1 = PCM integer, 3 = IEEE float. 0xFFFE (extensible) carries the real code
		// in a sub-format GUID; nothing in this project produces it, so it is
		// rejected loudly rather than guessed at.
		let encoding: DictationAudioFormat.Encoding
		switch (formatCode, bitsPerSample) {
		case (1, 16): encoding = .pcm16
		case (3, 32): encoding = .float32
		case (1, _), (3, _): throw ReadError.unsupportedBitDepth(bitsPerSample)
		default: throw ReadError.unsupportedFormat(code: formatCode)
		}

		self.format = DictationAudioFormat(
			sampleRate: sampleRate, channels: max(1, channels), encoding: encoding)
		self.pcm = pcmData
	}
}

extension Data {
	fileprivate func readASCII(at offset: Int, count: Int) -> String {
		guard offset + count <= self.count else { return "" }
		return String(decoding: self[startIndex + offset..<startIndex + offset + count], as: UTF8.self)
	}

	fileprivate func readUInt16LE(at offset: Int) -> UInt16 {
		withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
	}

	fileprivate func readUInt32LE(at offset: Int) -> UInt32 {
		withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
	}
}
