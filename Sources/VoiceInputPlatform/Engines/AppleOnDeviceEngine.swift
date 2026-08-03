import AVFoundation
import Foundation
import Speech
import VoiceInputCore

/// `SFSpeechRecognizer` driven strictly on-device.
///
/// `requiresOnDeviceRecognition` is non-negotiable here: dictation audio must never
/// leave the machine through Apple's servers. If a locale has no on-device model,
/// the engine reports itself unavailable instead of silently falling back to the
/// network path.
public struct AppleOnDeviceEngine: TranscriptionEngine {
    /// How long `finish()` waits for the final result after `endAudio()`.
    private let finalResultTimeout: TimeInterval

    public init(finalResultTimeout: TimeInterval = 15) {
        self.finalResultTimeout = finalResultTimeout
    }

    public var id: TranscriptionEngineID { .appleOnDevice }
    public var displayName: String { "Apple 音声認識（オンデバイス）" }
    public var supportsStreamingPartials: Bool { true }

    public func availability(locale: Locale) async -> EngineAvailability {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return EngineAvailability(
                status: .unsupportedLocale(locale.identifier),
                detail: "この言語 (\(locale.identifier)) に対応する音声認識モデルがありません。"
            )
        }

        guard recognizer.supportsOnDeviceRecognition else {
            return EngineAvailability(
                status: .unavailable("オンデバイス認識に非対応"),
                detail: """
                    この言語 (\(locale.identifier)) はオンデバイス認識に対応していません。\
                    音声を Apple のサーバーに送信しない方針のため、別のエンジンを選択してください。
                    """
            )
        }

        switch PermissionsService.speechRecognitionStatus() {
        case .granted:
            break
        case .notDetermined:
            return EngineAvailability(
                status: .needsPermission,
                detail: "音声認識の使用許可がまだ求められていません。"
            )
        case .denied, .restricted:
            return EngineAvailability(
                status: .needsPermission,
                detail: "音声認識の使用が許可されていません。"
            )
        }

        if PermissionsService.microphoneStatus() != .granted {
            return EngineAvailability(
                status: .needsPermission,
                detail: "マイクへのアクセスが許可されていません。"
            )
        }

        guard recognizer.isAvailable else {
            return EngineAvailability(
                status: .unavailable("認識エンジンが一時的に利用できません"),
                detail: "音声認識モデルの準備中の可能性があります。しばらく待ってから再試行してください。"
            )
        }

        return .available
    }

    public func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        let availability = await availability(locale: configuration.locale)
        guard availability.isUsable else {
            throw VoiceInputError.engineUnavailable(
                id,
                availability.detail ?? "利用できません。"
            )
        }
        guard let recognizer = SFSpeechRecognizer(locale: configuration.locale) else {
            throw VoiceInputError.engineUnavailable(id, "音声認識器を作成できませんでした。")
        }
        return AppleOnDeviceSession(
            recognizer: recognizer,
            configuration: configuration,
            timeout: finalResultTimeout
        )
    }
}

// MARK: - Session

