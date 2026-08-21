import AVFoundation
import Foundation
import VoiceInputCore
import os

/// Speaks text with the voices macOS already has installed.
///
/// `AVSpeechSynthesizer` reads the same voice assets as システム設定 → アクセシビリティ
/// → 読み上げコンテンツ, so a voice the user downloaded there is available here with
/// no extra permission, no network call and no cost. What this adds over the
/// system's own 選択項目を読み上げる is everything around it: the LLM rewrite, one
/// shortcut that works the same in every app, and chunked playback.
@MainActor
public final class SystemSpeechSynthesizer: SpeechSynthesizing {
    private static let log = Logger(subsystem: "io.github.voiceinput", category: "narration")

    private let synthesizer = AVSpeechSynthesizer()
    private let forwarder = DelegateForwarder()

    /// BCP-47 language the voice is picked for, e.g. `ja-JP`. Follows the dictation
    /// locale unless a voice is chosen explicitly.
    public var localeIdentifier: String
    /// A specific system voice, or `nil` to take the best one installed for
    /// `localeIdentifier`.
    public var voiceIdentifier: String?

    public var onQueueDrained: (@MainActor () -> Void)?

    public init(localeIdentifier: String, voiceIdentifier: String? = nil) {
        self.localeIdentifier = localeIdentifier
        self.voiceIdentifier = voiceIdentifier
        synthesizer.delegate = forwarder
        forwarder.onIdle = { [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.onQueueDrained?()
        }
    }

    // MARK: - SpeechSynthesizing

    public var isSpeaking: Bool { synthesizer.isSpeaking }
    public var isPaused: Bool { synthesizer.isPaused }

    public func enqueue(_ text: String, rate: Double) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice()
        utterance.rate = Self.utteranceRate(from: rate)
        // A beat between chunks, so a cut at a paragraph boundary is heard as a
        // paragraph rather than as a hiccup.
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    public func pause() {
        // `.immediate` stops mid-word; `.word` finishes the word first, which is
        // what a listener expects from a pause.
        synthesizer.pauseSpeaking(at: .word)
    }

    public func resume() {
        synthesizer.continueSpeaking()
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Voices

    /// Voices installed for a language, best first, for the Settings picker.
    public static func voices(forLanguage language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { qualityRank($0.quality) > qualityRank($1.quality) }
    }

    /// Whether any voice at all can serve the configured language. Settings uses it
    /// to point the user at the system's voice download rather than letting a
    /// reading fail silently.
    public var hasUsableVoice: Bool { resolveVoice() != nil }

    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }
        if let best = Self.voices(forLanguage: localeIdentifier).first { return best }
        // Last resort: whatever the system considers the default for the language.
        return AVSpeechSynthesisVoice(language: localeIdentifier)
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Maps the stored 0…1 pace onto `AVSpeechUtterance`'s range, whose default sits
    /// at 0.5. Clamped, because a rate of 0 never finishes and 1 is unintelligible
    /// for Japanese.
    static func utteranceRate(from rate: Double) -> Float {
        let clamped = min(max(rate, 0.2), 0.9)
        return Float(clamped)
    }
}

/// Bridges `AVSpeechSynthesizerDelegate` (nonisolated, AppKit-era) onto the main
/// actor. A separate object so `SystemSpeechSynthesizer` can stay `@MainActor`
/// without weakening its isolation to satisfy the delegate protocol.
private final class DelegateForwarder: NSObject, AVSpeechSynthesizerDelegate {
    /// Called after every utterance ends, whether it finished or was cancelled.
    /// Deliberately not `didFinish` only: `stop()` cancels, and the coordinator has
    /// to hear about both.
    var onIdle: (@MainActor () -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        notify()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        notify()
    }

    private func notify() {
        // AVFoundation delivers these on the main thread; the assumption is
        // asserted rather than assumed silently.
        MainActor.assumeIsolated {
            onIdle?()
        }
    }
}
