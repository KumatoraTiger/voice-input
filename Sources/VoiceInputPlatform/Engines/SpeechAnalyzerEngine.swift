import Foundation
import VoiceInputCore

// MARK: - Fallback (always compiled)

/// Stand-in for an engine that this build cannot provide.
///
/// Keeping it in the registry means `TranscriptionEngineID.appleSpeechAnalyzer`
/// always resolves to *something*, so Settings can show why the option is greyed
/// out instead of the engine silently disappearing from the list.
public struct UnavailableEngine: TranscriptionEngine {
    public let id: TranscriptionEngineID
    public let displayName: String
    private let reason: String

    public init(id: TranscriptionEngineID, displayName: String, reason: String) {
        self.id = id
        self.displayName = displayName
        self.reason = reason
    }

    public var supportsStreamingPartials: Bool { false }

    public func availability(locale: Locale) async -> EngineAvailability {
        EngineAvailability(status: .unsupportedOS(reason), detail: reason)
    }

    public func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        throw VoiceInputError.engineUnavailable(id, reason)
    }
}

extension UnavailableEngine {
    /// Message shown when the binary was built against a pre-macOS 26 SDK.
    public static let speechAnalyzerUnsupportedReason =
        "SpeechAnalyzer は macOS 26 以降 + macOS 26 SDK でのビルドが必要です"

    public static func speechAnalyzer(
        reason: String = UnavailableEngine.speechAnalyzerUnsupportedReason
    ) -> UnavailableEngine {
        UnavailableEngine(
            id: .appleSpeechAnalyzer,
            displayName: "Apple SpeechAnalyzer",
            reason: reason
        )
    }
}

// MARK: - Real implementation

// Everything below is compiled ONLY when `Scripts/build.sh` detects a macOS 26 or
// newer SDK and defines `SPEECH_ANALYZER`. The local development toolchain here is
// the macOS 15 SDK, where none of these symbols exist, so this code is verified by
// CI on a macOS 26 runner rather than by local builds.
//
// API shape confirmed against Apple's documentation:
//   https://developer.apple.com/documentation/speech/speechanalyzer
//   https://developer.apple.com/documentation/speech/speechtranscriber
//   https://developer.apple.com/documentation/speech/analyzerinput
//   https://developer.apple.com/documentation/speech/assetinventory
//   https://developer.apple.com/documentation/speech/analysiscontext

#if SPEECH_ANALYZER

import AVFoundation
import Speech

/// `SpeechAnalyzer` + `SpeechTranscriber`, Apple's replacement for
/// `SFSpeechRecognizer`. Runs on-device, is noticeably more accurate on long-form
/// dictation, and streams volatile (provisional) results while speaking.
@available(macOS 26, *)
public struct SpeechAnalyzerEngine: TranscriptionEngine {
    public init() {}

    public var id: TranscriptionEngineID { .appleSpeechAnalyzer }
    public var displayName: String { "Apple SpeechAnalyzer" }
    public var supportsStreamingPartials: Bool { true }

    public func availability(locale: Locale) async -> EngineAvailability {
        guard SpeechTranscriber.isAvailable else {
            return EngineAvailability(
                status: .unavailable("SpeechAnalyzer を利用できません"),
                detail: "このデバイスでは SpeechTranscriber が利用できません。"
            )
        }

        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return EngineAvailability(
                status: .unsupportedLocale(locale.identifier),
                detail: "この言語 (\(locale.identifier)) は SpeechAnalyzer が対応していません。"
            )
        }

        // SpeechAnalyzer transcribes on-device, but the Speech framework's TCC gate
        // still applies once the user has explicitly denied it.
        switch PermissionsService.speechRecognitionStatus() {
        case .denied, .restricted:
            return EngineAvailability(
                status: .needsPermission,
                detail: "音声認識の使用が許可されていません。"
            )
        case .granted, .notDetermined:
            break
        }

        if PermissionsService.microphoneStatus() != .granted {
            return EngineAvailability(
                status: .needsPermission,
                detail: "マイクへのアクセスが許可されていません。"
            )
        }

