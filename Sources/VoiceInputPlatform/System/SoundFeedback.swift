import AppKit
import Foundation
import VoiceInputCore

/// Plays a short system sound at each point in the dictation lifecycle.
///
/// The app is a menu-bar utility with no window in front of the user most of the
/// time, so sound is the primary confirmation that recording actually started.
public final class SoundFeedback: FeedbackPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    public init(isEnabled: Bool = true) {
        enabled = isEnabled
    }

    /// Bound to `AppSettings.playSounds`; flipping it takes effect immediately.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
        }
    }

    public func played(_ event: FeedbackEvent) {
        guard isEnabled, let name = Self.soundName(for: event) else { return }
        DispatchQueue.main.async {
            // NSSound instances are cached because each one owns a decoded buffer;
            // re-creating them on every hotkey press would thrash the audio stack.
            MainActor.assumeIsolated {
                guard let sound = Self.sound(named: name) else { return }
                // `play()` is a no-op on an already-playing sound; restart instead so
                // rapid start/stop cycles still give feedback.
                if sound.isPlaying { sound.stop() }
                sound.play()
            }
        }
    }

    // MARK: - Sound table

    private static func soundName(for event: FeedbackEvent) -> String? {
        switch event {
        case .recordingStarted: return "Tink"
        case .recordingStopped: return "Pop"
        case .finished: return "Glass"
        case .failed: return "Basso"
        case .cancelled: return "Funk"
        }
    }

    @MainActor private static var cache: [String: NSSound] = [:]

    @MainActor
    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return sound
    }
}
