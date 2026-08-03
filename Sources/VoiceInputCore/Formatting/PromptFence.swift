import Foundation

/// Every data fence the app's prompts use, and the one function that defuses them.
///
/// Delimiter injection is the same problem in every prompt the app builds: a
/// speaker — or a mis-recognition — must not be able to close a fence early and
/// have what follows read as prompt rather than as data. Keeping one list means a
/// fence introduced for a new action is neutralised inside the older prompts too,
/// so `<question>` spoken into a dictation is as inert as `</transcript>` is.
enum PromptFence {
    /// Closing tags come first: rewriting `<question>` before `</question>` would
    /// leave a stray `[question]>` behind.
    static let all: [(tag: String, replacement: String)] = [
        (FormattingPromptBuilder.closingTag, "[/transcript]"),
        (FormattingPromptBuilder.openingTag, "[transcript]"),
        (FormattingPromptBuilder.screenClosingTag, "[/screen_terms]"),
        (FormattingPromptBuilder.screenOpeningTag, "[screen_terms]"),
        (AskPromptBuilder.closingTag, "[/question]"),
        (AskPromptBuilder.openingTag, "[question]"),
    ]

    static func neutralize(_ text: String) -> String {
        all.reduce(text) { partial, fence in
            partial.replacingOccurrences(
                of: fence.tag,
                with: fence.replacement,
                options: [.caseInsensitive]
            )
        }
    }
}
