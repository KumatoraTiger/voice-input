import Foundation

/// Where the text to read aloud comes from.
///
/// A seam rather than a concrete reader, because every plausible source is
/// platform-side — a synthesised ⌘C today, OCR of the frontmost window next — and
/// Core may not import AppKit. `@MainActor` because a source reads the pasteboard
/// or the window server, and because `NarrationCoordinator` is main-actor anyway.
@MainActor
public protocol NarrationSourceReading {
    /// The text the user wants read. Empty when there is nothing selected; the
    /// coordinator turns that into `VoiceInputError.nothingToRead` rather than
    /// leaving each source to invent a message.
    func read() async throws -> String
}

/// Speaks text out loud, one queued chunk after another.
///
/// Class-bound and main-actor: every implementation wraps a stateful system
/// synthesiser that must be driven from one place.
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    /// Whether anything is being spoken or is still queued.
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    /// Appends a chunk and starts speaking if nothing is. This is what lets the
    /// rewrite of chunk 2 happen while chunk 1 is already audible.
    ///
    /// - Parameter rate: 0 slowest, 1 fastest, 0.5 the system's normal pace.
    func enqueue(_ text: String, rate: Double)
    func pause()
    func resume()
    /// Drops the queue and stops mid-sentence.
    func stop()
    /// Called when the queue empties, so the coordinator can go back to idle
    /// without polling.
    var onQueueDrained: (@MainActor () -> Void)? { get set }
}

/// What the read-aloud pipeline is doing. The menu renders from this.
public enum NarrationState: Sendable, Equatable {
    case idle
    /// Reading the source and rewriting the first chunk. Nothing is audible yet.
    case preparing
    case speaking
    case paused
    case failed(VoiceInputError)

    /// Whether a press of the shortcut should control the run in flight rather
    /// than start a new one.
    public var isActive: Bool {
        switch self {
        case .preparing, .speaking, .paused: return true
        case .idle, .failed: return false
        }
    }

    /// Content-free name, safe to log as `.public`.
    public var logName: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .speaking: return "speaking"
        case .paused: return "paused"
        case .failed(let error): return "failed(\(error.kind))"
        }
    }
}
