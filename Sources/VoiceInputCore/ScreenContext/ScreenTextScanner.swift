import Foundation

/// Shared text plumbing for the screen-context feature: splitting a string into
/// word-like runs, and folding two strings into comparable keys.
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

    /// A rough kana reading of latin text, so a katakana transcript can be
    /// compared with a latin word on screen. ICU's transliteration is
    /// approximate — good enough to rank candidates, not good enough to trust.
    static func kanaReading(of text: String) -> String? {
        let spaced = splitCamelCase(text).joined(separator: " ")
        guard let kana = spaced.applyingTransform(.latinToHiragana, reverse: false) else {
            return nil
        }
        let compact = kana.filter { !$0.isWhitespace }
        return compact.isEmpty ? nil : fold(compact)
    }

    /// `VoiceInputCore` → `["Voice", "Input", "Core"]`; also splits on `_`, `-`
    /// and digit boundaries. Leaves an all-caps word alone.
    static func splitCamelCase(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?

        for character in text {
            if character == "_" || character == "-" {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.isEmpty }
    }

    /// Levenshtein distance, bounded so a pathological input cannot cost much.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int = 64) -> Int {
        let a = Array(lhs.prefix(limit))
        let b = Array(rhs.prefix(limit))
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
