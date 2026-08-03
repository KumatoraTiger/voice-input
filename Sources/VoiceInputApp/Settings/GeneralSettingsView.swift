import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showsAccessibilityHelp = false

    var body: some View {
        @Bindable var environment = environment

        SettingsPane {
            Section("ショートカット") {
                LabeledContent("キー") {
                    HotkeyRecorderField(binding: $environment.settings.hotkey)
                }
                Picker("動作", selection: $environment.settings.hotkeyMode) {
                    Text("トグル（押して開始・もう一度押して停止）").tag(HotkeyMode.toggle)
                    Text("押している間だけ録音").tag(HotkeyMode.pushToTalk)
                }
                if let error = environment.hotkeyError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if environment.settings.hotkey.isModifierOnly {
                            HStack {
                                Button("アクセシビリティを許可…") {
                                    environment.permissions.promptForAccessibility()
                                }
                                Button("システム設定を開く") {
                                    environment.permissions.openSettings(for: .accessibility)
                                }
                                Button("再試行") { environment.reapplyHotkey() }
                            }
                            .controlSize(.small)
                        }
                    }
                } else if environment.settings.hotkey.isModifierOnly {
                    Text(
                        "修飾キーだけのショートカットです。他のキーと一緒に押したときは反応せず、"
                            + "単独で押して離したときだけ動作します。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("出力") {
                Toggle("整形後のテキストを自動でペーストする", isOn: autoPasteBinding)
                if showsAccessibilityHelp {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "自動ペーストには「アクセシビリティ」の許可が必要です。"
                                + "許可すると、VoiceInput が最前面のアプリに ⌘V を送れるようになります。"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("アクセシビリティを許可…") {
                                environment.permissions.promptForAccessibility()
                                refreshAccessibilityHelp()
                            }
                            Button("システム設定を開く") {
                                environment.permissions.openSettings(for: .accessibility)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Text("整形後のテキストは常にクリップボードにコピーされます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("動作") {
                Toggle("効果音を鳴らす", isOn: $environment.settings.playSounds)
                Toggle("ログイン時に起動する", isOn: $environment.settings.launchAtLogin)
                if let notice = environment.loginItemNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper(
                    value: $environment.settings.historyLimit,
                    in: 0...100,
                    step: 5
                ) {
                    Text(
                        environment.settings.historyLimit == 0
                            ? "履歴を保持しない"
                            : "履歴の保持件数: \(environment.settings.historyLimit) 件"
                    )
                }
                Text("履歴はメモリ上のみに保持され、ディスクには書き込まれません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshAccessibilityHelp)
        .task { await watchForAccessibilityGrant() }
    }

    /// Polls while this pane is visible, because there is no notification for a TCC
    /// change and the Settings window may never lose focus while the user flips the
    /// switch in System Settings. Only runs a cheap `AXIsProcessTrusted()` check,
    /// and only while something is actually blocked.
    private func watchForAccessibilityGrant() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            refreshAccessibilityHelp()
        }
    }

    /// Turning auto-paste on is the moment to check Accessibility: the setting is
    /// meaningless without it, and asking earlier would be an unexplained prompt.
    private var autoPasteBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.autoPasteEnabled },
            set: { newValue in
                environment.settings.autoPasteEnabled = newValue
                showsAccessibilityHelp = newValue && !environment.output.canPaste
            }
        )
    }

    private func refreshAccessibilityHelp() {
        environment.permissions.refresh()
        showsAccessibilityHelp =
            environment.settings.autoPasteEnabled && !environment.output.canPaste
        // Coming back from System Settings is the moment a modifier-only shortcut
        // can finally register; macOS sends no notification when that happens.
        if environment.hotkeyError != nil, environment.settings.hotkey.isModifierOnly {
            environment.reapplyHotkey()
        }
    }
}

#if DEBUG
struct GeneralSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        GeneralSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
