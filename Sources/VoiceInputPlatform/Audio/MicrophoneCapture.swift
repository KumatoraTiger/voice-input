import AVFoundation
import Foundation
import VoiceInputCore

/// Microphone capture built on `AVAudioEngine`.
///
/// The hardware input format is whatever the current device happens to be
/// (44.1/48 kHz, 1–2 channels), so every tap buffer is run through an
/// `AVAudioConverter` down to the pipeline format (16 kHz mono float32) before it
/// is handed to the consumer. Nothing is ever written to disk.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()

    /// Guards the mutable session state. The render thread takes it once per tap
    /// buffer, which is uncontended in practice (the only other writers are
    /// `start`/`stop` on the main thread) and far cheaper than the conversion that
    /// precedes it.
    private let stateLock = NSLock()
    private let levelLock = NSLock()

    private var continuation: AsyncStream<VoiceInputCore.AudioBuffer>.Continuation?
    private var targetFormat: AudioStreamFormat = .capture
    private var outputFormat: AVAudioFormat?
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var smoothedLevel: Float = 0

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - AudioCapturing

    public var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return smoothedLevel
    }

    public func start(format: AudioStreamFormat) throws -> AsyncStream<VoiceInputCore.AudioBuffer> {
        // `stop()` is idempotent, so this also covers "start called twice".
        stop()

        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: AVAudioChannelCount(max(1, format.channelCount)),
                interleaved: false
            )
        else {
            throw VoiceInputError.audioEngineFailed("出力フォーマットを作成できませんでした。")
        }

        let (stream, continuation) = AsyncStream<VoiceInputCore.AudioBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )

        stateLock.lock()
        self.continuation = continuation
        self.targetFormat = format
        self.outputFormat = output
        stateLock.unlock()

        do {
            try attachTapAndStartEngine()
        } catch {
            stateLock.lock()
            self.continuation = nil
            self.outputFormat = nil
            stateLock.unlock()
            continuation.finish()
            throw error
        }

        stateLock.lock()
        isRunning = true
        stateLock.unlock()

        installConfigurationObserver()
        return stream
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = isRunning
        let continuation = self.continuation
        let observer = configurationObserver
        self.continuation = nil
        self.outputFormat = nil
        self.configurationObserver = nil
        isRunning = false
        stateLock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        if wasRunning || engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Nil after the first call, so the stream is finished exactly once.
        continuation?.finish()

        levelLock.lock()
        smoothedLevel = 0
        levelLock.unlock()
    }

    // MARK: - Engine wiring

    private func attachTapAndStartEngine() throws {
        stateLock.lock()
        let output = outputFormat
        stateLock.unlock()

        guard let output else {
            throw VoiceInputError.audioEngineFailed("録音が開始されていません。")
        }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw VoiceInputError.audioEngineFailed("使用できる入力デバイスが見つかりません。")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: output) else {
            throw VoiceInputError.audioEngineFailed("オーディオ変換器を作成できませんでした。")
        }
        converter.reset()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat) {
            [weak self] buffer, _ in
            self?.process(buffer, converter: converter, output: output)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }
    }

    /// The input device changed (unplugged headset, new default mic). AVAudioEngine
    /// tears the graph down around us, so the tap has to be reinstalled against the
    /// new hardware format.
    private func installConfigurationObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        stateLock.lock()
        configurationObserver = observer
        stateLock.unlock()
    }

    private func handleConfigurationChange() {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running else { return }

        do {
            try attachTapAndStartEngine()
        } catch {
            // Nothing left to record from; end the stream cleanly rather than trap.
            stop()
        }
    }

    // MARK: - Conversion

    private func process(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        output: AVAudioFormat
    ) {
        guard let converted = Self.convert(buffer, using: converter, to: output) else { return }
        guard let channel = converted.floatChannelData?[0] else { return }
        let frameCount = Int(converted.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        updateLevel(with: samples)

        stateLock.lock()
        let continuation = self.continuation
        let format = targetFormat
        stateLock.unlock()

        continuation?.yield(VoiceInputCore.AudioBuffer(samples: samples, format: format))
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to output: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1_024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: buffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        // `.inputRanDry` is the normal outcome for a single-buffer feed.
        guard status != .error, buffer.frameLength > 0 else { return nil }
        return buffer
    }

    // MARK: - Level meter

    private func updateLevel(with samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()

        // Map -60 dBFS…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalized = min(max((decibels + 60) / 60, 0), 1)

        levelLock.lock()
        // Fast attack, slow release: the meter should jump on speech and glide down.
        let coefficient: Float = normalized > smoothedLevel ? 0.5 : 0.12
        smoothedLevel += (normalized - smoothedLevel) * coefficient
        levelLock.unlock()
    }
}
