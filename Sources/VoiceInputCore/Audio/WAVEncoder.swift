import Foundation

/// Encodes float PCM into a 16-bit little-endian RIFF/WAVE container.
///
/// Written by hand rather than with AVFoundation: `VoiceInputCore` must stay
/// free of platform frameworks so it remains unit-testable.
public enum WAVEncoder {
    /// Bytes of the canonical 44-byte RIFF header this encoder emits.
    public static let headerByteCount = 44
    public static let bitsPerSample = 16

    /// - Parameters:
    ///   - samples: Interleaved 32-bit float samples. Values outside `[-1, 1]`
    ///     are clamped rather than allowed to wrap around.
    ///   - format: Sample rate / channel count written into the `fmt ` chunk.
    public static func encode(samples: [Float], format: AudioStreamFormat) -> Data {
        let channels = max(1, format.channelCount)
        let sampleRate = max(1, Int(format.sampleRate.rounded()))
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = samples.count * bytesPerSample

        var data = Data(capacity: headerByteCount + dataByteCount)

        // RIFF chunk
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))  // PCM subchunk size
        data.appendLE(UInt16(1))  // format = PCM
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * channels * bytesPerSample))  // byte rate
        data.appendLE(UInt16(channels * bytesPerSample))  // block align
        data.appendLE(UInt16(bitsPerSample))

        // data chunk
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(dataByteCount))
        for sample in samples {
            data.appendLE(pcm16(from: sample))
        }
        return data
    }

    /// Clamps to `[-1, 1]` before scaling so a hot signal saturates instead of
    /// overflowing into the opposite polarity.
    static func pcm16(from sample: Float) -> Int16 {
        if sample.isNaN { return 0 }
        let clamped = min(max(sample, -1), 1)
        return Int16((clamped * 32_767).rounded())
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    fileprivate mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    fileprivate mutating func appendLE(_ value: Int16) {
        appendLE(UInt16(bitPattern: value))
    }
}
