import Foundation

enum WAVFileWriter {
	/// Encodes mono float samples as 16-bit little-endian PCM, the format WhisperKit and
	/// AVFoundation both read back without conversion surprises.
	static func data(samples: [Float], sampleRate: Int) -> Data {
		let channels = 1
		let bitsPerSample = 16
		let bytesPerSample = bitsPerSample / 8
		let dataSize = samples.count * bytesPerSample * channels
		let byteRate = sampleRate * channels * bytesPerSample
		let blockAlign = channels * bytesPerSample

		var data = Data(capacity: 44 + dataSize)
		data.append(contentsOf: Array("RIFF".utf8))
		data.appendLittleEndian(UInt32(36 + dataSize))
		data.append(contentsOf: Array("WAVE".utf8))
		data.append(contentsOf: Array("fmt ".utf8))
		data.appendLittleEndian(UInt32(16))
		data.appendLittleEndian(UInt16(1))
		data.appendLittleEndian(UInt16(channels))
		data.appendLittleEndian(UInt32(sampleRate))
		data.appendLittleEndian(UInt32(byteRate))
		data.appendLittleEndian(UInt16(blockAlign))
		data.appendLittleEndian(UInt16(bitsPerSample))
		data.append(contentsOf: Array("data".utf8))
		data.appendLittleEndian(UInt32(dataSize))

		var pcm = [Int16](repeating: 0, count: samples.count)
		for (index, sample) in samples.enumerated() {
			let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
			pcm[index] = Int16(clamped * Float(Int16.max)).littleEndian
		}
		pcm.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
		return data
	}

	static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
		try data(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
	}
}

extension Data {
	fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
		var littleEndian = value.littleEndian
		Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
	}
}
