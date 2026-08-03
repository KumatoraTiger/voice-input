import Foundation
import Testing

@testable import VoiceInputCore

@Suite("WAV encoder")
struct WAVEncoderTests {
    private func string(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data[range], as: UTF8.self)
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = Array(data[offset..<(offset + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = Array(data[offset..<(offset + 2)])
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    @Test("header fields describe the stream")
    func headerFields() {
        let samples = [Float](repeating: 0, count: 100)
        let data = WAVEncoder.encode(samples: samples, format: .capture)

        #expect(data.count == WAVEncoder.headerByteCount + samples.count * 2)
        #expect(string(data, 0..<4) == "RIFF")
        #expect(string(data, 8..<12) == "WAVE")
        #expect(string(data, 12..<16) == "fmt ")
        #expect(string(data, 36..<40) == "data")

        #expect(uint32(data, at: 4) == UInt32(36 + samples.count * 2))
        #expect(uint32(data, at: 16) == 16)  // PCM subchunk size
        #expect(uint16(data, at: 20) == 1)  // format = PCM
        #expect(uint16(data, at: 22) == 1)  // channels
        #expect(uint32(data, at: 24) == 16_000)  // sample rate
        #expect(uint32(data, at: 28) == 32_000)  // byte rate = 16000 * 1 * 2
        #expect(uint16(data, at: 32) == 2)  // block align
        #expect(uint16(data, at: 34) == 16)  // bits per sample
        #expect(uint32(data, at: 40) == UInt32(samples.count * 2))
    }

    @Test("stereo header reflects the channel count")
    func stereoHeader() {
        let format = AudioStreamFormat(sampleRate: 44_100, channelCount: 2)
        let data = WAVEncoder.encode(samples: [Float](repeating: 0, count: 8), format: format)

        #expect(uint16(data, at: 22) == 2)
        #expect(uint32(data, at: 24) == 44_100)
        #expect(uint32(data, at: 28) == 44_100 * 2 * 2)
        #expect(uint16(data, at: 32) == 4)
    }

    @Test("sample count survives the round trip")
    func sampleCount() {
        for count in [0, 1, 3, 1_024] {
            let data = WAVEncoder.encode(
                samples: [Float](repeating: 0.25, count: count),
                format: .capture
            )
            let declared = uint32(data, at: 40)
            #expect(Int(declared) == count * 2)
            #expect(data.count == WAVEncoder.headerByteCount + count * 2)
        }
    }

    @Test("out-of-range samples clamp instead of wrapping")
    func clamping() {
        #expect(WAVEncoder.pcm16(from: 0) == 0)
        #expect(WAVEncoder.pcm16(from: 1) == 32_767)
        #expect(WAVEncoder.pcm16(from: -1) == -32_767)
        #expect(WAVEncoder.pcm16(from: 12.5) == 32_767)
        #expect(WAVEncoder.pcm16(from: -9.75) == -32_767)
        #expect(WAVEncoder.pcm16(from: .nan) == 0)
        #expect(WAVEncoder.pcm16(from: 0.5) == 16_384)
    }

    @Test("clamped samples are written little endian")
    func littleEndianPayload() {
        let data = WAVEncoder.encode(samples: [1.0, -1.0], format: .capture)
        let payload = Array(data[44...])
        #expect(payload == [0xFF, 0x7F, 0x01, 0x80])
    }
}
