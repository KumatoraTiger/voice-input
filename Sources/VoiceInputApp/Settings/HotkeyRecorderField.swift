import AppKit
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// Click, then press a key combination — either a key with modifiers (⌥Space) or
/// modifiers on their own (⇧⌃).
///
/// Uses a local `NSEvent` monitor (the Settings window is key while recording, so
/// no Accessibility permission is needed) and swallows every key press until a
/// usable combination arrives, so ⌘W does not close the window mid-recording.
///
/// `flagsChanged` is watched as well as `keyDown`, because a modifier-only
/// shortcut produces **no** key-down event at all: without it, holding ⇧⌃ looks to
/// the user like the field is broken. Modifier-only combinations commit on
/// release, so that ⇧ → ⇧⌃ records ⇧⌃ rather than ⇧ alone.
struct HotkeyRecorderField: View {
    @Binding private var binding: HotkeyBinding?
    /// Off for a style shortcut: a modifier-only combination needs an event
    /// monitor and the Accessibility permission, which stays reserved for the one
    /// main dictation shortcut. See `HotkeyPlan`.
    private let allowsModifierOnly: Bool
    /// Only an optional binding can be emptied again.
    private let isClearable: Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?
    /// Largest modifier set seen during the current hold, so releasing commits the
    /// full combination rather than whatever is left on the way up.
    @State private var pendingModifiers: HotkeyBinding?

    /// A shortcut that must always be set — the main dictation one.
    init(binding: Binding<HotkeyBinding>, allowsModifierOnly: Bool = true) {
        self._binding = Binding(
            get: { binding.wrappedValue },
            set: { if let new = $0 { binding.wrappedValue = new } }
        )
        self.allowsModifierOnly = allowsModifierOnly
        self.isClearable = false
    }

    /// An optional shortcut, e.g. the one on a formatting style.
    init(binding: Binding<HotkeyBinding?>, allowsModifierOnly: Bool = false) {
        self._binding = binding
        self.allowsModifierOnly = allowsModifierOnly
        self.isClearable = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isRecording { stop() } else { start() }
                } label: {
                    Text(label)
                        .frame(minWidth: 130)
                        .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("ショートカットキー")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("クリックしてから新しいキーの組み合わせを押します")

                if isClearable, binding != nil, !isRecording {
                    Button("クリア") {
                        binding = nil
                    }
                    .controlSize(.small)
                    .accessibilityLabel("ショートカットキーを解除")
                }
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        guard isRecording else { return binding.map(HotkeyFormatting.displayString(for:)) ?? "未設定" }
        if let pendingModifiers {
            return HotkeyFormatting.displayString(for: pendingModifiers)
        }
        return "キーを押してください…"
    }

    private var accessibilityValue: String {
        binding.map(HotkeyFormatting.displayString(for:)) ?? "未設定"
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        pendingModifiers = nil
        hint =
            allowsModifierOnly
            ? "キーを押すか、修飾キーだけ（例: ⇧⌃）を押して離してください。⎋ でキャンセル。"
            : "修飾キーと通常のキーを組み合わせて押してください（例: ⌃⇧1）。⎋ でキャンセル。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                handleFlagsChanged(event)
                return event
            }
            // Esc cancels without changing anything.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let candidate = HotkeyFormatting.binding(from: event) {
                binding = candidate
                stop()
            } else {
                pendingModifiers = nil
                hint = "そのキーは単独では使えません。修飾キーと組み合わせてください（例: ⌥Space）。"
            }
            return nil
        }
    }

    /// Modifiers are recorded on the way *up*: while any are still held the field
    /// only previews the combination, and the release commits it.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard allowsModifierOnly else { return }

        if let candidate = HotkeyFormatting.modifierOnlyBinding(from: event) {
            pendingModifiers = candidate
            hint =
                "離すと \(HotkeyFormatting.displayString(for: candidate)) に設定します。通常のキーを押すとその組み合わせになります。"
            return
        }

        let stillHeld = HotkeyFormatting.carbonModifiers(from: event.modifierFlags) != 0
        guard !stillHeld else { return }

        guard let pendingModifiers else {
            // Everything let go with only one modifier ever held. Say so, rather
            // than leaving the field looking inert — which is what the old
            // keyDown-only recorder did for every modifier-only attempt.
            hint = "修飾キーだけで設定するには 2 つ以上（例: ⇧⌃）が必要です。⎋ でキャンセル。"
            return
        }
        binding = pendingModifiers
        stop()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        pendingModifiers = nil
        hint = nil
    }
}

#if DEBUG
struct HotkeyRecorderField_Previews: PreviewProvider {
    struct Host: View {
        @State private var binding = HotkeyBinding.defaultToggle
        @State private var styleBinding: HotkeyBinding?
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HotkeyRecorderField(binding: $binding)
                HotkeyRecorderField(binding: $styleBinding)
            }
            .padding()
        }
    }

    static var previews: some View {
        Host()
    }
}
#endif
