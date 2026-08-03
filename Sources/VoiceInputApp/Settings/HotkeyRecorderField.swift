import AppKit
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// Click, then press a key combination.
///
/// Uses a local `NSEvent` monitor (the Settings window is key while recording, so
/// no Accessibility permission is needed) and swallows every key press until a
/// usable combination arrives, so ⌘W does not close the window mid-recording.
struct HotkeyRecorderField: View {
    @Binding var binding: HotkeyBinding

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isRecording { stop() } else { start() }
            } label: {
                Text(isRecording ? "キーを押してください…" : HotkeyFormatting.displayString(for: binding))
                    .frame(minWidth: 130)
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("ショートカットキー")
            .accessibilityValue(HotkeyFormatting.displayString(for: binding))
            .accessibilityHint("クリックしてから新しいキーの組み合わせを押します")

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        hint = "修飾キー（⌘ ⌥ ⌃ ⇧）を含めてください。⎋ でキャンセル。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels without changing anything.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let candidate = HotkeyFormatting.binding(from: event) {
                binding = candidate
                stop()
            } else {
                hint = "修飾キーと組み合わせてください（例: ⌥Space）。"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        hint = nil
    }
}

#if DEBUG
struct HotkeyRecorderField_Previews: PreviewProvider {
    struct Host: View {
        @State private var binding = HotkeyBinding.defaultToggle
        var body: some View {
            HotkeyRecorderField(binding: $binding).padding()
        }
    }

    static var previews: some View {
        Host()
    }
}
#endif
