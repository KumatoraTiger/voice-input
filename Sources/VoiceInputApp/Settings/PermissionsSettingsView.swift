import AppKit
import Combine
import SwiftUI
import VoiceInputPlatform

struct PermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let permissions = environment.permissions

        SettingsPane {
            Section("録音に必要") {
                PermissionRow(
                    title: "マイク",
                    detail: "音声を録音します。",
                    status: permissions.microphone,
                    pane: .microphone,
                    onRequest: { await permissions.requestMicrophone() },
                    onOpenSettings: { permissions.openSettings(for: .microphone) }
                )
                PermissionRow(
                    title: "音声認識",
                    detail: "Apple のオンデバイス音声認識を使うために必要です。",
                    status: permissions.speechRecognition,
                    pane: .speechRecognition,
                    onRequest: { await permissions.requestSpeechRecognition() },
                    onOpenSettings: { permissions.openSettings(for: .speechRecognition) }
                )
            }

            Section("自動ペーストに必要") {
                PermissionRow(
                    title: "アクセシビリティ",
                    detail: "最前面のアプリに ⌘V を送るために必要です。自動ペーストを使わない場合は不要です。",
                    status: permissions.accessibility,
                    pane: .accessibility,
                    onRequest: {
                        permissions.promptForAccessibility()
                    },
                    onOpenSettings: { permissions.openSettings(for: .accessibility) }
                )
            }

            Section {
                Button("状態を再確認") { permissions.refresh() }
                    .controlSize(.small)
                Text("システム設定で許可を変更したあとは、このウインドウに戻ると自動で更新されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            permissions.refresh()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    let pane: PrivacyPane
    let onRequest: () async -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.isGranted ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if status.canRequest || pane == .accessibility {
                    Button("許可を求める") { Task { await onRequest() } }
                        .controlSize(.small)
                } else if !status.isGranted {
                    Button("システム設定を開く", action: onOpenSettings)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status.label)")
    }
}

#if DEBUG
struct PermissionsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        PermissionsSettingsView()
            .environment(AppEnvironment.previewEnvironment())
            .frame(width: 560, height: 460)
    }
}
#endif
