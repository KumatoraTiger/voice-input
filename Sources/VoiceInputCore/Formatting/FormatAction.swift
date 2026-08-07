import Foundation
import os

/// Cleans a raw dictation into polished text with one LLM call.
public struct FormatAction: VoiceAction {
    public let id = VoiceActionID.format
    public let displayName = "整形"
    public let requiresLLM = true
    public let usesScreenContext = true

    private static let log = Logger(subsystem: "io.github.voiceinput", category: "formatting")

    private let promptBuilder: FormattingPromptBuilder
    private let guardian: ScreenContextGuard
    private let maxOutputTokens: Int
    private let clock: @Sendable () -> Date

    public init(
        promptBuilder: FormattingPromptBuilder = FormattingPromptBuilder(),
        guardian: ScreenContextGuard = ScreenContextGuard(),
        maxOutputTokens: Int = 4096,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.promptBuilder = promptBuilder
        self.guardian = guardian
        self.maxOutputTokens = maxOutputTokens
        self.clock = clock
    }

    public func run(transcript: Transcript, context: ActionContext) async throws -> ActionOutcome {
        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw VoiceInputError.emptyTranscript }

        guard let provider = context.llm else {
            throw VoiceInputError.missingAPIKey(context.settings.llmProvider)
        }
        guard
            let apiKey = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw VoiceInputError.missingAPIKey(provider.id)
        }

        let model =
            context.settings.models[provider.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? provider.defaultModel

        let screen = screenContext(for: context)
        let screenText = screen?.text ?? ""
        Self.logScreenContext(screen, settings: context.settings)

        let started = clock()
        var response = try await send(
            transcript: raw,
            screenText: screenText,
            model: model,
            provider: provider,
            apiKey: apiKey,
            settings: context.settings
        )
        var text = Self.cleanReply(response.text)
        var discardedScreenContext = false

        // The screen influenced the answer; check that it influenced the spelling
        // and not the content. A failure here is not an error — it is a reason to
        // ask again with the screen left out entirely, which by construction
        // cannot be contaminated.
        if let screen {
            let verdict = guardian.inspect(
                output: text,
                transcript: raw,
                screenText: screen.text
            )
            if verdict.isContaminated {
                Self.log.warning(
                    """
                    screen context discarded: unexplained span of \
                    \(verdict.offendingLength, privacy: .public) chars
                    """
                )
                response = try await send(
                    transcript: raw,
                    screenText: "",
                    model: model,
                    provider: provider,
                    apiKey: apiKey,
                    settings: context.settings
                )
                text = Self.cleanReply(response.text)
                discardedScreenContext = true
            }
        }

        let elapsed = clock().timeIntervalSince(started)
        guard !text.isEmpty else { throw VoiceInputError.emptyTranscript }

        return ActionOutcome(
            text: text,
            copyToClipboard: true,
            pasteIntoFrontmostApp: context.settings.autoPasteEnabled,
            summary: Self.summary(
                model: response.model ?? model,
                elapsed: elapsed,
                discardedScreenContext: discardedScreenContext
            )
        )
    }

    /// How much of the screen this dictation carried, in characters, so a feature
    /// that is silently doing nothing can be told from one that is working.
    /// `none available` with the setting on means the read produced nothing — the
    /// reason for that is in the `screen` category, from the provider.
    private static func logScreenContext(_ screen: ScreenContext?, settings: AppSettings) {
        guard let screen else {
            if settings.screenContextEnabled {
                log.notice("screen context: none available")
            }
            return
        }
        let sent = min(screen.text.count, FormattingPromptBuilder.screenTextLimit)
        log.notice(
            """
            screen context: chars=\(screen.text.count, privacy: .public) \
            sent=\(sent, privacy: .public)
            """
        )
    }

    /// The screen is only consulted when the user asked for it. Reading the flag
    /// here rather than at the call site keeps the decision next to its use.
    private func screenContext(for context: ActionContext) -> ScreenContext? {
        guard context.settings.screenContextEnabled else { return nil }
        guard let screen = context.screenContext, !screen.isEmpty else { return nil }
        return screen
    }

    private func send(
        transcript: String,
        screenText: String,
        model: String,
        provider: any LLMProvider,
        apiKey: String,
        settings: AppSettings
    ) async throws -> LLMResponse {
        let prompt = promptBuilder.build(
            transcript: transcript,
            settings: settings,
            screenText: screenText
        )
        return try await provider.send(
            LLMRequest(
                model: model,
                systemPrompt: prompt.system,
                messages: [.user(prompt.user)],
                maxOutputTokens: maxOutputTokens,
                temperature: 0
            ),
            apiKey: apiKey
        )
    }

    static func summary(
        model: String,
        elapsed: TimeInterval,
        discardedScreenContext: Bool = false
    ) -> String {
        let base = String(format: "%@ · %.1fs", model, max(0, elapsed))
        // Worth surfacing: it means a retry happened and the result is the
        // screen-free one, which explains both the latency and any term the user
        // expected to be corrected and was not.
        return discardedScreenContext ? "\(base) · 画面コンテキスト破棄" : base
    }

    /// Models occasionally wrap the answer in a fenced block despite being told
    /// not to; strip that rather than pasting backticks into the user's editor.
    static func cleanReply(_ reply: String) -> String {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)

        guard
            let first = lines.first?.trimmingCharacters(in: .whitespaces),
            first.hasPrefix("```"),
            let last = lines.last?.trimmingCharacters(in: .whitespaces),
            last.hasPrefix("```"),
            lines.count >= 2
        else {
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
