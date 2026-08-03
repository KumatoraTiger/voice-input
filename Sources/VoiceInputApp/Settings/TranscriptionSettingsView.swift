import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

struct TranscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var newWord = ""

    var body: some View {
        @Bindable var environment = environment
        let model = environment.engineAvailability

        SettingsPane {
            Section("エンジン") {
                ForEach(TranscriptionEngineID.allCases, id: \.self) { id in
                    EngineRow(
                        id: id,
                        availability: model.availability(for: id),
                        isSelected: environment.settings.transcriptionEngine == id,
                        onSelect: { environment.settings.transcriptionEngine = id },
                        onFix: { fix(id: id, availability: model.availability(for: id)) }
                    )
                }
                if model.isRefreshing {
                    Label("状態を確認しています…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("言語") {
                Picker("言語", selection: $environment.settings.localeIdentifier) {
                    ForEach(localeChoices, id: \.self) { identifier in
                        Text(localeName(identifier)).tag(identifier)
                    }
                }
                Text("音声認識と整形プロンプトの両方で使われます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("クラウド音声認識") {
                TextField("モデル", text: $environment.settings.transcriptionModel)
                    .textFieldStyle(.roundedBorder)
                Text("例: gpt-4o-transcribe, gpt-4o-mini-transcribe, whisper-1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("単語リスト") {
                Text("固有名詞や社内用語を登録すると、認識と整形の両方で優先されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("単語を追加", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("追加", action: addWord)
                        .disabled(newWord.nilIfBlank == nil)
                }
                if environment.settings.vocabulary.isEmpty {
                    Text("まだ登録されていません。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(environment.settings.vocabulary.enumerated()), id: \.offset) {
                        index, word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                removeWord(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(word) を削除")
                        }
                    }
                }
            }
        }
        .task(id: environment.settings.localeIdentifier) {
            await model.refresh(locale: environment.settings.locale)
        }
    }

    // MARK: - Actions

    private func fix(id: TranscriptionEngineID, availability: EngineAvailability?) {
        guard let availability else { return }
        switch availability.status {
        case .needsPermission:
            environment.settingsTab = .permissions
        case .needsAPIKey:
            environment.settingsTab = .apiKeys
        case .unsupportedLocale, .unavailable, .unsupportedOS, .available:
            break
        }
    }

    private func addWord() {
        guard let word = newWord.nilIfBlank else { return }
        var vocabulary = environment.settings.vocabulary
        guard !vocabulary.contains(word) else {
            newWord = ""
            return
        }
        vocabulary.append(word)
        environment.settings.vocabulary = vocabulary
        newWord = ""
    }

    private func removeWord(at index: Int) {
        var vocabulary = environment.settings.vocabulary
        guard vocabulary.indices.contains(index) else { return }
        vocabulary.remove(at: index)
        environment.settings.vocabulary = vocabulary
    }

    // MARK: - Locale list

    /// A short curated list; the stored identifier is kept even if it is not in it.
    private var localeChoices: [String] {
        var choices = [
            "ja-JP", "en-US", "en-GB", "zh-CN", "ko-KR", "fr-FR", "de-DE", "es-ES",
        ]
        let current = environment.settings.localeIdentifier
        if !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    private func localeName(_ identifier: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return "\(name)（\(identifier)）"
    }
}

/// One engine, its live availability and the single button that fixes it.
private struct EngineRow: View {
    let id: TranscriptionEngineID
    let availability: EngineAvailability?
    let isSelected: Bool
    let onSelect: () -> Void
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(id.displayName) を選択")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName)
                    .font(.body)
                Text(id.tradeOff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if let fixTitle {
                        Button(fixTitle, action: onFix)
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                    }
                }
                if let detail = availability?.detail, availability?.isUsable == false {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var statusLabel: String {
        guard let availability else { return "確認中…" }
        return availability.status.shortLabel
    }

    private var statusSymbol: String {
        guard let availability else { return "clock" }
        return availability.isUsable ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        guard let availability else { return .secondary }
        return availability.isUsable ? .green : .orange
    }

    private var fixTitle: String? {
        switch availability?.status {
        case .needsPermission: return "権限を確認"
        case .needsAPIKey: return "API キーを設定"
        default: return nil
        }
    }
}

#if DEBUG
struct TranscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
