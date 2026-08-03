import Foundation

/// What was readable on screen when a dictation started, reduced to something
/// safe enough to show a language model.
///
/// The feature this backs is **off by default** (`AppSettings.screenContextEnabled`)
/// because collecting it needs the screen-recording permission and, when a cloud
/// provider is configured, sends a slice of the screen off the machine.
///
/// The two fields have deliberately different privileges:
///
/// - `terms` is the only part that is ever put in a prompt. It holds isolated
///   tokens — no whitespace, bounded length — so a sentence found on screen
///   cannot survive into the prompt as a sentence, and therefore cannot read as
///   an instruction. See `ScreenTermExtractor` for the filter that guarantees it.
/// - `fullText` **never leaves the process.** It exists so `ScreenContextGuard`
///   can ask the one question that matters after the fact: did anything from the
///   screen end up in the output that the speaker did not say?
public struct ScreenContext: Sendable, Equatable {
    /// Candidate spellings to offer the model. Already filtered and capped.
    public var terms: [String]

    /// Everything OCR could read, joined. Local-only, for validation.
    public var fullText: String

    public init(terms: [String], fullText: String) {
        self.terms = terms
        self.fullText = fullText
    }

    public static let empty = ScreenContext(terms: [], fullText: "")

    public var isEmpty: Bool { terms.isEmpty }
}

/// Supplies `ScreenContext`. Implemented in `VoiceInputPlatform`, where
/// ScreenCaptureKit and Vision live.
///
/// Intentionally non-throwing: a screen read is an optional accuracy aid, never a
/// reason to fail a dictation. A denied permission, a failed capture and a blank
/// screen all look the same from here — `.empty`.
public protocol ScreenContextProviding: Sendable {
    func currentContext() async -> ScreenContext
}

/// Used when the feature is off, and in tests.
public struct EmptyScreenContextProvider: ScreenContextProviding {
    public init() {}
    public func currentContext() async -> ScreenContext { .empty }
}
