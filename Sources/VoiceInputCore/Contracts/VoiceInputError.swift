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
    /// The question was heard but the model replied with nothing.
    case emptyAnswer
    case missingAPIKey(LLMProviderID)
    case keychainFailure(String)
    /// Non-2xx from a provider. `body` is truncated and must never contain the key.
    case providerHTTPError(provider: String, status: Int, body: String)
    case providerDecodingFailed(provider: String, detail: String)
    /// The configured model name could not be turned into a request. Only reachable
    /// for providers that put the model in the URL path (Gemini).
    case invalidModelName(provider: String, model: String)
    case networkFailure(String)
    case cancelled
}

extension VoiceInputError {
    /// A stable, content-free name for the failure, safe to log as `.public`.
    ///
    /// The associated values are deliberately left out: a transcription or provider
    /// detail can quote what the user said, and `docs/SECURITY.md` promises that
    /// never reaches a log. The case name alone is what makes a bug report
    /// actionable without it.
    public var kind: String {
        switch self {
        case .microphonePermissionDenied: return "microphonePermissionDenied"
        case .speechPermissionDenied: return "speechPermissionDenied"
        case .accessibilityPermissionDenied: return "accessibilityPermissionDenied"
        case .audioEngineFailed: return "audioEngineFailed"
        case .engineUnavailable(let id, _): return "engineUnavailable(\(id.rawValue))"
        case .transcriptionFailed: return "transcriptionFailed"
        case .emptyTranscript: return "emptyTranscript"
        case .emptyAnswer: return "emptyAnswer"
        case .missingAPIKey(let provider): return "missingAPIKey(\(provider.rawValue))"
        case .keychainFailure: return "keychainFailure"
        case .providerHTTPError(let provider, let status, _):
            return "providerHTTPError(\(provider), \(status))"
        case .providerDecodingFailed(let provider, _): return "providerDecodingFailed(\(provider))"
        case .invalidModelName(let provider, _): return "invalidModelName(\(provider))"
        case .networkFailure: return "networkFailure"
        case .cancelled: return "cancelled"
        }
    }
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
        case .emptyAnswer:
            return "回答が空でした。"
        case .missingAPIKey(let provider):
            return "\(provider.rawValue) の API キーが設定されていません。"
        case .keychainFailure(let detail):
            return "キーチェーンへのアクセスに失敗しました: \(detail)"
        case .providerHTTPError(let provider, let status, let body):
            return "\(provider) がエラーを返しました (HTTP \(status)): \(body)"
        case .providerDecodingFailed(let provider, let detail):
            return "\(provider) のレスポンスを解釈できませんでした: \(detail)"
        case .invalidModelName(let provider, let model):
            return "\(provider) のモデル名が不正です: \(model)"
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
        case .emptyAnswer:
            return "もう一度質問するか、設定 → 質問 で別のモデルを試してください。"
        case .invalidModelName:
            return "設定 → 整形 でモデル名を確認してください。空欄にすると既定のモデルを使います。"
        default:
            return nil
        }
    }
}
