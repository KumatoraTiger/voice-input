import Foundation

/// A point in the dictation lifecycle the platform layer may want to make a
/// sound (or otherwise signal) for.
public enum FeedbackEvent: String, Sendable, Equatable, CaseIterable, Codable {
    case recordingStarted
    case recordingStopped
    case finished
    case failed
    case cancelled
}

/// Implemented in `VoiceInputPlatform` (NSSound); Core only announces events.
public protocol FeedbackPresenting: Sendable {
    func played(_ event: FeedbackEvent)
}

/// Records events instead of playing them. For tests and previews.
public final class RecordingFeedbackPresenter: FeedbackPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FeedbackEvent] = []

    public init() {}

    public var events: [FeedbackEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func played(_ event: FeedbackEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}
