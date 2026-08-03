import Foundation
import Testing

@testable import VoiceInputCore

/// Carbon masks, repeated here so the test does not import Carbon (Core must not).
private let shift: UInt32 = 1 << 9
private let option: UInt32 = 1 << 11
private let control: UInt32 = 1 << 12
private let command: UInt32 = 1 << 8

@Suite("ModifierHotkeyDetector")
struct ModifierHotkeyDetectorTests {
    // MARK: - Toggle mode

    @Test("⇧⌃ pressed and released on its own fires once, on release")
    func toggleFiresOnRelease() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        #expect(detector.handle(.flagsChanged(shift)) == .none)
        // Still held: no press yet, or the shortcut would fight ⌃⇧-anything.
        #expect(detector.handle(.flagsChanged(shift | control)) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .press)
    }

    @Test("Holding ⇧⌃ and typing a key does not fire — ⌃⇧→ still selects a word")
    func toggleDisarmedByOtherKey() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        _ = detector.handle(.flagsChanged(shift | control))
        #expect(detector.handle(.keyDown) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }

    @Test("Adding a modifier after engaging disarms — ⇧⌃ then ⌘ is some other shortcut")
    func toggleDisarmedByExtraModifier() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        _ = detector.handle(.flagsChanged(shift | control))
        #expect(detector.handle(.flagsChanged(shift | control | command)) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }

    @Test("A modifier already held at engage time disarms")
    func toggleDisarmedByPriorModifier() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        _ = detector.handle(.flagsChanged(command))
        _ = detector.handle(.flagsChanged(command | shift | control))
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }

    @Test("Fires again on the next clean hold")
    func toggleFiresRepeatedly() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        _ = detector.handle(.flagsChanged(shift | control))
        #expect(detector.handle(.flagsChanged(0)) == .press)
        _ = detector.handle(.flagsChanged(shift | control))
        #expect(detector.handle(.flagsChanged(0)) == .press)
    }

    @Test("Unrelated modifiers are ignored entirely")
    func toggleIgnoresUnrelatedModifiers() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        #expect(detector.handle(.flagsChanged(option)) == .none)
        #expect(detector.handle(.flagsChanged(option | command)) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }

    // MARK: - Push to talk

    @Test("Push-to-talk starts on press and stops on release")
    func pushToTalkBrackets() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .pushToTalk)

        #expect(detector.handle(.flagsChanged(shift)) == .none)
        #expect(detector.handle(.flagsChanged(shift | control)) == .press)
        // Extra modifiers mid-hold must not restart or stop the recording.
        #expect(detector.handle(.flagsChanged(shift | control | command)) == .none)
        #expect(detector.handle(.flagsChanged(shift)) == .release)
    }

    @Test("Typing while holding does not stop push-to-talk")
    func pushToTalkSurvivesKeyDown() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .pushToTalk)

        _ = detector.handle(.flagsChanged(shift | control))
        #expect(detector.handle(.keyDown) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .release)
    }

    // MARK: - Edges

    @Test("reset() drops a hold in flight, so a rebind cannot fire the old shortcut")
    func resetDropsHold() {
        var detector = ModifierHotkeyDetector(required: shift | control, mode: .toggle)

        _ = detector.handle(.flagsChanged(shift | control))
        detector.reset()
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }

    @Test("An empty requirement never fires")
    func emptyRequirementNeverFires() {
        var detector = ModifierHotkeyDetector(required: 0, mode: .toggle)

        #expect(detector.handle(.flagsChanged(shift | control)) == .none)
        #expect(detector.handle(.flagsChanged(0)) == .none)
    }
}

@Suite("HotkeyBinding")
struct HotkeyBindingTests {
    @Test("Settings saved before modifier-only support still decode")
    func decodesLegacyBinding() throws {
        let legacy = Data(#"{"keyCode":49,"modifiers":2048}"#.utf8)
        let binding = try JSONDecoder().decode(HotkeyBinding.self, from: legacy)

        #expect(binding == .defaultToggle)
        #expect(binding.isModifierOnly == false)
    }

    @Test("A modifier-only binding survives a round trip")
    func roundTripsModifierOnly() throws {
        let binding = HotkeyBinding.modifiersOnly(shift | control)
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)

        #expect(decoded == binding)
        #expect(decoded.isModifierOnly)
        #expect(decoded.modifierCount == 2)
    }
}
