import Foundation
import VoiceInputCore
import VoiceInputPlatform

/// Which of the two things a run in flight is doing, as the UI words it.
///
/// The state machine is identical for both — only the labels differ, so this is a
/// presentation concern and stays out of Core.
enum DictationMode: Equatable {
    case dictation
    case ask

    init(action: VoiceActionID) {
        self = action == .ask ? .ask : .dictation
    }
}

/// Japanese labels and SF Symbol names for the dictation state machine, in one
/// place so the menu bar icon, the menu and the HUD never drift apart.
extension DictationState {
    /// One short line for the menu.
    func statusText(_ mode: DictationMode = .dictation) -> String {
        switch (self, mode) {
        case (.idle, _): return "待機中"
        case (.preparing, _): return "準備中…"
        case (.recording, .dictation): return "録音中…"
        case (.recording, .ask): return "質問を録音中…"
        case (.transcribing, .dictation): return "文字起こし中…"
        case (.transcribing, .ask): return "質問を認識中…"
        case (.formatting, .dictation): return "整形中…"
        case (.formatting, .ask): return "回答を作成中…"
        case (.finished, _): return "完了"
        case (.failed, _): return "エラー"
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
        "VoiceInput: \(statusText())"
    }
}

/// What the HUD renders. Derived from `DictationState` so the view itself stays
/// free of pipeline knowledge (and is trivial to preview).
enum HUDPhase: Equatable {
    case preparing
    case recording
    case transcribing
    case formatting
    /// `body` is the produced text, shown only when the result is `.persistent` —
    /// a dictation's text belongs in the app the user is pasting into, not here.
    case finished(summary: String?, body: String?)
    case failed(VoiceInputError)

    /// `nil` for `.idle` — the HUD must never be on screen when nothing is going on.
    init?(state: DictationState) {
        switch state {
        case .idle: return nil
        case .preparing: self = .preparing
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .formatting: self = .formatting
        case .finished(let outcome):
            self = .finished(
                summary: outcome.summary,
                body: outcome.presentation == .persistent ? outcome.text : nil
            )
        case .failed(let error): self = .failed(error)
        }
    }

    func title(_ mode: DictationMode = .dictation) -> String {
        switch (self, mode) {
        case (.preparing, _): return "準備中…"
        case (.recording, .dictation): return "録音中…"
        case (.recording, .ask): return "質問を録音中…"
        case (.transcribing, .dictation): return "文字起こし中…"
        case (.transcribing, .ask): return "質問を認識中…"
        case (.formatting, .dictation): return "整形中…"
        case (.formatting, .ask): return "回答を作成中…"
        case (.finished, .dictation): return "コピーしました"
        case (.finished, .ask): return "回答をコピーしました"
        case (.failed, _): return "失敗しました"
        }
    }

    func symbol(_ mode: DictationMode = .dictation) -> String {
        switch (self, mode) {
        case (.preparing, _): return "hourglass"
        case (.recording, _): return "mic.fill"
        case (.transcribing, _): return "waveform"
        case (.formatting, .dictation): return "text.append"
        case (.formatting, .ask): return "questionmark.bubble"
        case (.finished, _): return "checkmark.circle.fill"
        case (.failed, _): return "exclamationmark.triangle.fill"
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

    /// A result that stays on screen needs a way out, since no timer will remove it.
    var body: String? {
        guard case .finished(_, let body) = self else { return nil }
        return body
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
        case .emptyAnswer:
            return .ask
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
