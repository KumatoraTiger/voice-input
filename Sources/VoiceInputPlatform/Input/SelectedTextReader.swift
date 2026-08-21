import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VoiceInputCore

/// Reads whatever the user has selected in the frontmost app, by synthesising ⌘C
/// and taking the result off the pasteboard.
///
/// Three deliberate choices:
///
/// - **⌘C rather than the Accessibility text API.** `AXSelectedText` works in
///   native text views and returns nothing in a terminal, in Electron apps, and in
///   most browsers — which is where an agent's answer or a web page actually is.
///   Copy is the one path every app implements.
/// - **The pasteboard is put back.** Unlike `PasteboardOutputSink.paste`, nothing
///   downstream is waiting to read this, so restoring is safe: reading text aloud
///   must not cost the user the clipboard they were about to paste.
/// - **Nothing is kept.** The text is returned and never stored, logged, or
///   written to disk.
@MainActor
public final class SelectedTextReader: NarrationSourceReading {
    /// Virtual key code for `C`, layout-independent.
    private static let keyCodeC: CGKeyCode = 8

    /// How long to wait for the frontmost app to answer the ⌘C, polled in short
    /// steps. An app that has not written to the pasteboard by then is treated as
    /// having nothing selected.
    private let copyTimeout: Duration
    private let pollInterval: Duration

    public init(
        copyTimeout: Duration = .milliseconds(500),
        pollInterval: Duration = .milliseconds(20)
    ) {
        self.copyTimeout = copyTimeout
        self.pollInterval = pollInterval
    }

    public func read() async throws -> String {
        // Synthesising a keystroke into another app is exactly what the
        // Accessibility permission governs, so the same error as auto-paste.
        guard AXIsProcessTrusted() else { throw VoiceInputError.accessibilityPermissionDenied }

        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount
        let previous = pasteboard.string(forType: .string)

        try postCopyShortcut()

        // Wait for the app to answer. `changeCount` is the only reliable signal:
        // the string may be identical to what was already on the pasteboard.
        var elapsed = Duration.zero
        while pasteboard.changeCount == changeCountBefore, elapsed < copyTimeout {
            try? await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            elapsed += pollInterval
        }
        guard pasteboard.changeCount != changeCountBefore else {
            throw VoiceInputError.nothingToRead
        }

        let copied = pasteboard.string(forType: .string) ?? ""

        // Put the user's clipboard back. Skipped when there was nothing to restore,
        // so an empty pasteboard is left empty rather than cleared again.
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        guard !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputError.nothingToRead
        }
        return copied
    }

    private func postCopyShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw VoiceInputError.accessibilityPermissionDenied
        }
        // Without this, modifiers the user is still physically holding from the
        // shortcut leak into the synthesised event (⌥⌘C instead of ⌘C).
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.keyCodeC,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.keyCodeC,
                keyDown: false
            )
        else {
            throw VoiceInputError.accessibilityPermissionDenied
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
