import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// The 質問 pane: the shortcut that records a question, which model answers it, and
/// how long the answer should be.
struct AskSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        SettingsPane {
            Section("ショートカット") {
                LabeledContent("キー") {
                    HotkeyRecorderField(binding: $environment.settings.askHotkey)
                }
                if let issue = environment.askHotkeyIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "このキーで録音すると、話した内容を質問として LLM に送り、回答を画面に表示します。"
                        + "未設定のあいだは質問機能は動きません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "録音中に押すと、録音を止めずにその録音を質問に切り替えます"
                        + "（\(environment.hotkeyLabel) を押すと書き起こしに戻ります）。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("モデル") {
                HStack {
                    TextField("モデル", text: askModelBinding)
                        .textFieldStyle(.roundedBorder)
                    Menu("候補") {
                        ForEach(suggestedModels, id: \.self) { model in
                            Button(model) { askModelBinding.wrappedValue = model }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("モデルの候補")
                }
                Text(
                    "プロバイダは「整形」タブの設定（\(providerName)）を使います。"
                        + "空欄にすると既定のモデル（\(defaultModel)）になりますが、"
                        + "整形用の軽いモデルは質問には向きません。大きめのモデルを指定してください。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("回答") {
                Picker("長さ", selection: $environment.settings.askAnswerStyle) {
                    Text("簡潔（結論だけ）").tag(AskAnswerStyle.concise)
                    Text("詳しく（手順や例を含む）").tag(AskAnswerStyle.detailed)
                }
                .pickerStyle(.radioGroup)
                Text(
                    "回答は画面に表示され、Esc か「閉じる」で消えます。クリップボードにもコピーされますが、"
                        + "自動ペーストの対象にはなりません。コマンドの実行やファイルへのアクセスも行いません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Bindings

    /// Keyed by provider, like the formatting model, so switching providers keeps
    /// each side's choice.
    private var askModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.askModels[environment.settings.llmProvider] ?? "" },
            set: { newValue in
                var models = environment.settings.askModels
                models[environment.settings.llmProvider] = newValue
                environment.settings.askModels = models
            }
        )
    }

    // MARK: - Provider helpers

    private var providerName: String {
        environment.providers.provider(for: environment.settings.llmProvider)?.displayName
            ?? environment.settings.llmProvider.rawValue
    }

    private var suggestedModels: [String] {
        environment.providers.provider(for: environment.settings.llmProvider)?.suggestedModels ?? []
    }

    private var defaultModel: String {
        environment.providers.provider(for: environment.settings.llmProvider)?.defaultModel ?? "-"
    }
}

#if DEBUG
struct AskSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AskSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
