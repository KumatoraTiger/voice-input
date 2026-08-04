import AVFoundation
import Foundation
import Speech
import VoiceInputCore
import os

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
/// **A recognition task is one *segment*, not one dictation.** `SFSpeechRecognizer`
/// ends the task whenever its endpointer decides an utterance is over — a pause
/// between sentences is enough — and on-device recognition additionally hard-stops
/// at roughly a minute of audio. Treating the first `isFinal` as the answer
/// therefore threw away everything the user said afterwards. So each finished
/// segment is banked in `finalizedSegments` and a fresh task is opened over the
/// same audio stream; only `finish()` ends the dictation for real.
///
/// The result handler can fire before, during or after `finish()`, so the final
/// outcome is parked in `pendingResult` and picked up by whichever side arrives
/// second.
private final class AppleOnDeviceSession: TranscriptionSession, @unchecked Sendable {
    /// How many segments may come back empty *back-to-back* before we stop
    /// reopening tasks — see `spinInterval`.
    private static let maxEmptySegments = 4
    /// A task that ends this soon after the previous one, with nothing recognised,
    /// is a broken recognizer rather than a pause in the speech.
    private static let spinInterval: TimeInterval = 0.5
    /// Absolute cap on reopened tasks, as a backstop for a stuck recognizer. At
    /// roughly a minute per segment this is far longer than any real dictation.
    private static let maxSegments = 240

    /// Segment bookkeeping only — how a task ended and whether it produced
    /// anything. Never the recognised text.
    private static let log = Logger(subsystem: "io.github.voiceinput", category: "asr")

    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private let configuration: TranscriptionConfiguration
    private let timeout: TimeInterval
    private let startedAt = Date()
    private let partialContinuation: AsyncStream<String>.Continuation

    private var request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var finalizedSegments: [String] = []
    private var latestTranscript = ""
    private var segmentCount = 0
    private var emptySegments = 0
    private var lastSegmentEndedAt: Date?
    private var partialCount = 0
    private var appendedBuffers = 0
    private var utteranceStart: TimeInterval = 0
    private var lastError: Error?
    private var pendingResult: Result<String, Error>?
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var isStopping = false
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

        let request = Self.makeRequest(configuration: configuration)
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    private static func makeRequest(
        configuration: TranscriptionConfiguration
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if !configuration.contextualStrings.isEmpty {
            request.contextualStrings = configuration.contextualStrings
        }
        return request
    }

    // MARK: TranscriptionSession

    func append(_ buffer: VoiceInputCore.AudioBuffer) async {
        guard let request = locked({ isFinished ? nil : request }),
            let pcm = Self.makePCMBuffer(from: buffer)
        else { return }
        locked { appendedBuffers += 1 }
        request.append(pcm)
    }

    func finish() async throws -> Transcript {
        // Reading the request under the same lock that sets `isStopping` is what
        // keeps a segment rollover from stranding `endAudio()` on a dead request.
        let request = locked { () -> SFSpeechAudioBufferRecognitionRequest? in
            guard !isFinished, !isStopping else { return nil }
            isStopping = true
            return self.request
        }
        guard let request else { throw VoiceInputError.cancelled }

        let (segments, partials, banked, buffers, resolved) = locked {
            (segmentCount, partialCount, finalizedSegments.count, appendedBuffers,
                pendingResult != nil)
        }
        Self.log.notice(
            """
            finishing: segments=\(segments, privacy: .public) \
            partials=\(partials, privacy: .public) \
            banked=\(banked, privacy: .public) \
            buffers=\(buffers, privacy: .public) \
            alreadyResolved=\(resolved, privacy: .public)
            """
        )

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
        let (continuation, task) = locked {
            () -> (CheckedContinuation<String, Error>?, SFSpeechRecognitionTask?) in
            let pending = finalContinuation
            finalContinuation = nil
            pendingResult = pendingResult ?? .failure(VoiceInputError.cancelled)
            isStopping = true
            return (pending, self.task)
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
            if result.isFinal {
                endSegment(text: text, error: nil)
                return
            }
            // The recognizer restarts its transcription part-way through a task,
            // silently: `formattedString` reverts to the newest utterance and the
            // segment timestamps rewind. Nothing else marks it, so the earlier
            // speech has to be banked here or it is gone.
            let windowStart = result.bestTranscription.segments.first?.timestamp ?? 0
            lock.lock()
            let previousStart = utteranceStart
            let previous = latestTranscript
            let restarted = UtteranceBoundary.restarted(
                previous: previous,
                next: text,
                previousStart: previousStart,
                nextStart: windowStart
            )
            if restarted {
                finalizedSegments.append(previous)
            }
            utteranceStart = windowStart
            latestTranscript = text
            partialCount += 1
            let banked = finalizedSegments.count
            let preview = TranscriptSegmentJoiner.join(finalizedSegments + [text])
            lock.unlock()

            if restarted {
                // Lengths and timestamps only — never the text.
                Self.log.notice(
                    """
                    utterance restarted: banked=\(banked, privacy: .public) \
                    keptChars=\(previous.count, privacy: .public) \
                    newChars=\(text.count, privacy: .public) \
                    from=\(previousStart, format: .fixed(precision: 2), privacy: .public) \
                    to=\(windowStart, format: .fixed(precision: 2), privacy: .public)
                    """
                )
            } else if text.count < previous.count {
                // The mirror image of the line above. A shrink we read as a revision
                // is the call most likely to be wrong — too eager and the dictation
                // says everything twice, too strict and half of it disappears — so
                // leave the numbers behind for whoever has to judge that next.
                Self.log.debug(
                    """
                    shrink kept as revision: \
                    fromChars=\(previous.count, privacy: .public) \
                    toChars=\(text.count, privacy: .public) \
                    from=\(previousStart, format: .fixed(precision: 2), privacy: .public) \
                    to=\(windowStart, format: .fixed(precision: 2), privacy: .public)
                    """
                )
            }
            partialContinuation.yield(preview)
            return
        }

        // An error also ends the task, and mid-dictation it usually just means
        // "that utterance is over" or "the one-minute on-device cap was reached" —
        // the same rollover as a normal `isFinal`.
        guard let error else { return }
        endSegment(text: locked { latestTranscript }, error: error)
    }