/// One dictation against `SFSpeechAudioBufferRecognitionRequest`.
///
/// The recognition task's result handler can fire before, during or after
/// `finish()`, so the final outcome is parked in `pendingResult` and picked up by
/// whichever side arrives second.
private final class AppleOnDeviceSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let configuration: TranscriptionConfiguration
    private let timeout: TimeInterval
    private let startedAt = Date()
    private let partialContinuation: AsyncStream<String>.Continuation

    private var task: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var pendingResult: Result<String, Error>?
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var isFinished = false

    let partialTranscripts: AsyncStream<String>

    init(
        recognizer: SFSpeechRecognizer,
        configuration: TranscriptionConfiguration,
        timeout: TimeInterval
    ) {
        self.recognizer = recognizer
        self.configuration = configuration
        self.timeout = timeout

        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        partialTranscripts = stream
        partialContinuation = continuation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if !configuration.contextualStrings.isEmpty {
            request.contextualStrings = configuration.contextualStrings
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    // MARK: TranscriptionSession

    func append(_ buffer: VoiceInputCore.AudioBuffer) async {
        guard locked({ !isFinished }), let pcm = Self.makePCMBuffer(from: buffer) else { return }
        request.append(pcm)
    }

    func finish() async throws -> Transcript {
        if locked({ isFinished }) {
            throw VoiceInputError.cancelled
        }

        request.endAudio()

        let text: String
        do {
            text = try await awaitFinalTranscript()
        } catch {
            teardown()
            throw error
        }
        teardown()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceInputError.emptyTranscript }

        return Transcript(
            text: trimmed,
            locale: configuration.locale.identifier,
            duration: Date().timeIntervalSince(startedAt),
            engine: .appleOnDevice
        )
    }

    func cancel() async {
        let continuation = locked { () -> CheckedContinuation<String, Error>? in
            let pending = finalContinuation
            finalContinuation = nil
            pendingResult = pendingResult ?? .failure(VoiceInputError.cancelled)
            return pending
        }

        task?.cancel()
        teardown()
        continuation?.resume(throwing: VoiceInputError.cancelled)
    }

    // MARK: - Result plumbing

    /// Locking has to happen inside a synchronous frame: `NSLock` is unavailable
    /// from async contexts (a hard error under the Swift 6 language mode).
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.lock()
            latestTranscript = text
            lock.unlock()

            if result.isFinal {
                resolve(.success(text))
                return
            }
            partialContinuation.yield(text)
        }

        guard let error else { return }
        lock.lock()
        let fallback = latestTranscript
        lock.unlock()

        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The task ended abnormally but we already have usable text; keep it.
            resolve(.success(fallback))
        } else if Self.isNoSpeechDetected(error) {
            resolve(.failure(VoiceInputError.emptyTranscript))
        } else {
            resolve(.failure(VoiceInputError.transcriptionFailed(error.localizedDescription)))
        }
    }

    private func resolve(_ outcome: Result<String, Error>) {
        lock.lock()
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        pendingResult = outcome
        let continuation = finalContinuation
        finalContinuation = nil
        lock.unlock()

        partialContinuation.finish()
        continuation?.resume(with: outcome)
    }

    private func awaitFinalTranscript() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.waitForResult() }
            group.addTask { [timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw VoiceInputError.transcriptionFailed("認識結果を待機中にタイムアウトしました。")
            }
            guard let first = try await group.next() else {
                throw VoiceInputError.transcriptionFailed("認識結果を取得できませんでした。")
            }
            group.cancelAll()
            return first
        }
    }

    private func waitForResult() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingResult {
                    lock.unlock()
                    continuation.resume(with: pendingResult)
                    return
                }
                finalContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = finalContinuation
            finalContinuation = nil
            if pendingResult == nil {
                pendingResult = .failure(VoiceInputError.cancelled)
            }
            lock.unlock()
            continuation?.resume(throwing: VoiceInputError.cancelled)
        }
    }

    private func teardown() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let task = self.task
        self.task = nil
        lock.unlock()

        task?.finish()
        partialContinuation.finish()
    }

    // MARK: - Helpers

    /// `kAFAssistantErrorDomain` 1110 / 203 are "no speech was detected", which is a
    /// normal outcome for an accidental hotkey press rather than a failure.
    private static func isNoSpeechDetected(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "kAFAssistantErrorDomain" else { return false }
        return nsError.code == 1_110 || nsError.code == 203
    }

    private static func makePCMBuffer(from buffer: VoiceInputCore.AudioBuffer) -> AVAudioPCMBuffer?
    {
        let channels = max(1, buffer.format.channelCount)
        let frames = buffer.samples.count / channels
        guard frames > 0 else { return nil }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ),
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let destination = pcm.floatChannelData
        else { return nil }

        pcm.frameLength = AVAudioFrameCount(frames)
        buffer.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            if channels == 1 {
                destination[0].update(from: base, count: frames)
            } else {
                // De-interleave: the contract stores interleaved samples.
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        destination[channel][frame] = base[frame * channels + channel]
                    }
                }
            }
        }
        return pcm
    }
}
