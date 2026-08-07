import Foundation

/// Blanks out secret-shaped strings in OCR text before it reaches a prompt.
///
/// The word-list design this feature replaced dropped these for free: a filter that
/// only kept proper-noun-shaped tokens also rejected long letter-and-digit runs, so
/// a key visible on screen was never a candidate. Sending the text gives that up,
/// but only because it was a *side effect* of the filter — the shape test itself
/// still works, applied as redaction instead of selection.
///
/// ## What counts as secret-shaped
///
/// Word runs are split on anything that is not a letter, a digit or `_`, so a real
/// key comes apart at its punctuation and the high-entropy part is examined on its
/// own: `sk-proj-AbC123…` splits into `sk`, `proj`, `AbC123…`, and a JWT splits at
/// its dots into three long base64 runs. A run is redacted when it is
///
/// - at least `minimumMixedLength` characters and mixes letters with digits, or
/// - at least `minimumDigitLength` characters and is all digits — a card or account
///   number.
///
/// ## What this is not
///
/// It is a mitigation, not a guarantee, and the difference matters because the
/// earlier version of this feature documented a guarantee it later stopped
/// providing. It does not recognise:
///
/// - a secret with no digits in it, such as a hex string that happens to avoid
///   `0`–`9`;
/// - anything shorter than the thresholds, including short tokens and PINs;
/// - **prose**, which is the larger exposure. Another person's message, a customer
///   name and a medical record have no shape to key on, and they are sent.
///
/// `docs/SECURITY.md` states the exposure in those terms. This type narrows one
/// class of it.
public struct ScreenSecretRedactor: Sendable {
    /// Stands in for a redacted run. Short, so the output check cannot mistake it
    /// for a copied span, and obviously not screen content.
    public static let placeholder = "[redacted]"

    /// Length at which a letters-and-digits run stops looking like an identifier
    /// someone would dictate. Matches the threshold the deleted word filter used.
    public var minimumMixedLength: Int
    /// Length at which an all-digit run stops looking like a quantity or a year.
    /// Thirteen keeps dates, prices and version numbers out of it.
    public var minimumDigitLength: Int

    public init(minimumMixedLength: Int = 16, minimumDigitLength: Int = 13) {
        self.minimumMixedLength = minimumMixedLength
        self.minimumDigitLength = minimumDigitLength
    }

    public func redact(_ text: String) -> String {
        var result = ""
        var run = ""

        func flush() {
            guard !run.isEmpty else { return }
            result += isSecretShaped(run) ? Self.placeholder : run
            run = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    func isSecretShaped(_ run: String) -> Bool {
        let characters = Array(run)
        let digits = characters.filter(\.isNumber).count
        let letters = characters.filter(\.isLetter).count

        if characters.count >= minimumDigitLength, letters == 0, digits == characters.count {
            return true
        }
        return characters.count >= minimumMixedLength && digits > 0 && letters > 0
    }
}
