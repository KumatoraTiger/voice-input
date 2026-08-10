import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// One formatting style as the HUD renders it: a name, and the shortcut that
/// picks it, if it has one.
struct HUDStyleOption: Identifiable, Equatable {
    let id: UUID
    let name: String
    let shortcut: String?

    init(style: FormattingStyle) {
        self.id = style.id
        self.name = style.name
        self.shortcut = style.hotkey.map { HotkeyFormatting.displayString(for: $0) }
    }
}

/// The floating overlay shown while a dictation is in flight.
///
/// Deliberately dumb: everything it renders arrives as plain values, so it can be
/// previewed in any phase without a microphone.
struct RecordingHUD: View {
    let phase: HUDPhase
    /// Dictation or question — changes the wording, and hides the style row for a
    /// question, where a formatting style has nothing to do.
    var mode: DictationMode = .dictation
    var partialText: String = ""
    var level: Float = 0
    var frontmostAppName: String?
    /// Whether a formatting failure still put the raw transcript on the
    /// clipboard, so the failure view can say the dictation was not lost.
    var rawTranscriptCopied: Bool = false
    /// Styles to offer while recording. Empty hides the row entirely — which is
    /// what happens when formatting is off, or there is only one style.
    var styles: [HUDStyleOption] = []
    var selectedStyleID: UUID?
    var onSelectStyle: (UUID) -> Void = { _ in }
    /// Esc only reaches us when the app is active, or when Accessibility is
    /// granted; the hint is hidden otherwise rather than lying to the user.
    var showsEscapeHint: Bool = false
    var onCancel: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpenSettings: (SettingsTab) -> Void = { _ in }
    var onOpenPrivacyPane: (PrivacyPane) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if phase.showsLevelMeter {
                LevelMeter(level: level)
                    .frame(height: 18)
                    .accessibilityLabel("入力レベル")
                    .accessibilityValue("\(Int(level * 100))%")
            }
            if let body = phase.body {
                answerView(body)
            } else {
                transcriptView
            }
            if mode == .dictation, phase.showsStylePicker, styles.count > 1 {
                stylePicker
            }
            if case .failed(let error) = phase {
                failureView(error)
            }
            footer
        }
        .padding(14)
        .frame(width: phase.body == nil ? 360 : 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("VoiceInput")
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: phase.symbol(mode))
                .foregroundStyle(tint)
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(phase.title(mode))
                .font(.headline)
            Spacer(minLength: 8)
            if case .finished(let summary, _) = phase, let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let frontmostAppName, phase.showsLevelMeter {
                Text(frontmostAppName.truncated(to: 18))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        let text = partialText.truncatedFromStart(to: 140)
        if !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if phase.showsLevelMeter {
            Text(mode == .ask ? "質問を話してください…" : "話してください…")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    /// The answer, shown until the user dismisses it.
    ///
    /// Scrolls rather than growing without bound: the panel is parked over whatever
    /// the user is working in, so a long answer must not cover the screen. The wheel
    /// works without the panel becoming key, which is why this can stay in a
    /// non-activating panel at all.
    private func answerView(_ body: String) -> some View {
        ScrollView(.vertical) {
            Text(body)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityLabel("回答")
    }

    /// The style row. Clicking a chip switches the dictation in flight; the panel
    /// never becomes key, so this does not move focus away from the app being
    /// dictated into. A style with its own shortcut shows it, because pressing that
    /// is the version of this that needs no mouse.
    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("整形スタイル（今回のみ）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(styles) { style in
                    styleChip(style, isSelected: style.id == selectedStyleID)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("整形スタイル")
    }

    private func styleChip(_ style: HUDStyleOption, isSelected: Bool) -> some View {
        Button {
            onSelectStyle(style.id)
        } label: {
            HStack(spacing: 4) {
                Text(style.name)
                    .font(.caption)
                    .lineLimit(1)
                if let shortcut = style.shortcut {
                    Text(shortcut)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func failureView(_ error: VoiceInputError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error.errorDescription ?? "失敗しました。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rawTranscriptCopied {
                Text("文字起こしをそのままクリップボードにコピーしました。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let pane = error.privacyPane {
                    Button("システム設定を開く") { onOpenPrivacyPane(pane) }
                } else if let tab = error.settingsTab {
                    Button("\(tab.title)設定を開く") { onOpenSettings(tab) }
                }
                Button("閉じる") { onDismiss() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        if phase.isCancellable {
            HStack(spacing: 6) {
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Label(
                        showsEscapeHint ? "キャンセル（⎋）" : "キャンセル",
                        systemImage: "xmark.circle"
                    )
                }
                .controlSize(.small)
                .accessibilityLabel("キャンセル")
            }
        } else if phase.body != nil {
            // No timer will take this away, so the way out has to be visible.
            HStack(spacing: 6) {
                Text("クリップボードにもコピー済み")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(showsEscapeHint ? "閉じる（⎋）" : "閉じる") { onDismiss() }
                    .controlSize(.small)
                    .accessibilityLabel("閉じる")
            }
        }
    }

    private var tint: Color {
        switch phase {
        case .recording: return .red
        case .finished: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }
}

/// Simple bar-style input meter. Bars light up proportionally to the level, which
/// reads better at a glance than a continuous fill.
struct LevelMeter: View {
    let level: Float
    var barCount: Int = 24

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let width = max(
                1,
                (proxy.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            )
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let lit = Float(index) / Float(barCount) < normalized
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(lit ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: width, height: height(for: index, in: proxy.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: normalized)
        }
    }

    /// The raw level hugs the bottom of the range, so it is curved to make quiet
    /// speech visible.
    private var normalized: Float {
        min(1, max(0, powf(level, 0.6)))
    }

    private func height(for index: Int, in total: CGFloat) -> CGFloat {
        // Taller in the middle: reads as a waveform rather than a progress bar.
        let position = Double(index) / Double(max(1, barCount - 1))
        let shape = 0.45 + 0.55 * sin(position * .pi)
        return max(3, total * shape)
    }
}

#if DEBUG
struct RecordingHUD_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            RecordingHUD(
                phase: .recording,
                partialText: "明日の打ち合わせなんですけど、十時からに変更したいと思っています",
                level: 0.55,
                frontmostAppName: "Slack",
                styles: FormattingStyle.builtIns.map(HUDStyleOption.init(style:)),
                selectedStyleID: FormattingStyle.messageID,
                showsEscapeHint: true
            )
            RecordingHUD(phase: .formatting, partialText: "整形前のテキスト", level: 0)
            RecordingHUD(
                phase: .recording,
                mode: .ask,
                partialText: "Swift で配列の重複を取り除く方法",
                level: 0.4
            )
            RecordingHUD(phase: .formatting, mode: .ask)
            RecordingHUD(
                phase: .finished(
                    summary: "gpt-4.1 · 2.1s",
                    body: "Set を通すのが一番短いです。\n\n```swift\nArray(Set(items))\n```\n\n"
                        + "順序を保ちたい場合は、見た要素を Set に入れながら filter します。"
                ),
                mode: .ask,
                showsEscapeHint: true
            )
            RecordingHUD(phase: .finished(summary: "gpt-4.1-mini · 0.8s", body: nil))
            RecordingHUD(phase: .failed(.missingAPIKey(.openAI)))
            RecordingHUD(phase: .failed(.microphonePermissionDenied))
        }
        .padding()
        .previewDisplayName("HUD phases")
    }
}
#endif
