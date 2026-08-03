import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Hotkey plan")
struct HotkeyPlanTests {
    private static func settings(styles: [FormattingStyle]) -> AppSettings {
        var settings = AppSettings()
        settings.styles = styles
        return settings
    }

    private static func style(
        _ name: String,
        keyCode: UInt32?,
        modifiers: UInt32 = 1 << 12
    ) -> FormattingStyle {
        FormattingStyle(
            name: name,
            instructions: "",
            hotkey: HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
        )
    }

    @Test("the dictation shortcut is always planned, even with no styles")
    func dictationAlwaysPresent() {
        var settings = AppSettings()
        settings.styles = []

        let plan = HotkeyPlan.make(for: settings)

        #expect(plan.assignments.count == 1)
        #expect(plan.assignments.first?.purpose == .dictation)
        #expect(plan.assignments.first?.binding == HotkeyBinding.defaultToggle)
        #expect(plan.rejections.isEmpty)
    }

    @Test("styles with a shortcut are planned in Settings order")
    func stylesArePlanned() {
        let first = Self.style("チャット", keyCode: 18)
        let second = Self.style("メール", keyCode: 19)
        let plan = HotkeyPlan.make(
            for: Self.settings(styles: [
                first,
                FormattingStyle(name: "ショートカットなし", instructions: ""),
                second,
            ])
        )

        #expect(
            plan.assignments.map(\.purpose) == [
                .dictation, .style(first.id), .style(second.id),
            ]
        )
        #expect(plan.rejections.isEmpty)
    }

    @Test("a style takes the dictation shortcut's mode, so push-to-talk applies to both")
    func modeIsShared() {
        var settings = Self.settings(styles: [Self.style("チャット", keyCode: 18)])
        settings.hotkeyMode = .pushToTalk

        let plan = HotkeyPlan.make(for: settings)

        #expect(plan.assignments.allSatisfy { $0.mode == .pushToTalk })
    }

    @Test("a style that collides with the dictation shortcut is rejected, not registered")
    func collisionWithDictationShortcut() {
        var settings = Self.settings(styles: [])
        let clashing = FormattingStyle(
            name: "重複",
            instructions: "",
            hotkey: settings.hotkey
        )
        settings.styles = [clashing]

        let plan = HotkeyPlan.make(for: settings)

        #expect(plan.assignments.map(\.purpose) == [.dictation])
        #expect(plan.rejections[clashing.id] == .duplicate(settings.hotkey))
    }

    @Test("two styles on the same combination: the first keeps it")
    func collisionBetweenStyles() {
        let first = Self.style("先", keyCode: 18)
        let second = Self.style("後", keyCode: 18)

        let plan = HotkeyPlan.make(for: Self.settings(styles: [first, second]))

        #expect(plan.assignments.map(\.purpose) == [.dictation, .style(first.id)])
        #expect(plan.rejections[second.id] == .duplicate(second.hotkey!))
        #expect(plan.rejections[first.id] == nil)
    }

    @Test("the same key with different modifiers is not a collision")
    func differentModifiersAreDistinct() {
        let first = Self.style("先", keyCode: 18, modifiers: 1 << 12)
        let second = Self.style("後", keyCode: 18, modifiers: 1 << 9)

        let plan = HotkeyPlan.make(for: Self.settings(styles: [first, second]))

        #expect(plan.assignments.count == 3)
        #expect(plan.rejections.isEmpty)
    }

    @Test("a modifier-only style shortcut is rejected: that path is the main one's alone")
    func modifierOnlyStyleRejected() {
        let modifierOnly = Self.style("修飾のみ", keyCode: nil, modifiers: (1 << 9) | (1 << 12))

        let plan = HotkeyPlan.make(for: Self.settings(styles: [modifierOnly]))

        #expect(plan.assignments.map(\.purpose) == [.dictation])
        #expect(plan.rejections[modifierOnly.id] == .modifierOnlyUnsupported)
    }

    @Test("a modifier-only dictation shortcut is still planned")
    func modifierOnlyDictationAllowed() {
        var settings = AppSettings()
        settings.hotkey = .modifiersOnly((1 << 9) | (1 << 12))

        let plan = HotkeyPlan.make(for: settings)

        #expect(plan.assignments.first?.binding.isModifierOnly == true)
        #expect(plan.rejections.isEmpty)
    }

    @Test("purpose carries the style id, and the dictation purpose carries none")
    func purposeStyleID() {
        let id = UUID()
        #expect(HotkeyPurpose.style(id).styleID == id)
        #expect(HotkeyPurpose.dictation.styleID == nil)
    }
}