    /// What to do now that one recognition task has ended.
    private enum SegmentOutcome {
        case ignore
        /// The dictation continues: reopen a task and keep the joined text so far.
        case rollOver(preview: String)
        /// The dictation is over (or unrecoverable): this is the whole transcript.
        case complete(text: String, error: Error?)

        var label: String {
            switch self {
            case .ignore: return "ignore"
            case .rollOver: return "rollOver"
            case .complete(let text, _): return text.isEmpty ? "complete(empty)" : "complete"
            }
        }
    }

    private func endSegment(text: String, error: Error?) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome = locked { () -> SegmentOutcome in
            guard pendingResult == nil, !isFinished else { return .ignore }

            // A terminal result can come back empty even after partials carried
            // text — reproducibly so on macOS 15 when `endAudio()` tears the task
            // down mid-utterance. The last partial is then the best transcript this
            // segment produced, and dropping it loses the whole dictation.
            if trimmed.isEmpty {
                trimmed = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !trimmed.isEmpty {
                finalizedSegments.append(trimmed)
            }
            // A task that ends empty *instantly* means the recognizer has stopped
            // working and reopening it would spin. One that ends empty after a
            // while is just silence, which is a normal part of a dictation.
            let now = Date()
            let immediate =
                lastSegmentEndedAt.map { now.timeIntervalSince($0) < Self.spinInterval } ?? false
            emptySegments = (trimmed.isEmpty && immediate) ? emptySegments + 1 : 0
            lastSegmentEndedAt = now

            latestTranscript = ""
            utteranceStart = 0
            segmentCount += 1
            if let error { lastError = error }

            let joined = TranscriptSegmentJoiner.join(finalizedSegments)
            guard !isStopping,
                emptySegments < Self.maxEmptySegments,
                segmentCount < Self.maxSegments
            else {
                return .complete(text: joined, error: lastError)
            }
            return .rollOver(preview: joined)
        }

        let (index, partials) = locked { (segmentCount, partialCount) }
        Self.log.notice(
            """
            segment ended: index=\(index, privacy: .public) \
            empty=\(trimmed.isEmpty, privacy: .public) \
            partials=\(partials, privacy: .public) \
            error=\(Self.describe(error), privacy: .public) \
            outcome=\(outcome.label, privacy: .public)
            """
        )

        switch outcome {
        case .ignore:
            return
        case .rollOver(let preview):
            rollOverToNewTask(preview: preview)
        case .complete(let text, let error):
            complete(text: text, error: error)
        }
    }

    /// Domain + code only. Apple's error strings are not user content, but the
    /// numbers are what identify the failure and the string adds nothing.
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    private func complete(text: String, error: Error?) {
        guard text.isEmpty else {
            resolve(.success(text))
            return
        }
        guard let error, !Self.isNoSpeechDetected(error) else {
            resolve(.failure(VoiceInputError.emptyTranscript))
            return
        }
        resolve(.failure(VoiceInputError.transcriptionFailed(error.localizedDescription)))
    }

    /// Swaps in a fresh request + task so the audio that keeps arriving is still
    /// recognised. The swap happens inside the ended task's callback, so the window
    /// in which buffers are dropped is the silence the endpointer just detected.
    private func rollOverToNewTask(preview: String) {
        let newRequest = Self.makeRequest(configuration: configuration)

        // `finish()` or `cancel()` may have won the race while we were deciding.
        // Publishing `newRequest` under the lock is what makes a `finish()` that
        // arrives from here on hand its `endAudio()` to the task we are about to
        // open rather than to the one that just died.
        var previousTask: SFSpeechRecognitionTask?
        let swapped = locked { () -> Bool in
            guard !isFinished, !isStopping else { return false }
            previousTask = task
            request = newRequest
            task = nil
            return true
        }
        guard swapped else {
            complete(text: preview, error: nil)
            return
        }
        previousTask?.finish()

        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        let stale = locked { () -> SFSpeechRecognitionTask? in
            guard !isFinished else { return newTask }
            task = newTask
            return nil
        }
        stale?.cancel()

        partialContinuation.yield(preview)
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
