import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// First-launch window: three short steps, skippable at any point.
struct WelcomeView: View {
    enum Step: Int, CaseIterable {
        case permissions
        case engine
        case apiKey

        var title: String {
            switch self {
            case .permissions: return "権限を許可"
            case .engine: return "音声認識を選ぶ"
            case .apiKey: return "API キー（任意）"
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var step: Step = .permissions

    /// Called on 「試してみる」 and on 「あとで」.
    var onFinish: (_ startDictation: Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VoiceInput へようこそ")
                .font(.title2.bold())
            Text("\(environment.hotkeyLabel) を押して話すと、整形されたテキストがクリップボードに入ります。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(
                            item.rawValue <= step.rawValue
                                ? Color.accentColor : Color.secondary.opacity(0.25)
                        )
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 4)
            Text("ステップ \(step.rawValue + 1) / \(Step.allCases.count)・\(step.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permissions: permissionsStep
        case .engine: engineStep
        case .apiKey: apiKeyStep
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("マイクと音声認識の許可が必要です。")
                .font(.callout)
            permissionLine(
                title: "マイク",
                status: environment.permissions.microphone,
                action: { await environment.permissions.requestMicrophone() }
            )
            permissionLine(
                title: "音声認識",
                status: environment.permissions.speechRecognition,
                action: { await environment.permissions.requestSpeechRecognition() }
            )
            Text("自動ペースト用の「アクセシビリティ」は、あとから設定で有効にできます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { environment.permissions.refresh() }
    }

    private func permissionLine(
        title: String,
        status: PermissionStatus,
        action: @escaping () async -> Void
    ) -> some View {
        HStack {
            Image(systemName: status.symbol)
                .foregroundStyle(status.isGranted ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !status.isGranted {
                Button("許可") { Task { await action() } }
                    .controlSize(.small)
            }
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("あとから設定でいつでも変更できます。")
                .font(.callout)
            ForEach(TranscriptionEngineID.allCases, id: \.self) { id in
                Button {
                    environment.settings.transcriptionEngine = id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(
                            systemName: environment.settings.transcriptionEngine == id
                                ? "largecircle.fill.circle" : "circle"
                        )
                        .foregroundStyle(
                            environment.settings.transcriptionEngine == id
                                ? Color.accentColor : Color.secondary
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id.displayName)
                            Text(id.tradeOff)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let availability = environment.engineAvailability.availability(
                                for: id),
                                !availability.isUsable
                            {
                                Text(availability.status.shortLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    environment.settings.transcriptionEngine == id ? [.isSelected] : []
                )
            }
        }
        .task { await environment.engineAvailability.refresh(locale: environment.settings.locale) }
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整形に使う LLM の API キーを設定します。あとで設定してもかまいません。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Picker("プロバイダ", selection: providerBinding) {
                ForEach(LLMProviderID.allCases, id: \.self) { id in
                    Text(environment.providers.provider(for: id)?.displayName ?? id.rawValue).tag(
                        id)
                }
            }
            if let slot = currentSlot {
                SecureField(
                    "API キー",
                    text: Binding(
                        get: { environment.apiKeys.draft(for: slot.key) },
                        set: { environment.apiKeys.setDraft($0, for: slot.key) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存") { environment.apiKeys.save(slot) }
                        .disabled(environment.apiKeys.draft(for: slot.key).nilIfBlank == nil)
                    Text(environment.apiKeys.isSaved(slot.key) ? "保存済み" : "未設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = slot.helpURL {
                        Link("キーを取得", destination: url).font(.callout)
                    }
                }
            }
            Text("キーは macOS のキーチェーンに保存されます。整形をオフにすれば API キーなしでも使えます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("あとで") { onFinish(false) }
            Spacer()
            if step != .permissions {
                Button("戻る") { move(-1) }
            }
            if step == .apiKey {
                Button("試してみる") { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("次へ") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private var providerBinding: Binding<LLMProviderID> {
        Binding(
            get: { environment.settings.llmProvider },
            set: { environment.settings.llmProvider = $0 }
        )
    }

    private var currentSlot: APIKeysModel.Slot? {
        let key = SecretKey.apiKey(for: environment.settings.llmProvider)
        return environment.apiKeys.slots.first { $0.key == key }
    }

    private func move(_ delta: Int) {
        let next = step.rawValue + delta
        guard let step = Step(rawValue: next) else { return }
        self.step = step
    }
}

#if DEBUG
struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
            .environment(AppEnvironment.previewEnvironment())
    }
}
#endif
