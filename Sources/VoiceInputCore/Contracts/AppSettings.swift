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
    /// Optional global shortcut that dictates with this style without changing the
    /// default one. Key + modifiers only: a modifier-only binding is reserved for
    /// the main dictation shortcut (see `HotkeyPlan`).
    ///
    /// Decoded with `decodeIfPresent`, so settings written before this field
    /// existed still load.
    public var hotkey: HotkeyBinding?

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        isBuiltIn: Bool = false,
        hotkey: HotkeyBinding? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.hotkey = hotkey
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

/// How long an answer to a spoken question should be.
///
/// The single most useful knob for voice Q&A: a question asked out loud usually
/// wants a short answer, but the same shortcut is also how you ask for a snippet.
public enum AskAnswerStyle: String, Codable, Sendable, CaseIterable {
    /// Conclusion first, a few sentences. The default.
    case concise
    /// As long as it needs to be, steps and examples included.
    case detailed
}

/// How the hotkey behaves.
public enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Press once to start, press again to stop.
    case toggle
    /// Record while held down.
    case pushToTalk
}

/// Settings for reading the frontmost window to help the LLM fix misrecognised
/// names. See `ScreenContext`.
///
/// A struct rather than a lone `Bool` so the feature can grow knobs without
/// adding more top-level keys — and, being `Optional` on `AppSettings`, so that
/// settings written before the feature existed still decode.
public struct ScreenContextSettings: Codable, Sendable, Equatable {
    /// Off unless the user turns it on. Turning it on is what triggers the
    /// screen-recording permission prompt; nothing asks for it otherwise.
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
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

    // MARK: Ask

    /// Shortcut that records a *question* instead of a dictation.
    ///
    /// `nil`, and deliberately without a default: the feature is opt-in, so it can
    /// never arrive in an update having claimed a combination the user relies on.
    public var askHotkey: HotkeyBinding?
    /// Model per provider for questions, kept apart from `models` on purpose:
    /// formatting wants the cheapest model that can punctuate, answering wants the
    /// most capable one the user is willing to pay for.
    public var askModels: [LLMProviderID: String]
    public var askAnswerStyle: AskAnswerStyle

    // MARK: Screen context
    /// `nil` means the user has never touched the feature, which reads as off.
    ///
    /// Optional carries that meaning, rather than guarding decoding: `init(from:)`
    /// decodes every field with a fallback, so a *required* new key would no longer
    /// reset anyone's configuration either way.
    public var screenContext: ScreenContextSettings?

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
        askHotkey: HotkeyBinding? = nil,
        askModels: [LLMProviderID: String] = [:],
        askAnswerStyle: AskAnswerStyle = .concise,
        screenContext: ScreenContextSettings? = nil,
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
        self.askHotkey = askHotkey
        self.askModels = askModels
        self.askAnswerStyle = askAnswerStyle
        self.screenContext = screenContext
        self.autoPasteEnabled = autoPasteEnabled
        self.playSounds = playSounds
        self.historyLimit = historyLimit
        self.hotkey = hotkey
        self.hotkeyMode = hotkeyMode
        self.launchAtLogin = launchAtLogin
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Non-optional view of `screenContext`, so call sites and SwiftUI bindings
    /// never have to spell the migration detail.
    public var screenContextEnabled: Bool {
        get { screenContext?.isEnabled ?? false }
        set {
            var value = screenContext ?? ScreenContextSettings()
            value.isEnabled = newValue
            screenContext = value
        }
    }

    public var activeStyle: FormattingStyle? {
        guard let activeStyleID else { return styles.first }
        return styles.first { $0.id == activeStyleID } ?? styles.first
    }

    public func style(withID id: UUID?) -> FormattingStyle? {
        guard let id else { return nil }
        return styles.first { $0.id == id }
    }

    /// A copy pointed at another style, used for a **one-off** switch: the
    /// coordinator hands this to the action so a style chosen in the HUD or by a
    /// style shortcut applies to that dictation alone, without persisting.
    /// An id that names no style leaves the settings untouched.
    public func selectingStyle(_ id: UUID?) -> AppSettings {
        guard let id, style(withID: id) != nil else { return self }
        var copy = self
        copy.activeStyleID = id
        return copy
    }

    /// The model a question should use, or `nil` to let the provider's default
    /// stand. Blank counts as unset, the way the formatting model field does.
    public func askModel(for provider: LLMProviderID) -> String? {
        askModels[provider]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

extension AppSettings {
    /// Decoded field by field, so that **adding** a setting never resets the ones a
    /// user already has.
    ///
    /// The synthesized decoder requires every non-optional key to be present, so the
    /// build that introduces one cannot read the previous build's JSON — and
    /// `UserDefaultsSettingsStore.load()` would quietly hand back defaults, taking
    /// the hotkey, the provider and every edited style with it. Optional properties
    /// were always safe (`decodeIfPresent` is synthesized for them); this extends
    /// the same tolerance to the rest.
    ///
    /// A key that is present but of the wrong *type* still throws, which is what
    /// keeps genuinely corrupt data falling back to defaults wholesale.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()

        func decode<T: Decodable>(_ key: CodingKeys, or standby: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? standby
        }

        self.init(
            transcriptionEngine: try decode(.transcriptionEngine, or: fallback.transcriptionEngine),
            localeIdentifier: try decode(.localeIdentifier, or: fallback.localeIdentifier),
            transcriptionModel: try decode(.transcriptionModel, or: fallback.transcriptionModel),
            vocabulary: try decode(.vocabulary, or: fallback.vocabulary),
            llmProvider: try decode(.llmProvider, or: fallback.llmProvider),
            models: try decode(.models, or: fallback.models),
            styles: try decode(.styles, or: fallback.styles),
            activeStyleID: try decode(.activeStyleID, or: fallback.activeStyleID),
            formattingEnabled: try decode(.formattingEnabled, or: fallback.formattingEnabled),
            askHotkey: try container.decodeIfPresent(HotkeyBinding.self, forKey: .askHotkey),
            askModels: try decode(.askModels, or: fallback.askModels),
            askAnswerStyle: try decode(.askAnswerStyle, or: fallback.askAnswerStyle),
            screenContext: try container.decodeIfPresent(
                ScreenContextSettings.self,
                forKey: .screenContext
            ),
            autoPasteEnabled: try decode(.autoPasteEnabled, or: fallback.autoPasteEnabled),
            playSounds: try decode(.playSounds, or: fallback.playSounds),
            historyLimit: try decode(.historyLimit, or: fallback.historyLimit),
            hotkey: try decode(.hotkey, or: fallback.hotkey),
            hotkeyMode: try decode(.hotkeyMode, or: fallback.hotkeyMode),
            launchAtLogin: try decode(.launchAtLogin, or: fallback.launchAtLogin)
        )
    }
}

/// Persists `AppSettings`. Implemented over `UserDefaults`; tests use an in-memory one.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings) throws
}
