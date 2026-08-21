import AppKit
import Foundation
import VoiceInputCore

/// Reads whatever is already on the clipboard.
///
/// This exists because of where the text usually comes from. A coding agent's
/// answer, a chat reply, a documentation page: each of them renders in a view that
/// has its own copy button, and pressing it is one click. Selecting the same text
/// by hand is not, especially in a terminal where the answer spans a scrollback
/// boundary.
///
/// Compared with `SelectedTextReader`, the trade is deliberate:
///
/// - **No keystroke is synthesised**, so the Accessibility permission is not
///   involved at all. The feature works on a machine where the user has granted
///   nothing.
/// - **The pasteboard is left exactly as it was.** Nothing is written, and the
///   read is a plain `string(forType:)`.
/// - **What is read is whatever was copied last**, which may be older than the
///   user thinks. The cost of that mistake is a wrong reading, not a lost
///   clipboard, and stopping is one press away.
@MainActor
public struct ClipboardTextReader: NarrationSourceReading {
    public init() {}

    public func read() async throws -> String {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputError.clipboardEmpty
        }
        return text
    }
}
