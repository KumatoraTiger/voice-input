import Foundation

/// Description of a PCM stream flowing through the app.
///
/// The whole pipeline standardises on mono 32-bit float PCM because it is the
/// lowest common denominator between `SFSpeechRecognizer`, `SpeechAnalyzer` and
/// the cloud STT endpoints (which want a WAV/PCM upload).
public struct AudioStreamFormat: Sendable, Equatable, Codable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// The capture format used by `AudioCapturing` implementations.
    ///
    /// 16 kHz mono is what Apple's speech stack downsamples to internally and is
    /// also the cheapest thing to upload to a cloud transcription endpoint.
    public static let capture = AudioStreamFormat(sampleRate: 16_000, channelCount: 1)
}

/// A chunk of captured audio.
public struct AudioBuffer: Sendable {
    /// Interleaved 32-bit float samples in `[-1, 1]`.
    public var samples: [Float]
    public var format: AudioStreamFormat

    public init(samples: [Float], format: AudioStreamFormat) {
        self.samples = samples
        self.format = format
    }

    public var duration: TimeInterval {
        guard format.sampleRate > 0, format.channelCount > 0 else { return 0 }
        return Double(samples.count) / (format.sampleRate * Double(format.channelCount))
    }
}

/// Captures microphone audio and yields it as a stream of buffers.
///
/// Implemented by `VoiceInputPlatform.MicrophoneCapture`; unit tests substitute a
/// fixture-driven fake.
public protocol AudioCapturing: AnyObject, Sendable {
    /// Starts capture. The returned stream finishes when `stop()` is called or the
    /// engine fails.
    func start(format: AudioStreamFormat) throws -> AsyncStream<AudioBuffer>
    func stop()
    /// Most recent input level in `[0, 1]`, for the UI meter.
    var level: Float { get }
}
