import Foundation

/// The single state machine the whole UI renders from.
///
/// idle → preparing → recording → transcribing → formatting → finished → idle
/// Any state can go to `failed`, and `failed`/`finished` return to `idle`.
public enum DictationState: Sendable, Equatable {
    case idle
    /// Permissions checked, engine warming up.
    case preparing
    case recording
    /// Audio stopped, waiting for the final transcript.
    case transcribing
    /// Calling the LLM.
    case formatting
    case finished(ActionOutcome)
    case failed(VoiceInputError)

    public var isBusy: Bool {
        switch self {
        case .idle, .finished, .failed: return false
        case .preparing, .recording, .transcribing, .formatting: return true
        }
    }
}

/// One completed dictation, kept for the history menu. Text stays in memory only
/// (never written to disk) so nothing sensitive outlives the app.
public struct DictationRecord: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var rawText: String
    public var formattedText: String
    public var date: Date
    public var summary: String?

    public init(
        id: UUID = UUID(),
        rawText: String,
        formattedText: String,
        date: Date,
        summary: String? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.formattedText = formattedText
        self.date = date
        self.summary = summary
    }
}
