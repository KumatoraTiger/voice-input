import Foundation

/// Identifies a speech-to-text backend.
///
/// Adding an engine = add a case here, implement `TranscriptionEngine`, register it
/// in `EngineRegistry`. See `docs/adding-an-engine.md`.
public enum TranscriptionEngineID: String, Codable, Sendable, CaseIterable, Hashable {
    /// `SFSpeechRecognizer` with on-device recognition. Free, offline, macOS 13+.
    case appleOnDevice
    /// `SpeechAnalyzer` / `SpeechTranscriber`, macOS 26+ only. Higher accuracy.
    case appleSpeechAnalyzer
    /// Cloud STT over HTTP (OpenAI `gpt-4o-transcribe` / `whisper-1`).
    case openAICloud
}

/// Why an engine can or cannot be used right now.
public struct EngineAvailability: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case available
        /// Microphone / speech-recognition TCC permission not yet granted.
        case needsPermission
        /// No API key stored for the backing provider.
        case needsAPIKey
        /// The OS is too old, or the binary was built against an older SDK.
        case unsupportedOS(String)
        /// The requested locale has no model installed / is not supported.
        case unsupportedLocale(String)
        case unavailable(String)
    }

    public var status: Status
    /// Human-readable, shown verbatim in Settings.
    public var detail: String?

    public init(status: Status, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    public var isUsable: Bool { status == .available }

    public static let available = EngineAvailability(status: .available)
}

public struct TranscriptionConfiguration: Sendable {
    public var locale: Locale
    /// Audio format the session will be fed with.
    public var format: AudioStreamFormat
    /// Optional domain words to bias recognition toward (names, jargon).
    public var contextualStrings: [String]
    /// Free-form model override, e.g. `gpt-4o-transcribe`. Engine-specific.
    public var model: String?

    public init(
        locale: Locale,
        format: AudioStreamFormat = .capture,
        contextualStrings: [String] = [],
        model: String? = nil
    ) {
        self.locale = locale
        self.format = format
        self.contextualStrings = contextualStrings
        self.model = model
    }
}

/// The result of one dictation.
public struct Transcript: Sendable, Equatable, Codable {
    public var text: String
    public var locale: String?
    public var duration: TimeInterval
    public var engine: TranscriptionEngineID

    public init(
        text: String,
        locale: String? = nil,
        duration: TimeInterval = 0,
        engine: TranscriptionEngineID
    ) {
        self.text = text
        self.locale = locale
        self.duration = duration
        self.engine = engine
    }
}

/// One dictation in progress.
///
/// Lifecycle: `makeSession` → repeated `append` → exactly one of `finish`/`cancel`.
public protocol TranscriptionSession: AnyObject, Sendable {
    /// Live partial results for the UI. May never emit (cloud engines).
    /// Finishes when the session ends.
    var partialTranscripts: AsyncStream<String> { get }
    func append(_ buffer: AudioBuffer) async
    /// Flushes and returns the final transcript.
    func finish() async throws -> Transcript
    func cancel() async
}

/// A speech-to-text backend.
public protocol TranscriptionEngine: Sendable {
    var id: TranscriptionEngineID { get }
    var displayName: String { get }
    /// Whether partial results arrive while speaking (drives the UI).
    var supportsStreamingPartials: Bool { get }
    func availability(locale: Locale) async -> EngineAvailability
    func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession
}
