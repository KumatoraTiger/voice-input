import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// The floating overlay shown while a dictation is in flight.
///
/// Deliberately dumb: everything it renders arrives as plain values, so it can be
/// previewed in any phase without a microphone.
struct RecordingHUD: View {
    let phase: HUDPhase
    var partialText: String = ""
    var level: Float = 0
    var frontmostAppName: String?
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
            transcriptView
            if case .failed(let error) = phase {
                failureView(error)
            }
            footer
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
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
            Image(systemName: phase.symbol)
                .foregroundStyle(tint)
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(phase.title)
                .font(.headline)
            Spacer(minLength: 8)
            if case .finished(let summary) = phase, let summary {
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
            Text("話してください…")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
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
                showsEscapeHint: true
            )
            RecordingHUD(phase: .formatting, partialText: "整形前のテキスト", level: 0)
            RecordingHUD(phase: .finished(summary: "gpt-4.1-mini · 0.8s"))
            RecordingHUD(phase: .failed(.missingAPIKey(.openAI)))
            RecordingHUD(phase: .failed(.microphonePermissionDenied))
        }
        .padding()
        .previewDisplayName("HUD phases")
    }
}
#endif
