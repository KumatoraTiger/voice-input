import AppKit
import Carbon.HIToolbox
import Foundation
import VoiceInputCore

/// Conversions between `HotkeyBinding` (Carbon key code + Carbon modifier mask),
/// `NSEvent` (what a recorder field sees) and the ⌥Space style label shown in the UI.
public enum HotkeyFormatting {
    // MARK: - NSEvent → HotkeyBinding

    /// Builds a key-plus-modifiers binding from a key-down event captured by a
    /// recorder field.
    ///
    /// Returns `nil` for events that would make a useless shortcut: a bare key with
    /// no modifiers, or a press of a modifier key on its own. A modifier-only
    /// shortcut never produces a key-down event at all — see
    /// `modifierOnlyBinding(from:)`.
    public static func binding(from event: NSEvent) -> HotkeyBinding? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else { return nil }

        let keyCode = UInt32(event.keyCode)
        guard !modifierKeyCodes.contains(keyCode) else { return nil }

        return HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Builds a modifier-only binding (⇧⌃, ⌥⌘, …) from a `flagsChanged` event.
    ///
    /// Requires **two** modifiers: a single one would fire whenever the user typed
    /// a capital letter or reached for any other shortcut.
    public static func modifierOnlyBinding(from event: NSEvent) -> HotkeyBinding? {
        guard event.type == .flagsChanged else { return nil }
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers.nonzeroBitCount >= 2 else { return nil }
        return .modifiersOnly(modifiers)
    }

    /// Maps `NSEvent.ModifierFlags` onto the Carbon mask `RegisterEventHotKey` wants.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    // MARK: - HotkeyBinding → display

    /// e.g. `⌥Space`, `⌃⇧D`, or `⌃⇧` for a modifier-only shortcut. Modifiers use
    /// Apple's canonical ⌃⌥⇧⌘ order.
    public static func displayString(for binding: HotkeyBinding) -> String {
        var result = modifierString(for: binding.modifiers)
        if let keyCode = binding.keyCode {
            result += keyName(for: keyCode)
        }
        return result
    }

    /// Just the ⌃⌥⇧⌘ glyphs, in Apple's canonical order.
    public static func modifierString(for modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    /// Label for a single key.
    ///
    /// Uses a fixed ANSI table rather than `UCKeyTranslate` on the active input
    /// source: `RegisterEventHotKey` binds by physical key code, so the label must
    /// stay stable when the user switches to a Japanese or Dvorak layout.
    public static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let character = ansiKeyNames[keyCode] { return character }
        return "Key \(keyCode)"
    }

    // MARK: - Tables

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function),
    ]

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
    ]

    private static let ansiKeyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
    ]
}
