import Foundation

/// Checks a formatted result for text that came from the screen rather than from
/// the speaker.
///
/// ## What it is for
///
/// Since the prompt carries the screen's text rather than a filtered word list,
/// this is the only remaining check that does not depend on the model behaving.
/// It cannot make contamination unlikely; it makes it *detectable*, which is what
/// allows the dictation to recover instead of pasting the result.
///
/// ## The question it asks
///
/// Formatting has a narrow contract: clean up the transcript, add no information.
/// Screen context widens it by one allowance — the model may re-spell a word it
/// recognises on screen. A respelling is *short*: `SQL`, `API`, a product name.
/// So the output is suspect when it contains a **long** span that
///
/// - appears in what OCR read, and
/// - does **not** appear in the transcript.
///
/// That is the signature of both failure modes at once: an injected instruction the
/// model obeyed, and screen content the model simply copied. Neither can happen
/// without screen text surfacing in the output at length.
///
/// ## Why it does not fire on ordinary formatting
///
/// The check is on long spans. Deleting fillers, adding punctuation, reordering a
/// clause and fixing a homophone all produce short, local changes that are not
/// lifted from the screen. A creative custom style can rewrite freely without
/// tripping this, because rewriting does not reproduce screen text.
///
/// Two false-positive paths remain, and both cost only a retry: a common phrase
/// that happens to be on screen, in the output, and absent from the transcript; and
/// a legitimate correction longer than `minimumRun`, such as an identifier like
/// `DATABASE_CONNECTION_TIMEOUT` being spelled out from the screen. The second is
/// the price of dropping the sanctioned-term list — with no list, a long correction
/// and a long copy look alike.
///
/// ## What the verdict deliberately omits
///
/// The offending text itself. It is screen content, so putting it in a log line
/// or an error message would leak the very thing this type exists to contain.
/// A length is enough to act on and safe to record — the same reasoning as
/// `VoiceInputError.kind`.
public struct ScreenContextGuard: Sendable {
    /// How many characters of screen text, unexplained by the transcript, count
    /// as contamination. Short coincidences are not interesting; a sentence is.
    public var minimumRun: Int

    public init(minimumRun: Int = 12) {
        self.minimumRun = minimumRun
    }

    public struct Verdict: Sendable, Equatable {
        public var isContaminated: Bool
        /// Longest offending span, in normalised characters. Zero when clean.
        public var offendingLength: Int

        public static let clean = Verdict(isContaminated: false, offendingLength: 0)

        public init(isContaminated: Bool, offendingLength: Int) {
            self.isContaminated = isContaminated
            self.offendingLength = offendingLength
        }
    }

    public func inspect(
        output: String,
        transcript: String,
        screenText: String
    ) -> Verdict {
        let screen = Self.compact(screenText)
        guard screen.count >= minimumRun else { return .clean }

        let spoken = Self.compact(transcript)
        let produced = Self.compact(output)
        guard produced.count >= minimumRun else { return .clean }

        // A span sitting inside a single word run on screen is one word, however
        // long, and one word is the thing the model is allowed to take. Identifiers
        // are what make this necessary: `DATABASE_CONNECTION_TIMEOUT` and
        // `ScreenCaptureKit` are longer than `minimumRun` and are exactly the
        // spellings the feature exists to fix, so length alone cannot separate a
        // respelling from a copy. Word count can — an instruction, or a sentence
        // lifted from the screen, needs more than one word to exist. That is the
        // argument the discarded token-only filter used to make at extraction time,
        // applied here instead.
        let screenWords = Set(
            ScreenTextScanner.runs(in: screenText).map { ScreenTextScanner.fold($0.text) }
        )

        var longest = 0
        let characters = Array(produced)

        for start in characters.indices {
            var end = start + minimumRun
            while end <= characters.count {
                let span = String(characters[start..<end])
                // Nothing longer can be on screen either, so stop extending.
                guard screen.contains(span) else { break }
                if !spoken.contains(span), !screenWords.contains(where: { $0.contains(span) }) {
                    longest = max(longest, span.count)
                }
                end += 1
            }
        }

        return Verdict(isContaminated: longest > 0, offendingLength: longest)
    }

    // MARK: - Normalisation

    /// Word runs only, folded: punctuation, spacing and casing differ between a
    /// screen and a sentence for reasons that say nothing about provenance.
    static func compact(_ text: String) -> String {
        ScreenTextScanner.fold(
            ScreenTextScanner.runs(in: text).map(\.text).joined()
        )
    }
}
