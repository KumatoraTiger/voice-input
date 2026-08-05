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
    private let matcher: ScreenTermMatcher
    private let guardian: ScreenContextGuard
    private let maxOutputTokens: Int
    private let clock: @Sendable () -> Date

    public init(
        promptBuilder: FormattingPromptBuilder = FormattingPromptBuilder(),
        matcher: ScreenTermMatcher = ScreenTermMatcher(),
        guardian: ScreenContextGuard = ScreenContextGuard(),
        maxOutputTokens: Int = 4096,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.promptBuilder = promptBuilder
        self.matcher = matcher
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
        let terms = screen.map { matcher.candidates(transcript: raw, terms: $0.terms) } ?? []
        Self.logScreenContext(screen, candidates: terms, settings: context.settings)

        let started = clock()
        var response = try await send(
            transcript: raw,
            screenTerms: terms,
            model: model,
            provider: provider,
            apiKey: apiKey,
            settings: context.settings
        )
        var text = Self.cleanReply(response.text)
        var discardedScreenContext = false

        // The screen influenced the answer; check that only the sanctioned part
        // of it did. A failure here is not an error — it is a reason to ask
        // again with the screen left out entirely, which by construction cannot
        // be contaminated.
        if let screen, !terms.isEmpty {
            let verdict = guardian.inspect(
                output: text,
                transcript: raw,
                screenText: screen.fullText,
                sanctionedTerms: terms
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
                    screenTerms: [],
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

    /// The one number that says whether the feature did anything: how much of the
    /// screen's pool survived matching against what was actually said. `pool > 0`
    /// with `candidates=0` is the honest failure mode — the screen was read and
    /// nothing on it sounded like the dictation — and it is invisible without
    /// this line.
    private static func logScreenContext(
        _ screen: ScreenContext?,
        candidates: [String],
        settings: AppSettings
    ) {
        guard let screen else {
            if settings.screenContextEnabled {
                log.notice("screen context: none available")
            }
            return
        }
        log.notice(
            """
            screen context: pool=\(screen.terms.count, privacy: .public) \
            candidates=\(candidates.count, privacy: .public)
            """
        )
        // Screen content: redacted unless private data is deliberately enabled.
        log.debug("screen candidates: \(candidates.joined(separator: " "), privacy: .private)")
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
        screenTerms: [String],
        model: String,
        provider: any LLMProvider,
        apiKey: String,
        settings: AppSettings
    ) async throws -> LLMResponse {
        let prompt = promptBuilder.build(
            transcript: transcript,
            settings: settings,
            screenTerms: screenTerms
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
