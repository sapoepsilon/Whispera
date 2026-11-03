import Foundation

/// A file as the transcription endpoints want it: bytes, a name, and a type.
///
/// The capture path hands over raw float samples and the upload endpoints want
/// a container, so the conversion lives here rather than in every caller.
public struct AudioPayload: Sendable, Equatable {
	public let data: Data
	public let filename: String
	public let mimetype: String

	public init(data: Data, filename: String, mimetype: String) {
		self.data = data
		self.filename = filename
		self.mimetype = mimetype
	}

	/// Reads a file off disk and infers its type from the extension.
	public static func file(at url: URL) throws -> AudioPayload {
		AudioPayload(
			data: try Data(contentsOf: url),
			filename: url.lastPathComponent,
			mimetype: mimetype(for: url))
	}

	/// Wraps mono float samples in a 16-bit PCM WAV container.
	public static func wav(
		samples: [Float], sampleRate: Int = 16000, filename: String = "dictation.wav"
	) -> AudioPayload {
		AudioPayload(
			data: WAVEncoder.encode(samples: samples, sampleRate: sampleRate),
			filename: filename,
			mimetype: "audio/wav")
	}

	/// Only the containers the transcription endpoints accept. Anything else
	/// reads as WAV, which is what the capture path produces.
	public static func mimetype(for url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "mp3": return "audio/mpeg"
		case "m4a", "mp4": return "audio/mp4"
		case "flac": return "audio/flac"
		case "ogg": return "audio/ogg"
		case "webm": return "audio/webm"
		default: return "audio/wav"
		}
	}
}

/// Float samples to a 16-bit PCM WAV file.
///
/// Free of any actor isolation on purpose: the two-pass finaliser wraps up to
/// ten minutes of audio off the main thread, where a per-sample loop belongs.
public enum WAVEncoder {
	public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
		let bitsPerSample = 16
		let channels = 1
		let byteRate = sampleRate * channels * bitsPerSample / 8
		let blockAlign = channels * bitsPerSample / 8
		let dataBytes = samples.count * bitsPerSample / 8

		var data = Data(capacity: 44 + dataBytes)
		func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func appendUInt32(_ value: Int) {
			withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
		}
		func appendUInt16(_ value: Int) {
			withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
		}

		appendASCII("RIFF")
		appendUInt32(36 + dataBytes)
		appendASCII("WAVE")
		appendASCII("fmt ")
		appendUInt32(16)
		appendUInt16(1)
		appendUInt16(channels)
		appendUInt32(sampleRate)
		appendUInt32(byteRate)
		appendUInt16(blockAlign)
		appendUInt16(bitsPerSample)
		appendASCII("data")
		appendUInt32(dataBytes)

		for sample in samples {
			let clamped = max(-1.0, min(1.0, sample))
			let scaled = Int16(clamped * Float(Int16.max))
			withUnsafeBytes(of: scaled.littleEndian) { data.append(contentsOf: $0) }
		}

		return data
	}
}
