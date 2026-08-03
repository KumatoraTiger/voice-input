import Foundation

/// Every user-visible failure in the app. Cases carry enough information for the UI
/// to offer a next step (open Settings, grant permission, retry).
public enum VoiceInputError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case accessibilityPermissionDenied
    case audioEngineFailed(String)
    case engineUnavailable(TranscriptionEngineID, String)
    case transcriptionFailed(String)
    case emptyTranscript
    case missingAPIKey(LLMProviderID)
    case keychainFailure(String)
    /// Non-2xx from a provider. `body` is truncated and must never contain the key.
    case providerHTTPError(provider: String, status: Int, body: String)
    case providerDecodingFailed(provider: String, detail: String)
    case networkFailure(String)
    case cancelled
}

extension VoiceInputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "マイクへのアクセスが許可されていません。"
        case .speechPermissionDenied:
            return "音声認識の使用が許可されていません。"
        case .accessibilityPermissionDenied:
            return "自動ペーストにはアクセシビリティの許可が必要です。"
        case .audioEngineFailed(let detail):
            return "録音を開始できませんでした: \(detail)"
        case .engineUnavailable(let id, let detail):
            return "音声認識エンジン (\(id.rawValue)) を利用できません: \(detail)"
        case .transcriptionFailed(let detail):
            return "音声認識に失敗しました: \(detail)"
        case .emptyTranscript:
            return "音声を認識できませんでした。"
        case .missingAPIKey(let provider):
            return "\(provider.rawValue) の API キーが設定されていません。"
        case .keychainFailure(let detail):
            return "キーチェーンへのアクセスに失敗しました: \(detail)"
        case .providerHTTPError(let provider, let status, let body):
            return "\(provider) がエラーを返しました (HTTP \(status)): \(body)"
        case .providerDecodingFailed(let provider, let detail):
            return "\(provider) のレスポンスを解釈できませんでした: \(detail)"
        case .networkFailure(let detail):
            return "ネットワークエラー: \(detail)"
        case .cancelled:
            return "キャンセルされました。"
        }
    }

    /// A suggested next step, shown under the error in the UI.
    public var recoverySuggestion: String? {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied:
            return "システム設定 → プライバシーとセキュリティ から許可してください。"
        case .accessibilityPermissionDenied:
            return "システム設定 → プライバシーとセキュリティ → アクセシビリティ で VoiceInput を許可してください。"
        case .missingAPIKey:
            return "設定 → API キー から設定してください。"
        default:
            return nil
        }
    }
}