        return .available
    }

    public func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        guard
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: configuration.locale)
        else {
            throw VoiceInputError.engineUnavailable(
                id,
                "この言語 (\(configuration.locale.identifier)) は SpeechAnalyzer が対応していません。"
            )
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // The locale model is a downloadable asset; `assetInstallationRequest`
        // returns nil once everything the modules need is already installed.
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installation.downloadAndInstall()
            }
            // Reservations keep the OS from reclaiming the model under disk pressure.
            // `reservedLocales` is an async property, so it is read into a local
            // rather than inlined into the condition.
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0 == locale }) {
                _ = try await AssetInventory.reserve(locale: locale)
            }
        } catch {
            throw VoiceInputError.engineUnavailable(
                id,
                "音声認識モデルの取得に失敗しました: \(error.localizedDescription)"
            )
        }

        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            )
        else {
            throw VoiceInputError.engineUnavailable(id, "対応する音声フォーマットがありません。")
        }

        let context = AnalysisContext()
        if !configuration.contextualStrings.isEmpty {
            context.contextualStrings = [.general: configuration.contextualStrings]
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)

        do {
            try await analyzer.setContext(context)
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            inputContinuation.finish()
            throw VoiceInputError.transcriptionFailed(error.localizedDescription)
        }

        return SpeechAnalyzerSession(
            analyzer: analyzer,
            transcriber: transcriber,
            inputContinuation: inputContinuation,
            analyzerFormat: analyzerFormat,
            configuration: configuration
        )
    }
}

@available(macOS 26, *)
private final class SpeechAnalyzerSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let configuration: TranscriptionConfiguration
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let partialContinuation: AsyncStream<String>.Continuation
    private let startedAt = Date()

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var finalizedText = ""
    private var volatileText = ""
    private var isFinished = false
    private var resultsTask: Task<Void, Error>?

    let partialTranscripts: AsyncStream<String>

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat,
        configuration: TranscriptionConfiguration
    ) {
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.configuration = configuration
        self.inputContinuation = inputContinuation

        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        partialTranscripts = stream
        partialContinuation = continuation

        resultsTask = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                self.absorb(result)
            }
        }
    }

    // MARK: TranscriptionSession

    /// Locking has to happen inside a synchronous frame: `NSLock` is unavailable
    /// from async contexts (a hard error under the Swift 6 language mode).
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func append(_ buffer: VoiceInputCore.AudioBuffer) async {
        guard locked({ !isFinished }), let pcm = makeAnalyzerBuffer(from: buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: pcm))
    }

    func finish() async throws -> Transcript {
        let alreadyFinished = locked { () -> Bool in
            let was = isFinished
            isFinished = true
            return was
        }
        if alreadyFinished { throw VoiceInputError.cancelled }

        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultsTask?.value
        } catch {
            partialContinuation.finish()
            throw VoiceInputError.transcriptionFailed(error.localizedDescription)
        }
        partialContinuation.finish()

        let text = locked { finalizedText.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.isEmpty else { throw VoiceInputError.emptyTranscript }

        return Transcript(
            text: text,
            locale: configuration.locale.identifier,
            duration: Date().timeIntervalSince(startedAt),
            engine: .appleSpeechAnalyzer
        )
    }

    func cancel() async {
        let alreadyFinished = locked { () -> Bool in
            let was = isFinished
            isFinished = true
            return was
        }
        guard !alreadyFinished else { return }

        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
        partialContinuation.finish()
    }

    // MARK: - Results

    /// Volatile results are provisional and get replaced by the finalized result
    /// covering the same audio range, so only finalized text is accumulated.
    private func absorb(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        lock.lock()
        if result.isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        let preview = finalizedText + volatileText
        lock.unlock()
        partialContinuation.yield(preview)
    }

    // MARK: - Audio

    private func makeAnalyzerBuffer(from buffer: VoiceInputCore.AudioBuffer) -> AVAudioPCMBuffer? {
        let channels = max(1, buffer.format.channelCount)
        let frames = buffer.samples.count / channels
        guard frames > 0 else { return nil }

        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ),
            let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
            let destination = pcm.floatChannelData
        else { return nil }

        pcm.frameLength = AVAudioFrameCount(frames)
        buffer.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            if channels == 1 {
                destination[0].update(from: base, count: frames)
            } else {
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        destination[channel][frame] = base[frame * channels + channel]
                    }
                }
            }
        }

        if source.sampleRate == analyzerFormat.sampleRate,
            source.channelCount == analyzerFormat.channelCount,
            source.commonFormat == analyzerFormat.commonFormat
        {
            return pcm
        }
        return convert(pcm, from: source)
    }

    private func convert(_ input: AVAudioPCMBuffer, from source: AVAudioFormat) -> AVAudioPCMBuffer?
    {
        lock.lock()
        if sourceFormat != source || converter == nil {
            converter = AVAudioConverter(from: source, to: analyzerFormat)
            sourceFormat = source
        }
        let converter = self.converter
        lock.unlock()
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
        else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

#endif
