import Foundation

/// Recognises a modifier-only shortcut (⇧⌃, ⌥⌘, …) from a stream of modifier-flag
/// changes.
///
/// Carbon's `RegisterEventHotKey` can only bind a *key* plus modifiers, so a
/// modifier-only shortcut has to be detected by watching `flagsChanged` events.
/// The rule that keeps ⇧⌃ from firing every time the user presses ⌃⇧→ to select a
/// word is: in `.toggle` mode the shortcut fires **on release**, and only if
/// nothing else happened while the modifiers were held — no other key went down,
/// and no additional modifier joined in.
///
/// `.pushToTalk` needs no such guard: it starts on press and stops on release,
/// which is exactly the gesture the user is making.
///
/// Lives in Core (rather than next to `HotkeyMonitor`) so the state machine is
/// unit-testable without AppKit.
public struct ModifierHotkeyDetector: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        /// The complete set of modifiers currently held, as a Carbon mask.
        case flagsChanged(UInt32)
        /// A non-modifier key went down. Disqualifies the current hold.
        case keyDown
    }

    public enum Output: Sendable, Equatable {
        case none
        case press
        case release
    }

    /// The modifier mask that has to be held. Never 0 for a usable detector.
    public let required: UInt32
    public let mode: HotkeyMode

    /// The required modifiers are currently held.
    private var isEngaged = false
    /// The hold is still a candidate: no extra modifier, no other key.
    private var isArmed = false

    public init(required: UInt32, mode: HotkeyMode) {
        self.required = required
        self.mode = mode
    }

    /// The required modifiers are held right now.
    ///
    /// `HotkeyMonitor` uses this to keep its key-down monitor installed *only*
    /// during a hold: the detector needs to know that some other key was pressed,
    /// but there is no reason for the app to watch the keyboard the rest of the
    /// time. See `docs/SECURITY.md`.
    public var isHolding: Bool { isEngaged }

    public mutating func handle(_ input: Input) -> Output {
        switch input {
        case .keyDown:
            isArmed = false
            return .none

        case .flagsChanged(let mask):
            let wasEngaged = isEngaged
            let engaged = required != 0 && (mask & required) == required
            isEngaged = engaged

            if engaged {
                if !wasEngaged {
                    // An extra modifier already down at engage time (⌘ then ⇧⌃)
                    // means the user is reaching for some other shortcut.
                    isArmed = mask == required
                    return mode == .pushToTalk ? .press : .none
                }
                if mask != required { isArmed = false }
                return .none
            }

            guard wasEngaged else { return .none }
            switch mode {
            case .pushToTalk:
                return .release
            case .toggle:
                let fires = isArmed
                isArmed = false
                return fires ? .press : .none
            }
        }
    }

    /// Drops any in-flight hold. Call when the binding changes or monitoring stops,
    /// so a shortcut cannot fire from modifiers held across the change.
    public mutating func reset() {
        isEngaged = false
        isArmed = false
    }
}
