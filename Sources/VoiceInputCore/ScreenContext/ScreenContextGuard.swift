import Foundation

/// Checks a formatted result for text that came from the screen rather than from
/// the speaker.
///
/// ## What it is for
///
/// Everything else in this feature makes contamination *unlikely*. This makes it
/// *detectable*, which is a different and stronger property — it is the only
/// layer that can tell, after the model has replied, that something went wrong.
///
/// ## The question it asks
///
/// Formatting has a narrow contract: clean up the transcript, add no information.
/// Screen context widens it by exactly one allowance — the model may re-spell a
/// word using a term we handed it. So the output is suspect when it contains a
/// long span that
///
/// - appears in what OCR read, and
/// - does **not** appear in the transcript, and
/// - is not one of the terms we sanctioned.
///
/// That is the signature of both failure modes at once: an injected instruction
/// the model obeyed, and screen content the model simply copied. Neither can
/// happen without screen text surfacing in the output.
///
/// ## Why it does not fire on ordinary formatting
///
/// The checks are on *long* spans of screen text. Deleting fillers, adding
/// punctuation, reordering a clause and fixing a homophone all produce short,
/// local changes that are not lifted from the screen. A creative custom style can
/// rewrite freely without tripping this, because rewriting does not reproduce
/// screen text. The false-positive path that remains — a common phrase that
/// happens to be on screen, in the output, and absent from the transcript — is
/// bounded by `minimumRun` and costs only a retry.
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
        screenText: String,
        sanctionedTerms: [String]
    ) -> Verdict {
        let screen = Self.compact(screenText)
        guard screen.count >= minimumRun else { return .clean }

        let spoken = Self.compact(transcript)
        let masked = Self.mask(
            Self.compact(output),
            removing: sanctionedTerms.map(Self.compact)
        )
        guard masked.count >= minimumRun else { return .clean }

        var longest = 0
        let characters = Array(masked)

        for start in characters.indices {
            var end = start + minimumRun
            while end <= characters.count {
                let span = String(characters[start..<end])
                // The mask is not text the model produced, so a span may not
                // straddle it.
                if span.contains(Self.sentinel) { break }
                // Nothing longer can be on screen either, so stop extending.
                guard screen.contains(span) else { break }
                if !spoken.contains(span) { longest = max(longest, span.count) }
                end += 1
            }
        }

        return Verdict(isContaminated: longest > 0, offendingLength: longest)
    }

    // MARK: - Yield

    /// How many sanctioned terms the model actually put to work: present in the
    /// output, absent from the transcript.
    ///
    /// The same relation `inspect` reasons about, read the other way round.
    /// Contamination is screen text in the output that we did *not* sanction;
    /// yield is screen text in the output that we *did*, and that the recogniser
    /// had not already produced on its own. A term the transcript already spelled
    /// correctly does not count, because the screen changed nothing there.
    ///
    /// This is a count, never the terms, for the reason given above the type.
    ///
    /// It measures application, not benefit. A model can reach the right spelling
    /// without the hint, and this cannot tell that case from a genuine correction;
    /// only formatting the same dictation both ways could. Read it as an upper
    /// bound on what the screen contributed.
    public func appliedTerms(
        output: String,
        transcript: String,
        sanctionedTerms: [String]
    ) -> Int {
        let produced = Self.compact(output)
        let spoken = Self.compact(transcript)

        return
            sanctionedTerms
            .map(Self.compact)
            .filter { !$0.isEmpty }
            .filter { produced.contains($0) && !spoken.contains($0) }
            .count
    }

    // MARK: - Normalisation

    private static let sentinel: Character = "\u{0}"

    /// Word runs only, folded: punctuation, spacing and casing differ between a
    /// screen and a sentence for reasons that say nothing about provenance.
    static func compact(_ text: String) -> String {
        ScreenTextScanner.fold(
            ScreenTextScanner.runs(in: text).map(\.text).joined()
        )
    }

    /// Blanks out the terms we asked the model to use, so using them is not
    /// mistaken for copying from the screen.
    private static func mask(_ text: String, removing terms: [String]) -> String {
        terms
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { partial, term in
                partial.replacingOccurrences(of: term, with: String(sentinel))
            }
    }
}
