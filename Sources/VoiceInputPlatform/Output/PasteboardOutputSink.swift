import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VoiceInputCore

/// Delivers finished text through the system pasteboard, optionally following up
/// with a synthesised ⌘V into whatever app has focus.
public struct PasteboardOutputSink: OutputSink {
    /// Virtual key code for `V` on every keyboard layout (layout-independent).
    private static let keyCodeV: CGKeyCode = 9

    /// Gap between writing the pasteboard and posting ⌘V. The hotkey handler runs
    /// while our own menu-bar UI may still be the key window, so the frontmost app
    /// needs a moment to take focus back before it will accept the keystroke.
    private let pasteDelay: Duration

    public init(pasteDelay: Duration = .milliseconds(120)) {
        self.pasteDelay = pasteDelay
    }

    public var canPaste: Bool { AXIsProcessTrusted() }

    public func copy(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw VoiceInputError.transcriptionFailed("クリップボードへの書き込みに失敗しました。")
        }
    }

    public func paste(_ text: String) async throws {
        guard canPaste else { throw VoiceInputError.accessibilityPermissionDenied }

        try copy(text)
        try? await Task.sleep(for: pasteDelay)

        // The previous pasteboard contents are deliberately NOT restored. The paste
        // target reads the pasteboard asynchronously and on its own schedule, so any
        // restore we schedule either races that read (pasting the user's old
        // clipboard instead of the dictation) or lands so late it is useless. Leaving
        // the dictated text on the pasteboard also matches
        // `ActionOutcome.copyToClipboard`, which the user expects to hold after a
        // dictation.
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw VoiceInputError.accessibilityPermissionDenied
        }
        // Without this the user physically holding the hotkey's modifiers would leak
        // into the synthesised event (e.g. ⌥⌘V instead of ⌘V).
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.keyCodeV,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.keyCodeV,
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
