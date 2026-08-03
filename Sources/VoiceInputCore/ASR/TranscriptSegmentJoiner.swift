import Foundation

/// Stitches the pieces a streaming recognizer hands back into one transcript.
///
/// Apple's on-device recognizer does not return a whole dictation in one go: it
/// ends a recognition task at every utterance boundary it detects and hard-stops
/// at roughly a minute of audio. Each of those pieces is a finished sentence or
/// two, and the engine has to concatenate them itself.
///
/// The only interesting question is what goes *between* two pieces. English needs
/// a space or the last word of one segment runs into the first word of the next;
/// Japanese does not, and a stray space there survives into the clipboard whenever
/// LLM formatting is off.
public enum TranscriptSegmentJoiner {
    /// Joins `segments` in order, dropping empty ones and inserting a separator
    /// only where the writing system needs it.
    public static func join(_ segments: [String]) -> String {
        let cleaned =
            segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var result = cleaned.first else { return "" }

        for segment in cleaned.dropFirst() {
            if needsSeparator(after: result, before: segment) {
                result += " "
            }
            result += segment
        }
        return result
    }

    /// A separator is needed unless either side of the seam is scriptio continua —
    /// Japanese, Chinese, or the full-width punctuation that goes with them.
    static func needsSeparator(after left: String, before right: String) -> Bool {
        guard let last = left.unicodeScalars.last,
            let first = right.unicodeScalars.first
        else { return false }
        return !isContinuousScript(last) && !isContinuousScript(first)
    }

    private static func isContinuousScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK symbols and punctuation (、。「」…)
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xF900...0xFAFF,  // CJK Compatibility Ideographs
            0xFF00...0xFFEF:  // Half-width and full-width forms
            return true
        default:
            return false
        }
    }
}
