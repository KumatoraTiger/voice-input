import Foundation
import VoiceInputCore
import VoiceInputPlatform

/// Japanese labels and SF Symbol names for the dictation state machine, in one
/// place so the menu bar icon, the menu and the HUD never drift apart.
extension DictationState {
    /// One short line for the menu.
    var statusText: String {
        switch self {
        case .idle: return "待機中"
        case .preparing: return "準備中…"
        case .recording: return "録音中…"
        case .transcribing: return "文字起こし中…"
        case .formatting: return "整形中…"
        case .finished: return "完了"
        case .failed: return "エラー"
        }
    }

    /// Menu-bar icon. Menu-bar space is tiny, so these stay single-shape symbols.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "mic"
        case .preparing: return "mic"
        case .recording: return "mic.fill"
        case .transcribing, .formatting: return "waveform"
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// Spoken description for VoiceOver on the icon-only menu-bar item.
    var accessibilityStatus: String {
        "VoiceInput: \(statusText)"
    }
}

/// What the HUD renders. Derived from `DictationState` so the view itself stays
/// free of pipeline knowledge (and is trivial to preview).
enum HUDPhase: Equatable {
    case preparing
    case recording
    case transcribing
    case formatting
    case finished(summary: String?)
    case failed(VoiceInputError)

    /// `nil` for `.idle` — the HUD must never be on screen when nothing is going on.
    init?(state: DictationState) {
        switch state {
        case .idle: return nil
        case .preparing: self = .preparing
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .formatting: self = .formatting
        case .finished(let outcome): self = .finished(summary: outcome.summary)
        case .failed(let error): self = .failed(error)
        }
    }

    var title: String {
        switch self {
        case .preparing: return "準備中…"
        case .recording: return "録音中…"
        case .transcribing: return "文字起こし中…"
        case .formatting: return "整形中…"
        case .finished: return "コピーしました"
        case .failed: return "失敗しました"
        }
    }

    var symbol: String {
        switch self {
        case .preparing: return "hourglass"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .formatting: return "text.append"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var showsLevelMeter: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Switching style only means something while audio is still being captured —
    /// once the transcript is on its way to the LLM the choice is already spent.
    var showsStylePicker: Bool {
        switch self {
        case .preparing, .recording: return true
        default: return false
        }
    }

    var isCancellable: Bool {
        switch self {
        case .preparing, .recording, .transcribing, .formatting: return true
        case .finished, .failed: return false
        }
    }
}

extension VoiceInputError {
    /// The Settings tab that can actually fix this error, if any.
    var settingsTab: SettingsTab? {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied,
            .accessibilityPermissionDenied:
            return .permissions
        case .missingAPIKey, .keychainFailure, .providerHTTPError:
            return .apiKeys
        case .engineUnavailable:
            return .transcription
        default:
            return nil
        }
    }

    /// The System Settings privacy pane that can fix this error, if any. Preferred
    /// over `settingsTab` because a TCC grant cannot be made from inside the app.
    var privacyPane: PrivacyPane? {
        switch self {
        case .microphonePermissionDenied: return .microphone
        case .speechPermissionDenied: return .speechRecognition
        case .accessibilityPermissionDenied: return .accessibility
        default: return nil
        }
    }
}

extension EngineAvailability.Status {
    /// The short honest label shown next to an engine in Settings.
    var shortLabel: String {
        switch self {
        case .available: return "利用可能"
        case .needsPermission: return "権限が必要"
        case .needsAPIKey: return "API キーが必要"
        case .unsupportedOS: return "macOS 26 以降が必要"
        case .unsupportedLocale: return "このロケールは非対応"
        case .unavailable: return "利用不可"
        }
    }
}

extension TranscriptionEngineID {
    var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple 音声認識（オンデバイス）"
        case .appleSpeechAnalyzer: return "Apple SpeechAnalyzer"
        case .openAICloud: return "OpenAI（クラウド）"
        }
    }

    /// One line that makes the trade-off visible before the user picks.
    var tradeOff: String {
        switch self {
        case .appleOnDevice:
            return "無料・オフライン。音声は端末から出ません。"
        case .appleSpeechAnalyzer:
            return "macOS 26 以降で高精度。無料・オフライン。"
        case .openAICloud:
            return "従量課金。音声が OpenAI に送信されます。"
        }
    }
}

extension PermissionStatus {
    var label: String {
        switch self {
        case .granted: return "許可済み"
        case .denied: return "未許可"
        case .notDetermined: return "未確認"
        case .restricted: return "制限されています"
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .restricted: return "lock.circle.fill"
        }
    }
}
