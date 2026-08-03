import Foundation

/// Narrows the screen's terms down to the ones that plausibly relate to what was
/// actually said.
///
/// This is the load-bearing defence of the whole feature. Because formatting runs
/// **after** transcription, the prompt does not have to carry the screen — it can
/// carry only the words that sound like something the speaker uttered. An
/// attacker who controls the screen therefore cannot place arbitrary text in the
/// prompt: whatever they display is dropped unless the user happens to say
/// something phonetically close to it.
///
/// Two comparisons, deliberately calibrated differently:
///
/// - **Same script.** Cheap and reliable, so the tolerance is tight.
/// - **A latin term against a katakana word.** `VoiceInput` on screen, 「ボイス
///   インプット」 in the transcript. This leans on ICU transliteration, which is
///   approximate enough that a tight tolerance would find almost nothing — so the
///   tolerance is loose, and the blast radius is contained instead by only ever
///   comparing against the transcript's *katakana* runs. Japanese dictation puts
///   loanwords in katakana and little else, which keeps the pool small.
///
/// A missed match costs one candidate, never safety.
public struct ScreenTermMatcher: Sendable {
    /// Upper bound on what reaches the prompt, whatever the screen holds.
    public var limit: Int

    public init(limit: Int = 12) {
        self.limit = limit
    }

    public func candidates(transcript: String, terms: [String]) -> [String] {
        guard !terms.isEmpty else { return [] }

        let runs = ScreenTextScanner.runs(in: transcript).filter { $0.text.count >= 2 }
        let spoken = runs.map { ScreenTextScanner.fold($0.text) }.filter { !$0.isEmpty }
        let spokenKatakana =
            runs
            .filter { $0.script == .katakana }
            .map { ScreenTextScanner.fold($0.text) }
            .filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return [] }

        return
            terms
            .filter { matches($0, spoken: spoken, spokenKatakana: spokenKatakana) }
            .prefix(limit)
            .map { $0 }
    }

    private func matches(
        _ term: String,
        spoken: [String],
        spokenKatakana: [String]
    ) -> Bool {
        let folded = ScreenTextScanner.fold(term)
        guard !folded.isEmpty else { return false }
        if spoken.contains(where: { Self.isNear(folded, $0, tolerance: Self.strict) }) {
            return true
        }

        guard
            !spokenKatakana.isEmpty,
            term.contains(where: { $0.isASCII && $0.isLetter }),
            let kana = ScreenTextScanner.kanaReading(of: term),
            kana != folded
        else {
            return false
        }
        return spokenKatakana.contains(where: { Self.isNear(kana, $0, tolerance: Self.loose) })
    }

    // MARK: - Closeness

    /// A misrecognition within the same script is a character or two out.
    static let strict: (Int) -> Int = { longer in max(1, longer / 3) }
    /// Transliteration noise is much larger than recognition noise; see the type
    /// comment for why this is safe to allow.
    static let loose: (Int) -> Int = { longer in max(1, longer * 3 / 5) }

    /// Close enough to be a plausible misrecognition of one another.
    ///
    /// Containment covers the case where the speaker was understood and only the
    /// spelling needs fixing; edit distance covers the rest.
    static func isNear(_ lhs: String, _ rhs: String, tolerance: (Int) -> Int) -> Bool {
        guard lhs.count >= 2, rhs.count >= 2 else { return false }

        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)

        // Containment, but not of a fragment: "in" turning up inside "VoiceInput"
        // says nothing, while 「入力」 inside 「音声入力」 says a lot. Either the
        // shorter side is a word in its own right, or it is most of the longer one.
        if shorter >= 3 || shorter * 2 >= longer {
            if lhs.contains(rhs) || rhs.contains(lhs) { return true }
        }

        // Wildly different lengths are not misrecognitions of each other, and
        // skipping them keeps the distance calculation off long pairs.
        guard longer <= shorter * 2 else { return false }

        return ScreenTextScanner.editDistance(lhs, rhs) <= tolerance(longer)
    }
}
