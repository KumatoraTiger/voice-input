import Foundation

/// A user-editable formatting preset (the prompt that turns a raw dictation into
/// polished text).
public struct FormattingStyle: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// Appended to the built-in system prompt. Empty means "defaults only".
    public var instructions: String
    /// Built-ins can be edited but not deleted, and are restorable.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, instructions: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }
}

/// A global hotkey, stored as a Carbon key code plus modifier mask.
///
/// Two shapes, registered through different mechanisms (see `HotkeyMonitor`):
/// - **key + modifiers** (`keyCode != nil`), e.g. ⌥Space — Carbon
///   `RegisterEventHotKey`, no Accessibility permission needed.
/// - **modifiers only** (`keyCode == nil`), e.g. ⇧⌃ — Carbon cannot express this,
///   so it is detected from `flagsChanged` events, which *does* need Accessibility.
public struct HotkeyBinding: Codable, Sendable, Equatable, Hashable {
    /// Carbon virtual key code, or `nil` when the modifier combination itself is
    /// the shortcut.
    public var keyCode: UInt32?
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …). Never 0.
    public var modifiers: UInt32

    public init(keyCode: UInt32?, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A shortcut made of modifiers alone, e.g. ⇧⌃.
    public static func modifiersOnly(_ modifiers: UInt32) -> HotkeyBinding {
        HotkeyBinding(keyCode: nil, modifiers: modifiers)
    }

    /// Whether this binding needs the `flagsChanged` path (and so Accessibility).
    public var isModifierOnly: Bool { keyCode == nil }

    /// How many distinct modifiers the mask holds. A modifier-only shortcut needs
    /// at least two, or it would fire every time the user typed a capital letter.
    public var modifierCount: Int { modifiers.nonzeroBitCount }

    /// ⌥Space — chosen because it is rarely taken by other apps.
    public static let defaultToggle = HotkeyBinding(keyCode: 49, modifiers: 1 << 11)
}

/// How the hotkey behaves.
public enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Press once to start, press again to stop.
    case toggle
    /// Record while held down.
    case pushToTalk
}

/// Everything persisted for the user. **Never contains secrets** — API keys live in
/// the Keychain via `SecretStore`. This type is safe to log, export, and diff.
public struct AppSettings: Codable, Sendable, Equatable {
    // MARK: Transcription
    public var transcriptionEngine: TranscriptionEngineID
    /// BCP-47 identifier, e.g. `ja-JP`.
    public var localeIdentifier: String
    /// Model override for cloud STT engines.
    public var transcriptionModel: String
    /// Domain words to bias recognition toward.
    public var vocabulary: [String]

    // MARK: Formatting
    public var llmProvider: LLMProviderID
    /// Model per provider, so switching providers keeps each side's choice.
    public var models: [LLMProviderID: String]
    public var styles: [FormattingStyle]
    public var activeStyleID: UUID?
    /// Skip the LLM entirely and emit the raw transcript.
    public var formattingEnabled: Bool

    // MARK: Output
    public var autoPasteEnabled: Bool
    public var playSounds: Bool
    /// Keep the last N results in memory for the menu (0 disables history).
    public var historyLimit: Int

    // MARK: Input
    public var hotkey: HotkeyBinding
    public var hotkeyMode: HotkeyMode
    public var launchAtLogin: Bool

    public init(
        transcriptionEngine: TranscriptionEngineID = .appleOnDevice,
        localeIdentifier: String = "ja-JP",
        transcriptionModel: String = "gpt-4o-transcribe",
        vocabulary: [String] = [],
        llmProvider: LLMProviderID = .openAI,
        models: [LLMProviderID: String] = [:],
        styles: [FormattingStyle] = FormattingStyle.builtIns,
        activeStyleID: UUID? = FormattingStyle.builtIns.first?.id,
        formattingEnabled: Bool = true,
        autoPasteEnabled: Bool = false,
        playSounds: Bool = true,
        historyLimit: Int = 20,
        hotkey: HotkeyBinding = .defaultToggle,
        hotkeyMode: HotkeyMode = .toggle,
        launchAtLogin: Bool = false
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.localeIdentifier = localeIdentifier
        self.transcriptionModel = transcriptionModel
        self.vocabulary = vocabulary
        self.llmProvider = llmProvider
        self.models = models
        self.styles = styles
        self.activeStyleID = activeStyleID
        self.formattingEnabled = formattingEnabled
        self.autoPasteEnabled = autoPasteEnabled
        self.playSounds = playSounds
        self.historyLimit = historyLimit
        self.hotkey = hotkey
        self.hotkeyMode = hotkeyMode
        self.launchAtLogin = launchAtLogin
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    public var activeStyle: FormattingStyle? {
        guard let activeStyleID else { return styles.first }
        return styles.first { $0.id == activeStyleID } ?? styles.first
    }
}

/// Persists `AppSettings`. Implemented over `UserDefaults`; tests use an in-memory one.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings) throws
}
