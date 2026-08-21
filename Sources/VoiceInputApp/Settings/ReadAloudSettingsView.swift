import AVFoundation
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// The 読み上げ pane: the two shortcuts that start a reading (the selection and the
/// clipboard), whether the LLM rewrites the text first, and which system voice
/// reads it.
struct ReadAloudSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        SettingsPane {
            Section("選択テキストのショートカット") {
                LabeledContent("キー") {
                    HotkeyRecorderField(binding: $environment.settings.readAloudHotkey)
                }
                if let issue = environment.readAloudHotkeyIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "テキストを選択してこのキーを押すと、読み上げやすい形に整えてから読み上げます。"
                        + "未設定のあいだは、このキーでの読み上げは動きません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "読み上げ中に押すと一時停止、もう一度押すと再開します。"
                        + "選択範囲の取得には ⌘C を送るため、アクセシビリティの許可が必要です"
                        + "（クリップボードは読み取り後に元に戻します）。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("クリップボードのショートカット") {
                LabeledContent("キー") {
                    HotkeyRecorderField(
                        binding: $environment.settings.readAloudClipboardHotkey
                    )
                }
                if let issue = environment.readAloudClipboardHotkeyIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "いまクリップボードに入っているテキストを読み上げます。"
                        + "AI エージェントやチャットの回答には、たいてい回答ごとのコピーボタンがあるので、"
                        + "それを押してからこのキーを押すのがいちばん速い経路です。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "⌘C を送らないので、アクセシビリティの許可は不要です。"
                        + "クリップボードは読み取るだけで、書き換えません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("整形") {
                Toggle("LLM で読み上げ向けに整える", isOn: rewriteBinding)
                Text(
                    "見出しや箇条書きの記号を外し、コードブロックや URL を「〜のコードです」のように"
                        + "言い換えてから読み上げます。オフにすると選択したテキストをそのまま読みます。"
                        + "プロバイダとモデルは「整形」タブの設定を使い、API キーが未設定のときは"
                        + "自動的にそのまま読み上げます。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("声") {
                Picker("音声", selection: voiceBinding) {
                    Text("自動（\(environment.settings.localeIdentifier) の最良の声）").tag(
                        String?.none)
                    ForEach(voices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(Optional(voice.identifier))
                    }
                }
                if voices.isEmpty {
                    Label(
                        "\(environment.settings.localeIdentifier) の音声が見つかりません。"
                            + "システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 から追加してください。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("速さ") {
                    HStack {
                        Slider(value: rateBinding, in: 0.2...0.9)
                        Text(rateLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text(
                    "声は macOS にインストールされているものを使います（システム設定の「読み上げコンテンツ」と同じ）。"
                        + "拡張版やプレミアム版をダウンロードしておくと聞き取りやすくなります。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Bindings

    private var rewriteBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.readAloudSettings.rewriteEnabled },
            set: { newValue in
                var value = environment.settings.readAloudSettings
                value.rewriteEnabled = newValue
                environment.settings.readAloud = value
            }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { environment.settings.readAloudSettings.rate },
            set: { newValue in
                var value = environment.settings.readAloudSettings
                value.rate = newValue
                environment.settings.readAloud = value
            }
        )
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { environment.settings.readAloudSettings.voiceIdentifier },
            set: { newValue in
                var value = environment.settings.readAloudSettings
                value.voiceIdentifier = newValue
                environment.settings.readAloud = value
            }
        )
    }

    // MARK: - Voices

    private var voices: [AVSpeechSynthesisVoice] {
        SystemSpeechSynthesizer.voices(forLanguage: environment.settings.localeIdentifier)
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name)（プレミアム）"
        case .enhanced: return "\(voice.name)（拡張）"
        default: return voice.name
        }
    }

    /// 0.5 is the system's normal pace, so the label is relative to it rather than
    /// showing a raw 0…1 number that means nothing to the user.
    private var rateLabel: String {
        let multiplier = environment.settings.readAloudSettings.rate / 0.5
        return String(format: "%.1f倍", multiplier)
    }
}

#if DEBUG
struct ReadAloudSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ReadAloudSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
