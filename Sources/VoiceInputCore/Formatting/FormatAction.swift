import Foundation

/// Cleans a raw dictation into polished text with one LLM call.
public struct FormatAction: VoiceAction {
    public let id = VoiceActionID.format
    public let displayName = "整形"
    public let requiresLLM = true

    private let promptBuilder: FormattingPromptBuilder
    private let maxOutputTokens: Int
    private let clock: @Sendable () -> Date

    public init(
        promptBuilder: FormattingPromptBuilder = FormattingPromptBuilder(),
        maxOutputTokens: Int = 4096,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.promptBuilder = promptBuilder
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

        let prompt = promptBuilder.build(transcript: raw, settings: context.settings)
        let request = LLMRequest(
            model: model,
            systemPrompt: prompt.system,
            messages: [.user(prompt.user)],
            maxOutputTokens: maxOutputTokens,
            temperature: 0
        )

        let started = clock()
        let response = try await provider.send(request, apiKey: apiKey)
        let elapsed = clock().timeIntervalSince(started)

        let text = Self.cleanReply(response.text)
        guard !text.isEmpty else { throw VoiceInputError.emptyTranscript }

        return ActionOutcome(
            text: text,
            copyToClipboard: true,
            pasteIntoFrontmostApp: context.settings.autoPasteEnabled,
            summary: Self.summary(model: response.model ?? model, elapsed: elapsed)
        )
    }

    static func summary(model: String, elapsed: TimeInterval) -> String {
        String(format: "%@ · %.1fs", model, max(0, elapsed))
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
