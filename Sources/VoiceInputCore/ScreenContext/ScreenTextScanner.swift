import Foundation

/// Text plumbing for `ScreenContextGuard`: splitting a string into word-like runs,
/// and folding a string into a comparable key.
///
/// Both exist so the guard can ask whether a span of the output also appears on
/// screen without punctuation, spacing or casing deciding the answer — those differ
/// between a rendered UI and a sentence for reasons that say nothing about where
/// the text came from.
///
/// Japanese does not put spaces between words, so splitting on whitespace finds
/// nothing useful in 「これはVoiceInputです」. Splitting on **script changes**
/// does: hiragana / katakana / kanji / latin boundaries land close enough to word
/// boundaries for this purpose, and it needs no dictionary and no framework —
/// which matters, because `VoiceInputCore` may not import NaturalLanguage.
enum ScreenTextScanner {
    enum Script: Equatable {
        case latin
        case katakana
        case hiragana
        case han
        /// Punctuation, whitespace, symbols — a boundary, never part of a run.
        case separator
    }

    static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x30_40...0x30_9F:
            return .hiragana
        // Katakana, phonetic extensions, halfwidth katakana. `・` (30FB) is a
        // separator despite living in the block.
        case 0x30_FB:
            return .separator
        case 0x30_A0...0x30_FF, 0x31_F0...0x31_FF, 0xFF_66...0xFF_9F:
            return .katakana
        case 0x4E_00...0x9F_FF, 0x34_00...0x4D_BF, 0xF9_00...0xFA_FF:
            return .han
        default:
            break
        }

        let character = Character(scalar)
        if character.isLetter || character.isNumber || scalar == "_" {
            return .latin
        }
        return .separator
    }

    struct Run: Equatable {
        var text: String
        var script: Script
    }

    /// Split into maximal same-script runs, dropping separators.
    static func runs(in text: String) -> [Run] {
        var result: [Run] = []
        var current = ""
        var currentScript: Script = .separator

        func flush() {
            if !current.isEmpty, currentScript != .separator {
                result.append(Run(text: current, script: currentScript))
            }
            current = ""
        }

        for character in text {
            // A Character can be several scalars (é, emoji); classify by the first.
            guard let first = character.unicodeScalars.first else { continue }
            let script = script(of: first)
            if script != currentScript {
                flush()
                currentScript = script
            }
            if script != .separator {
                current.append(character)
            }
        }
        flush()
        return result
    }

    /// Case-, width- and diacritic-insensitive form, with katakana folded to
    /// hiragana and the prolonged-sound mark dropped, so ボイス / ぼいす / ボイズ
    /// compare closely.
    static func fold(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: nil
        )
        let hiragana =
            folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
        return hiragana.filter { $0 != "ー" && $0 != "・" && $0 != "ｰ" }
    }

}
