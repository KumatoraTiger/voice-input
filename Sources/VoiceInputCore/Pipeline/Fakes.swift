import Foundation
import os

// Preview / test helpers. These ship in the library on purpose so the SwiftUI
// target can build previews without a microphone, an API key or a network.
// Nothing here performs I/O.

// MARK: - Audio

public final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioBuffer>.Continuation?
    private var storedLevel: Float = 0

    /// Emitted (in order) as soon as capture starts.
    public var scriptedBuffers: [AudioBuffer]
    /// When set, `start` throws instead of returning a stream.
    public var startError: VoiceInputError?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    public init(
        scriptedBuffers: [AudioBuffer] = [FakeAudioCapture.tone(seconds: 0.5)],
        startError: VoiceInputError? = nil
    ) {
        self.scriptedBuffers = scriptedBuffers
        self.startError = startError
    }

    public func start(format: AudioStreamFormat) throws -> AsyncStream<AudioBuffer> {
        if let startError { throw startError }
        lock.lock()
        startCount += 1
        let buffers = scriptedBuffers
        lock.unlock()

        return AsyncStream { continuation in
            for buffer in buffers { continuation.yield(buffer) }
            self.lock.lock()
            self.continuation = continuation
            self.storedLevel = buffers.isEmpty ? 0 : 0.5
            self.lock.unlock()
        }
    }

    public func stop() {
        lock.lock()
        stopCount += 1
        let continuation = self.continuation
        self.continuation = nil
        storedLevel = 0
        lock.unlock()
        continuation?.finish()
    }

    public var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return storedLevel
    }

    public static func tone(seconds: Double, sampleRate: Double = 16_000) -> AudioBuffer {
        let count = max(0, Int(seconds * sampleRate))
        let samples = (0..<count).map { index -> Float in
            Float(sin(Double(index) * 2 * Double.pi * 440 / sampleRate)) * 0.4
        }
        return AudioBuffer(samples: samples, format: .capture)
    }
}

// MARK: - Transcription

public struct FakeTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let id: TranscriptionEngineID
    public let displayName: String
    public let supportsStreamingPartials: Bool

    private let transcript: String
    private let partials: [String]
    private let availabilityResult: EngineAvailability
    private let finishError: VoiceInputError?

    public init(
        id: TranscriptionEngineID = .appleOnDevice,
        displayName: String = "テスト用エンジン",
        transcript: String = "これはテストの書き起こしです",
        partials: [String] = [],
        availability: EngineAvailability = .available,
        finishError: VoiceInputError? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.transcript = transcript
        self.partials = partials
        self.supportsStreamingPartials = !partials.isEmpty
        self.availabilityResult = availability
        self.finishError = finishError
    }

    public func availability(locale: Locale) async -> EngineAvailability { availabilityResult }

    public func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        FakeTranscriptionSession(
            transcript: transcript,
            partials: partials,
            engine: id,
            locale: configuration.locale.identifier,
            finishError: finishError
        )
    }
}

public actor FakeTranscriptionSession: TranscriptionSession {
    nonisolated public let partialTranscripts: AsyncStream<String>

    private let transcript: String
    private let engine: TranscriptionEngineID
    private let locale: String
    private let finishError: VoiceInputError?
    private var appendedSamples = 0
    private var cancelled = false

    init(
        transcript: String,
        partials: [String],
        engine: TranscriptionEngineID,
        locale: String,
        finishError: VoiceInputError?
    ) {
        self.transcript = transcript
        self.engine = engine
        self.locale = locale
        self.finishError = finishError
        self.partialTranscripts = AsyncStream { continuation in
            for partial in partials { continuation.yield(partial) }
            continuation.finish()
        }
    }

    public func append(_ buffer: AudioBuffer) async {
        appendedSamples += buffer.samples.count
    }

    public func cancel() async { cancelled = true }

    public func finish() async throws -> Transcript {
        if cancelled { throw VoiceInputError.cancelled }
        if let finishError { throw finishError }
        return Transcript(text: transcript, locale: locale, duration: 1, engine: engine)
    }

    public var receivedSampleCount: Int { appendedSamples }
    public var wasCancelled: Bool { cancelled }
}

// MARK: - LLM

public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public let id: LLMProviderID
    public let displayName = "テスト用プロバイダ"
    public let suggestedModels = ["fake-model"]
    public let defaultModel = "fake-model"
    public let apiKeyURL = URL(string: "https://example.invalid/keys")!

    private let storedRequests = OSAllocatedUnfairLock<[LLMRequest]>(initialState: [])
    private let replies: [String]
    private let error: VoiceInputError?

    public convenience init(
        id: LLMProviderID = .openAI,
        reply: String = "整形されたテキスト。",
        error: VoiceInputError? = nil
    ) {
        self.init(id: id, replies: [reply], error: error)
    }

    /// Answers each call with the next reply, repeating the last one. Lets a test
    /// drive a flow that calls the provider more than once — `FormatAction`
    /// retrying without screen context, for instance.
    public init(
        id: LLMProviderID = .openAI,
        replies: [String],
        error: VoiceInputError? = nil
    ) {
        self.id = id
        self.replies = replies.isEmpty ? [""] : replies
        self.error = error
    }

    public var requests: [LLMRequest] {
        storedRequests.withLock { $0 }
    }

    public func send(_ request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        let index = storedRequests.withLock { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        if let error { throw error }
        return LLMResponse(
            text: replies[min(index, replies.count - 1)],
            inputTokens: 10,
            outputTokens: 5,
            model: request.model
        )
    }
}

// MARK: - Output

public final class FakeOutputSink: OutputSink, @unchecked Sendable {
    private let storedCopied = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let storedPasted = OSAllocatedUnfairLock<[String]>(initialState: [])

    public var canPaste: Bool
    public var copyError: VoiceInputError?

    public init(canPaste: Bool = true, copyError: VoiceInputError? = nil) {
        self.canPaste = canPaste
        self.copyError = copyError
    }

    public var copiedTexts: [String] { storedCopied.withLock { $0 } }

    public var pastedTexts: [String] { storedPasted.withLock { $0 } }

    public func copy(_ text: String) throws {
        if let copyError { throw copyError }
        storedCopied.withLock { $0.append(text) }
    }

    public func paste(_ text: String) async throws {
        guard canPaste else { throw VoiceInputError.accessibilityPermissionDenied }
        storedPasted.withLock { $0.append(text) }
    }
}

// MARK: - Screen context

public final class FakeScreenContextProvider: ScreenContextProviding, @unchecked Sendable {
    private let context: ScreenContext
    private let storedCallCount = OSAllocatedUnfairLock(initialState: 0)

    public init(_ context: ScreenContext) {
        self.context = context
    }

    /// How many dictations actually consulted the screen. Zero is the assertion
    /// that matters while the feature is off.
    public var callCount: Int { storedCallCount.withLock { $0 } }

    public func currentContext() async -> ScreenContext {
        storedCallCount.withLock { $0 += 1 }
        return context
    }
}
