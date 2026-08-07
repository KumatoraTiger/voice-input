import Foundation

/// Identifies a thing the app can do with a finished dictation.
///
/// The abstraction is what lets the app do something other than "clean this up"
/// with a finished transcript, bound to its own hotkey, without touching the
/// capture or transcription layers. See `docs/adding-an-action.md`.
public struct VoiceActionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Clean up a raw dictation into polished text.
    public static let format = VoiceActionID(rawValue: "format")
    /// Pass the transcript through untouched (no LLM call, no API key needed).
    public static let raw = VoiceActionID(rawValue: "raw")
    /// Treat the transcript as a question and put the answer on the clipboard.
    ///
    /// The one action where the speech is deliberately allowed to *ask* something
    /// rather than only be rewritten — see `AskPromptBuilder` for where that
    /// licence stops, and `docs/SECURITY.md` for why it is still text-only.
    public static let ask = VoiceActionID(rawValue: "ask")
}

/// How long the finished result stays in front of the user.
///
/// The action decides, the same way it decides `copyToClipboard`: only the action
/// knows whether its output is a confirmation or something the user has to read.
public enum ResultPresentation: Sendable, Equatable {
    /// Flash a confirmation and get out of the way. Right for text that has landed
    /// somewhere the user is about to paste it.
    case transient
    /// Stay on screen until dismissed. Right for output whose whole purpose is to be
    /// read — an answer is useless if it vanishes after 800ms.
    case persistent
}

/// What an action produced and what should happen to it.
public struct ActionOutcome: Sendable, Equatable {
    public var text: String
    /// Put `text` on the pasteboard.
    public var copyToClipboard: Bool
    /// Additionally paste into the frontmost app (requires Accessibility).
    public var pasteIntoFrontmostApp: Bool
    /// Shown in the history / HUD, e.g. "gpt-4.1-mini · 320ms".
    public var summary: String?
    /// Whether the HUD holds this result until the user dismisses it.
    public var presentation: ResultPresentation

    public init(
        text: String,
        copyToClipboard: Bool = true,
        pasteIntoFrontmostApp: Bool = false,
        summary: String? = nil,
        presentation: ResultPresentation = .transient
    ) {
        self.text = text
        self.copyToClipboard = copyToClipboard
        self.pasteIntoFrontmostApp = pasteIntoFrontmostApp
        self.summary = summary
        self.presentation = presentation
    }
}

/// Everything an action is allowed to reach for. Keeps actions injectable in tests.
public struct ActionContext: Sendable {
    public var settings: AppSettings
    public var llm: (any LLMProvider)?
    public var apiKey: String?
    /// Name of the app that was frontmost when recording started, e.g. "Slack".
    /// Lets a future action adapt tone per target app.
    public var frontmostAppName: String?
    /// What was readable on screen when recording started. `nil` unless the user
    /// enabled `AppSettings.screenContextEnabled`. See `ScreenContext` for the
    /// rules an action must respect before putting any of it in a prompt.
    public var screenContext: ScreenContext?

    public init(
        settings: AppSettings,
        llm: (any LLMProvider)? = nil,
        apiKey: String? = nil,
        frontmostAppName: String? = nil,
        screenContext: ScreenContext? = nil
    ) {
        self.settings = settings
        self.llm = llm
        self.apiKey = apiKey
        self.frontmostAppName = frontmostAppName
        self.screenContext = screenContext
    }
}

public protocol VoiceAction: Sendable {
    var id: VoiceActionID { get }
    var displayName: String { get }
    /// If true the action calls an LLM and therefore needs a configured provider.
    var requiresLLM: Bool { get }
    /// If true the action reads `ActionContext.screenContext`.
    ///
    /// The coordinator uses this to decide whether to read the screen **at all**, so
    /// an action that ignores the terms must not cause a capture. Needing an LLM is
    /// not the same question: `AskAction` needs one and has no use for the screen.
    var usesScreenContext: Bool { get }
    func run(transcript: Transcript, context: ActionContext) async throws -> ActionOutcome
}

extension VoiceAction {
    /// Opt in explicitly. A new action that forgets to think about it gets the
    /// answer that reads nothing off the user's screen.
    public var usesScreenContext: Bool { false }
}

/// Where finished text goes.
public protocol OutputSink: Sendable {
    func copy(_ text: String) throws
    /// Paste into whatever app currently has focus.
    func paste(_ text: String) async throws
    /// Whether `paste` will work right now (Accessibility permission granted).
    var canPaste: Bool { get }
}
