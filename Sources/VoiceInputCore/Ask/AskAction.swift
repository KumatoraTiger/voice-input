import Foundation

/// Answers a spoken question with one LLM call and puts the answer on the clipboard.
///
/// Shares the whole capture path with `FormatAction` and differs only in what the
/// transcript means: there it is text to clean up, here it is the question. Nothing
/// routes a dictation into this action by accident — it runs only when the user
/// presses the shortcut bound to it.
public struct AskAction: VoiceAction {
    public let id = VoiceActionID.ask
    public let displayName = "質問"
    public let requiresLLM = true

    private let promptBuilder: AskPromptBuilder
    private let clock: @Sendable () -> Date

    public init(
        promptBuilder: AskPromptBuilder = AskPromptBuilder(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.promptBuilder = promptBuilder
        self.clock = clock
    }

    public func run(transcript: Transcript, context: ActionContext) async throws -> ActionOutcome {
        let question = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw VoiceInputError.emptyTranscript }

        guard let provider = context.llm else {
            throw VoiceInputError.missingAPIKey(context.settings.llmProvider)
        }
        guard
            let apiKey = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw VoiceInputError.missingAPIKey(provider.id)
        }

        // The ask model is deliberately its own setting; only when the user has not
        // chosen one does this land on the provider default the formatter uses.
        let model = context.settings.askModel(for: provider.id) ?? provider.defaultModel

        let prompt = promptBuilder.build(question: question, settings: context.settings)
        let request = LLMRequest(
            model: model,
            systemPrompt: prompt.system,
            messages: [.user(prompt.user)],
            maxOutputTokens: Self.maxOutputTokens(for: context.settings.askAnswerStyle),
            temperature: 0
        )

        let started = clock()
        let response = try await provider.send(request, apiKey: apiKey)
        let elapsed = clock().timeIntervalSince(started)

        // Unlike a formatted dictation, the answer keeps its markdown fences: a
        // reply to 「Swift で書いて」 is *supposed* to arrive as a fenced block, and
        // stripping the outer one would corrupt an answer that is only code.
        let answer = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw VoiceInputError.emptyAnswer }

        return ActionOutcome(
            text: answer,
            // Still on the clipboard, so ⌘V works when the answer *is* what you
            // wanted to paste.
            copyToClipboard: true,
            // Deliberately not following `autoPasteEnabled`. That setting means
            // "put my dictation into the field I am typing in"; an answer is
            // something to read, and it is shown on screen instead. Dropping a
            // paragraph into the sentence the user was mid-way through writing is
            // almost never what they meant.
            pasteIntoFrontmostApp: false,
            summary: FormatAction.summary(model: response.model ?? model, elapsed: elapsed),
            // An answer that disappears after 800ms is not an answer.
            presentation: .persistent
        )
    }

    /// A truncated answer is worse than a slightly expensive one, so both ceilings
    /// sit above what the length instruction actually asks for.
    static func maxOutputTokens(for style: AskAnswerStyle) -> Int {
        switch style {
        case .concise: return 2048
        case .detailed: return 4096
        }
    }
}
