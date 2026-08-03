import SwiftUI
import VoiceInputCore

/// API キー tab.
///
/// A stored key is never read back into a field: the UI only ever shows
/// 保存済み / 未設定. Everything is written through `SecretStore` (the Keychain).
struct APIKeysSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let model = environment.apiKeys

        SettingsPane {
            Section {
                Label(
                    "API キーは macOS のキーチェーンに保存されます。"
                        + "設定ファイルやこのリポジトリには一切書き込まれません。",
                    systemImage: "lock.fill"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                if let storeError = model.storeError {
                    Label(storeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(model.slots) { slot in
                Section(slot.title) {
                    APIKeySlotView(slot: slot, model: model, settings: environment.settings)
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

private struct APIKeySlotView: View {
    let slot: APIKeysModel.Slot
    let model: APIKeysModel
    let settings: AppSettings

    var body: some View {
        Text(slot.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 6) {
            Image(systemName: model.isSaved(slot.key) ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(model.isSaved(slot.key) ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(model.isSaved(slot.key) ? "保存済み" : "未設定")
                .font(.callout)
            Spacer()
            if let url = slot.helpURL {
                Link("キーを取得", destination: url)
                    .font(.callout)
            }
        }

        SecureField("新しい API キー", text: draftBinding)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("\(slot.title) の API キー")

        HStack {
            Button("保存") { model.save(slot) }
                .disabled(model.draft(for: slot.key).nilIfBlank == nil)
            Button("削除") { model.delete(slot) }
                .disabled(!model.isSaved(slot.key))
            Spacer()
            Button("接続テスト") {
                Task { await model.test(slot, settings: settings) }
            }
            .disabled(isTesting)
        }
        .controlSize(.small)

        switch model.results[slot.key] {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("テスト中…").font(.caption).foregroundStyle(.secondary)
            }
        case .success(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let detail):
            Label(detail, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    private var isTesting: Bool {
        model.results[slot.key] == .running
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { model.draft(for: slot.key) },
            set: { model.setDraft($0, for: slot.key) }
        )
    }
}

#if DEBUG
struct APIKeysSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        APIKeysSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
