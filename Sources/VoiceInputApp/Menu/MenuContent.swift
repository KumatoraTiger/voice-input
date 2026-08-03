import AppKit
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// The menu-bar menu. Rendered by AppKit (`.menu` style), so it sticks to the
/// view types the menu backend supports: Text, Button, Toggle, Picker, Menu,
/// Divider. Nothing here does I/O beyond a pasteboard write.
struct MenuContent: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        let state = environment.coordinator.state

        Text(statusLine(for: state))

        Button(startStopTitle(for: state)) {
            environment.toggleDictation()
        }
        .disabled(isBusyBeyondRecording(state))

        if state.isBusy {
            Button("キャンセル") { environment.coordinator.cancel() }
        }

        if let hotkeyError = environment.hotkeyError {
            Text(hotkeyError.truncated(to: 80))
        }

        Divider()

        Toggle("LLM で整形する", isOn: $environment.settings.formattingEnabled)

        Picker("整形スタイル", selection: $environment.settings.activeStyleID) {
            ForEach(environment.settings.styles) { style in
                Text(styleTitle(for: style)).tag(Optional(style.id))
            }
        }
        .disabled(!environment.settings.formattingEnabled)

        Divider()

        Menu("履歴") {
            if environment.coordinator.history.isEmpty {
                Text("まだありません")
            } else {
                ForEach(environment.coordinator.history) { record in
                    Button(historyTitle(for: record)) {
                        environment.copyToPasteboard(record.formattedText)
                    }
                }
            }
        }
        .disabled(environment.coordinator.history.isEmpty)

        Divider()

        // `SettingsLink` is the one dependable way to open the Settings scene from
        // a MenuBarExtra on macOS 14 (`openSettings` in the environment is unreliable
        // from a menu). The window is brought to the front by `WindowActivator`
        // inside `SettingsRootView`, since an accessory app is not active here.
        SettingsLink {
            Text("設定…")
        }

        Button("VoiceInput を終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Labels

    private func statusLine(for state: DictationState) -> String {
        switch state {
        case .idle:
            return "待機中 — \(environment.hotkeyLabel) で開始"
        case .failed(let error):
            return "エラー: \((error.errorDescription ?? "失敗しました").truncated(to: 60))"
        case .finished:
            return "完了 — クリップボードにコピーしました"
        default:
            return state.statusText
        }
    }

    private func startStopTitle(for state: DictationState) -> String {
        let shortcut = environment.hotkeyLabel
        switch state {
        case .recording, .preparing:
            return "録音を停止（\(shortcut)）"
        default:
            return "録音を開始（\(shortcut)）"
        }
    }

    /// While transcribing or formatting there is nothing to start or stop.
    private func isBusyBeyondRecording(_ state: DictationState) -> Bool {
        switch state {
        case .transcribing, .formatting: return true
        default: return false
        }
    }

    /// The shortcut rides along in the label: a `Picker` row cannot carry a real
    /// key equivalent, and the point is only to remind the user it exists.
    private func styleTitle(for style: FormattingStyle) -> String {
        guard let hotkey = style.hotkey else { return style.name }
        return "\(style.name)  \(HotkeyFormatting.displayString(for: hotkey))"
    }

    private func historyTitle(for record: DictationRecord) -> String {
        "\(Self.timeFormatter.string(from: record.date))  \(record.formattedText.truncated(to: 44))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

#if DEBUG
// The `#Preview` macro needs a plugin that only ships with Xcode; this repo
// builds with Command Line Tools only, so previews use `PreviewProvider`.
struct MenuContent_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading) {
            MenuContent()
        }
        .padding()
        .frame(width: 280)
        .environment(AppEnvironment.previewEnvironment())
    }
}
#endif
