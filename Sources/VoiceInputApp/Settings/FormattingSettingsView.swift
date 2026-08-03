import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

struct FormattingSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedStyleID: UUID?

    var body: some View {
        @Bindable var environment = environment
        let settings = environment.settings

        SettingsPane {
            Section("整形") {
                Toggle("LLM でテキストを整形する", isOn: $environment.settings.formattingEnabled)
                Text("オフにすると、認識結果をそのままコピーします（API キー不要・オフライン）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("画面コンテキスト") {
                Toggle("画面の文字を読んで固有名詞の表記を直す", isOn: screenContextBinding)
                    .disabled(!settings.formattingEnabled)
                Text(
                    """
                    最前面のウィンドウだけを読み取り、そこに写っていた単語のうち\
                    「話した内容と音が近いもの」だけを整形の参考として送ります。\
                    文章はそのまま送りません。画面収録の許可が必要です。
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if settings.screenContextEnabled {
                    if environment.permissions.screenRecording == .granted {
                        Label("画面収録は許可されています。", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Label("画面収録が許可されていません。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("システム設定を開く") {
                                environment.permissions.openScreenRecordingSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    Text(
                        """
                        クラウドのプロバイダを使っている場合、選ばれた単語はそのプロバイダに送られます。\
                        パスワードマネージャなど一部のアプリは、この設定に関わらず読み取りません。
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("プロバイダ") {
                Picker("プロバイダ", selection: $environment.settings.llmProvider) {
                    ForEach(LLMProviderID.allCases, id: \.self) { id in
                        Text(providerName(id)).tag(id)
                    }
                }
                HStack {
                    TextField("モデル", text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                    Menu("候補") {
                        ForEach(suggestedModels, id: \.self) { model in
                            Button(model) { modelBinding.wrappedValue = model }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("モデルの候補")
                }
                Text("空欄にすると既定のモデル（\(defaultModel)）を使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("スタイル") {
                Picker("使用中のスタイル", selection: $environment.settings.activeStyleID) {
                    ForEach(settings.styles) { style in
                        Text(style.name).tag(Optional(style.id))
                    }
                }

                List(selection: $selectedStyleID) {
                    ForEach(settings.styles) { style in
                        HStack {
                            Text(style.name)
                            if style.isBuiltIn {
                                Text("組み込み")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let hotkey = style.hotkey {
                                Text(HotkeyFormatting.displayString(for: hotkey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(style.id)
                    }
                }
                .frame(height: 110)

                HStack {
                    Button("追加", action: addStyle)
                    Button("複製", action: duplicateStyle)
                        .disabled(selectedIndex == nil)
                    Button("削除", action: deleteStyle)
                        .disabled(selectedIndex == nil || selectedStyle?.isBuiltIn == true)
                    Spacer()
                    Button("デフォルトに戻す", action: restoreStyle)
                        .disabled(!canRestoreSelected)
                }
                .controlSize(.small)

                if let index = selectedIndex {
                    TextField("名前", text: $environment.settings.styles[index].name)
                        .textFieldStyle(.roundedBorder)

                    LabeledContent("ショートカット") {
                        HotkeyRecorderField(
                            binding: $environment.settings.styles[index].hotkey
                        )
                    }
                    if let issue = styleIssue(at: index) {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(
                        "このスタイルで録音を開始します。既定のスタイルは変わらず、その回だけ適用されます。"
                            + "録音中に押すと、録音を止めずにこのスタイルへ切り替えます。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("指示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $environment.settings.styles[index].instructions)
                            .font(.body)
                            .frame(height: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(.separator)
                            )
                            .accessibilityLabel("スタイルの指示")
                    }
                } else {
                    Text("スタイルを選択すると編集できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("試す") {
                TextEditor(text: trialSampleBinding)
                    .font(.body)
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .accessibilityLabel("サンプル文")
                HStack {
                    Button("試す") {
                        Task {
                            await environment.formattingTrial.run(settings: environment.settings)
                        }
                    }
                    .disabled(environment.formattingTrial.isRunning)
                    if environment.formattingTrial.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("クリア") { environment.formattingTrial.reset() }
                        .controlSize(.small)
                }
                if let output = environment.formattingTrial.output {
                    Text(output)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = environment.formattingTrial.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("実際の整形と同じ処理を 1 回だけ実行します（API キーが必要です）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selectedStyleID == nil {
                selectedStyleID =
                    environment.settings.activeStyleID
                    ?? environment.settings.styles.first?.id
            }
        }
    }

    // MARK: - Bindings

    /// Not a plain `$settings.screenContextEnabled`: switching it on is what asks
    /// for the screen-recording permission, so it has to go through the
    /// environment rather than straight into the settings store.
    private var screenContextBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.screenContextEnabled },
            set: { environment.setScreenContextEnabled($0) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { environment.settings.models[environment.settings.llmProvider] ?? "" },
            set: { newValue in
                var models = environment.settings.models
                models[environment.settings.llmProvider] = newValue
                environment.settings.models = models
            }
        )
    }

    private var trialSampleBinding: Binding<String> {
        Binding(
            get: { environment.formattingTrial.sample },
            set: { environment.formattingTrial.sample = $0 }
        )
    }

    // MARK: - Style helpers

    private var selectedIndex: Int? {
        guard let selectedStyleID else { return nil }
        return environment.settings.styles.firstIndex { $0.id == selectedStyleID }
    }

    private var selectedStyle: FormattingStyle? {
        selectedIndex.map { environment.settings.styles[$0] }
    }

    private func styleIssue(at index: Int) -> String? {
        environment.styleHotkeyIssues[environment.settings.styles[index].id]
    }

    private var canRestoreSelected: Bool {
        guard let style = selectedStyle, style.isBuiltIn,
            let original = FormattingStyle.builtIns.first(where: { $0.id == style.id })
        else { return false }
        return original != style
    }

    private func addStyle() {
        let style = FormattingStyle(name: "新しいスタイル", instructions: "")
        environment.settings.styles.append(style)
        selectedStyleID = style.id
    }

    private func duplicateStyle() {
        guard let style = selectedStyle else { return }
        let copy = FormattingStyle(
            name: "\(style.name) のコピー",
            instructions: style.instructions,
            isBuiltIn: false
        )
        environment.settings.styles.append(copy)
        selectedStyleID = copy.id
    }

    private func deleteStyle() {
        guard let index = selectedIndex, !environment.settings.styles[index].isBuiltIn else {
            return
        }
        var settings = environment.settings
        let removed = settings.styles.remove(at: index)
        if settings.activeStyleID == removed.id {
            settings.activeStyleID = settings.styles.first?.id
        }
        environment.settings = settings
        selectedStyleID = environment.settings.styles.first?.id
    }

    /// Built-ins are editable but always restorable, so a broken prompt is never a
    /// dead end.
    private func restoreStyle() {
        guard let index = selectedIndex else { return }
        let id = environment.settings.styles[index].id
        guard let original = FormattingStyle.builtIns.first(where: { $0.id == id }) else { return }
        environment.settings.styles[index] = original
    }

    // MARK: - Provider helpers

    private func providerName(_ id: LLMProviderID) -> String {
        environment.providers.provider(for: id)?.displayName ?? id.rawValue
    }

    private var suggestedModels: [String] {
        environment.providers.provider(for: environment.settings.llmProvider)?.suggestedModels ?? []
    }

    private var defaultModel: String {
        environment.providers.provider(for: environment.settings.llmProvider)?.defaultModel ?? "-"
    }
}

#if DEBUG
struct FormattingSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        FormattingSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
