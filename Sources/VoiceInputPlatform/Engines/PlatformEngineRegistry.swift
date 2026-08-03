import Foundation
import VoiceInputCore

/// The engine list the running app sees.
///
/// Every `TranscriptionEngineID` resolves to an engine, including ones this build
/// cannot actually run — an unavailable engine explains itself in Settings, which
/// is far more useful than an id that maps to nothing.
public struct PlatformEngineRegistry: TranscriptionEngineResolving {
    public let engines: [any TranscriptionEngine]

    /// - Parameters:
    ///   - secrets: passed straight through to Core's cloud engine. The platform
    ///     layer never reads or stores the key itself; it only wires up the lookup.
    ///   - cloudEngine: override for tests, or to swap in a different cloud backend.
    public init(
        secrets: any SecretStore,
        cloudEngine: (any TranscriptionEngine)? = nil
    ) {
        var engines: [any TranscriptionEngine] = [AppleOnDeviceEngine()]
        engines.append(Self.makeSpeechAnalyzerEngine())
        engines.append(cloudEngine ?? OpenAITranscriptionEngine(secrets: secrets))
        self.engines = engines
    }

    /// Escape hatch for previews and tests.
    public init(engines: [any TranscriptionEngine]) {
        self.engines = engines
    }

    public func engine(for id: TranscriptionEngineID) -> (any TranscriptionEngine)? {
        engines.first { $0.id == id }
    }

    /// The real SpeechAnalyzer adapter only exists when the binary was built with a
    /// macOS 26 SDK *and* is running on macOS 26; otherwise a stub keeps the id
    /// resolvable and reports `.unsupportedOS`.
    private static func makeSpeechAnalyzerEngine() -> any TranscriptionEngine {
        #if SPEECH_ANALYZER
        if #available(macOS 26, *) {
            return SpeechAnalyzerEngine()
        }
        return UnavailableEngine.speechAnalyzer(
            reason: "SpeechAnalyzer は macOS 26 以降が必要です"
        )
        #else
        return UnavailableEngine.speechAnalyzer()
        #endif
    }
}
