import Foundation

/// The text that was readable on the frontmost window when a dictation started.
///
/// The feature this backs is **off by default** (`AppSettings.screenContextEnabled`)
/// because collecting it needs the screen-recording permission and, when a cloud
/// provider is configured, sends a slice of the screen off the machine.
///
/// ## Why the whole text, and not a word list
///
/// This started out passing isolated words: OCR output was reduced to proper-noun
/// candidates, then narrowed to the ones that sounded like something the speaker
/// had said, and only those reached the prompt. That shape was safer, and it did
/// not work. Measured over sixty-odd candidates it corrected one word, because
/// phonetic narrowing is the wrong instrument for the errors a recogniser actually
/// makes:
///
/// - An acronym comes back as kana (「エスキューエル」 for `SQL`) and no transliteration
///   of `SQL` resembles it, so the match never happens.
/// - Two words collapse into one katakana run (「デプロイトロールバック」 for 「デプロイとか
///   ロールバック」) and a word list cannot split them apart.
/// - A misread on screen (`管埋画面` for `管理画面`) is indistinguishable from a rare
///   correct spelling, so it gets offered with the same authority.
///
/// A model reading the surrounding text resolves all three, because the context is
/// what says which words are plausible. The dictation that produced nothing from a
/// four-word candidate list produced `SQL`, `API` and 「接続設定を見直して」 from the
/// text those words came from.
///
/// ## What that costs
///
/// The word list was a structural guarantee: a sentence could not be represented in
/// it, so screen text could not read as an instruction, and the phonetic gate bound
/// the attack surface to the user's own speech. Both are gone. What remains is a
/// data fence the model is told not to obey, an inspection of the output
/// (`ScreenContextGuard`), and the shape of the result — formatting produces text,
/// and an `ActionOutcome` cannot name a command, a destination or a URL.
///
/// The exposure is the honest cost. Anything legible in the frontmost window
/// reaches the configured provider, including text written by other people.
/// `ScreenSecretRedactor` blanks key-shaped runs on the way into the prompt, which
/// recovers what the old word filter dropped as a side effect, but prose has no
/// shape to key on and is sent. `docs/SECURITY.md` states this in full, and it is
/// why the feature stays off until someone turns it on.
public struct ScreenContext: Sendable, Equatable {
    /// The OCR text, lines joined with newlines.
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public static let empty = ScreenContext(text: "")

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
